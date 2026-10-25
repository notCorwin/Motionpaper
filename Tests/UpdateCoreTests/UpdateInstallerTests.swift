import Darwin
import Foundation
import Testing
@testable import UpdateCore

private let originalCommit = String(repeating: "a", count: 40)
private let candidateCommit = String(repeating: "b", count: 40)
private let changedCommit = String(repeating: "c", count: 40)
private let mismatchedCommit = String(repeating: "d", count: 40)

@Test func testUpdateInstallerExchangesBeforeRelaunchAndCleansStage() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit)
    let relaunch = RelaunchProbe()

    try await update.install { application, _ in
        try await relaunch.launch(application)
    }

    #expect(await relaunch.observedCommits() == [candidateCommit])
    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == candidateCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerRestoresPreviousAppWhenRelaunchFails() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit)
    let relaunch = RelaunchProbe(failFirstAttempt: true)

    await #expect(throws: RelaunchProbe.Failure.self) {
        try await update.install { application, _ in
            try await relaunch.launch(application)
        }
    }

    #expect(await relaunch.observedCommits() == [candidateCommit, originalCommit])
    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerRejectsCandidateWithMismatchedCommit() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit, applicationCommit: mismatchedCommit)

    await #expect(throws: (any Error).self) {
        try await update.install { _, _ in }
    }

    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerRejectsCandidateWithWrongBundleIdentifier() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit, bundleIdentifier: "example.invalid")

    await #expect(throws: (any Error).self) {
        try await update.install { _, _ in }
    }

    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerRejectsInvalidCandidateSignature() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit, damageSignature: true)

    await #expect(throws: (any Error).self) {
        try await update.install { _, _ in }
    }

    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerRejectsDestinationChangedAfterPreparation() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit)
    let replacement = fixture.root.appendingPathComponent("ChangedMotionpaper.app", isDirectory: true)
    try makeApplication(at: replacement, commit: changedCommit)
    try FileManager.default.removeItem(at: fixture.destination)
    try FileManager.default.moveItem(at: replacement, to: fixture.destination)

    await #expect(throws: UpdateError.self) {
        try await update.install { _, _ in }
    }

    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == changedCommit)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
}

@Test func testUpdateInstallerConfirmsLaunchForMatchingApplicationAndFullCommit() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit)
    try fixture.writePlan(update)
    let pid = ProcessInfo.processInfo.processIdentifier

    #expect(throws: UpdateError.self) {
        try PreparedUpdate.confirmLaunch(arguments: ["--complete-update", update.directory.path, candidateCommit],
                                         application: fixture.root, commit: candidateCommit, pid: pid)
    }

    let abbreviatedCommit = String(candidateCommit.prefix(12))
    #expect(throws: UpdateError.self) {
        try PreparedUpdate.confirmLaunch(arguments: ["--complete-update", update.directory.path, abbreviatedCommit],
                                         application: fixture.destination, commit: abbreviatedCommit, pid: pid)
    }

    try PreparedUpdate.confirmLaunch(arguments: ["--complete-update", update.directory.path, candidateCommit],
                                     application: fixture.destination, commit: candidateCommit, pid: pid)
    try await update.waitForLaunch(pid: pid, commit: candidateCommit)
}

@Test func testUpdateInstallerStaleCleanupPreservesLeasedStageAndInstalledApp() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit)
    try fixture.writePlan(update)
    let lease = try update.acquireLease()
    defer { try? lease.close() }

    #expect(try UpdateInstaller.installationInProgress(application: fixture.destination))
    try await UpdateInstaller.removeStaleInstallations(application: fixture.destination)
    #expect(FileManager.default.fileExists(atPath: update.directory.path))
    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)

    try lease.close()
    try await UpdateInstaller.removeStaleInstallations(application: fixture.destination)
    #expect(!FileManager.default.fileExists(atPath: update.directory.path))
    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == originalCommit)
}

@Test func testUpdateInstallerStaleCleanupPreservesUnconfirmedPreviousVersion() async throws {
    let fixture = try InstallerFixture()
    defer { fixture.cleanUp() }
    let update = try fixture.makeUpdate(commit: candidateCommit, applicationCommit: originalCommit)
    try fixture.writePlan(update)
    // Arrange the persisted state after a swap whose launch or rollback never completed.
    try FileManager.default.removeItem(at: fixture.destination)
    try makeApplication(at: fixture.destination, commit: candidateCommit)

    try await UpdateInstaller.removeStaleInstallations(application: fixture.destination)

    #expect(try UpdateInstaller.bundleCommit(update.replacement) == originalCommit)
    #expect(try UpdateInstaller.bundleCommit(fixture.destination) == candidateCommit)
}

@Test func releasingLeaseUnlocksInheritedDescriptorsAndCannotCloseANewerLease() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateLeaseTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    let lease = UpdateLease(fileDescriptor: descriptor)
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    // A forked child shares this open file description. dup reproduces that
    // ownership deterministically, without depending on subprocess timing.
    let inherited = dup(descriptor)
    try #require(inherited >= 0)
    defer { close(inherited) }

    try lease.close()
    let next = try UpdateInstaller.acquireLease(directory: directory)
    defer { try? next.close() }
    try lease.close()
    #expect(throws: UpdateError.self) {
        try UpdateInstaller.acquireLease(directory: directory)
    }
}

private struct InstallerFixture {
    let root: URL
    let destination: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        root = directory.resolvingSymlinksInPath()
        destination = root.appendingPathComponent("Motionpaper.app", isDirectory: true)
        do {
            try makeApplication(at: destination, commit: originalCommit)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func makeUpdate(commit: String, applicationCommit: String? = nil,
                    bundleIdentifier: String = "local.motionpaper.app",
                    damageSignature: Bool = false) throws -> PreparedUpdate {
        let directory = root.appendingPathComponent(".motionpaper-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let replacement = directory.appendingPathComponent("Motionpaper.app", isDirectory: true)
            try makeApplication(at: replacement, commit: applicationCommit ?? commit,
                                bundleIdentifier: bundleIdentifier)
            if damageSignature {
                try FileManager.default.removeItem(at: replacement.appendingPathComponent("Contents/_CodeSignature"))
            }
            return PreparedUpdate(directory: directory, destination: destination,
                                  commit: commit, previousCommit: originalCommit)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func writePlan(_ update: PreparedUpdate) throws {
        try JSONEncoder().encode(update).write(to: update.directory.appendingPathComponent("update.json"),
                                               options: .atomic)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeApplication(at application: URL, commit: String,
                             bundleIdentifier: String = "local.motionpaper.app") throws {
    let manager = FileManager.default
    let contents = application.appendingPathComponent("Contents", isDirectory: true)
    let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
    try manager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                         to: executableDirectory.appendingPathComponent("Motionpaper"))
    let information: [String: String] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleExecutable": "Motionpaper",
        "CFBundleName": "Motionpaper",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "MotionpaperCommit": commit,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))

    try runCodeSign(["--force", "--deep", "--strict", "--sign", "-",
                     "--identifier", bundleIdentifier, application.path])
}

private func runCodeSign(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw InstallerTestError.codeSignFailed(process.terminationStatus)
    }
}

private enum InstallerTestError: Error {
    case codeSignFailed(Int32)
}

private actor RelaunchProbe {
    enum Failure: Error {
        case firstAttempt
    }

    private let failFirstAttempt: Bool
    private var commits: [String] = []

    init(failFirstAttempt: Bool = false) {
        self.failFirstAttempt = failFirstAttempt
    }

    func launch(_ application: URL) throws {
        commits.append(try UpdateInstaller.bundleCommit(application))
        if failFirstAttempt, commits.count == 1 {
            throw Failure.firstAttempt
        }
    }

    func observedCommits() -> [String] { commits }
}
