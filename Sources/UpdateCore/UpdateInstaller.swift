import Darwin
import Foundation

public enum UpdateInstaller {
    public static func validateDestination(_ application: URL) throws {
        let application = application.resolvingSymlinksInPath()
        let volume = try application.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeSupportsSwapRenamingKey])
        guard application.pathExtension == "app",
              !application.pathComponents.contains("AppTranslocation"),
              volume.volumeIsReadOnly != true,
              FileManager.default.isWritableFile(atPath: application.deletingLastPathComponent().path) else {
            throw UpdateError.installLocation
        }
        guard volume.volumeSupportsSwapRenaming == true else { throw UpdateError.unsupportedVolume }
    }

    // The download service has already verified the image's size and SHA-256.
    public static func prepare(image: URL, manifest: UpdateManifest, application: URL) async throws -> PreparedUpdate {
        let manager = FileManager.default
        let destination = application.resolvingSymlinksInPath()
        try validateDestination(destination)
        let previousCommit = try bundleCommit(destination)
        let directory = destination.deletingLastPathComponent()
            .appendingPathComponent(".motionpaper-update-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        let update = PreparedUpdate(directory: directory, destination: destination,
                                    commit: manifest.commit, previousCommit: previousCommit)
        let lease = try update.acquireLease()
        defer { try? lease.close() }
        var prepared = false
        defer { if !prepared { update.discard() } }

        let mount = directory.appendingPathComponent("Image", isDirectory: true)
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        // Also attempt detach if attach fails after partially mounting the volume.
        var detached = false
        defer {
            if !detached { try? run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path]) }
        }
        try Task.checkCancellation()
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-quiet",
                                    "-mountpoint", mount.path, image.path])
        try Task.checkCancellation()
        let source = mount.appendingPathComponent("Motionpaper.app", isDirectory: true)
        guard source.resolvingSymlinksInPath() == source else { throw UpdateError.invalidApplication }
        try run("/usr/bin/ditto", [source.path, update.replacement.path])
        try Task.checkCancellation()
        try validateApplication(update.replacement, commit: manifest.commit, version: manifest.version)
        try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path])
        detached = true
        try manager.removeItem(at: mount)
        try Task.checkCancellation()

        // The running helper must survive replacement of its containing app bundle.
        try manager.copyItem(at: destination.appendingPathComponent("Contents/Helpers/MotionpaperUpdater"),
                             to: update.helper)
        try JSONEncoder().encode(update).write(to: directory.appendingPathComponent("update.json"), options: .atomic)
        prepared = true
        return update
    }

    public static func installationInProgress(application: URL) throws -> Bool {
        for directory in try transactionDirectories(application: application) {
            if let update = try? PreparedUpdate.load(from: directory),
               update.destination != application.resolvingSymlinksInPath() { continue }
            do {
                let lease = try acquireLease(directory: directory)
                try lease.close()
            } catch UpdateError.installationInProgress { return true }
        }
        return false
    }

    // Only a successfully started app removes abandoned transactions and old backups.
    public static func removeStaleInstallations(application: URL) async throws {
        for directory in try transactionDirectories(application: application) {
            try Task.checkCancellation()
            let update = try? PreparedUpdate.load(from: directory)
            if let update, update.destination != application.resolvingSymlinksInPath() { continue }
            let lease: UpdateLease
            do { lease = try acquireLease(directory: directory) }
            catch UpdateError.installationInProgress { continue }
            defer { try? lease.close() }
            if let update {
                // An interrupted swap or failed rollback may hold the only recoverable old app.
                if (try? bundleCommit(update.replacement)) != update.commit,
                   !FileManager.default.fileExists(atPath: update.completed.path) { continue }
            } else if FileManager.default.fileExists(atPath: directory.appendingPathComponent("install").path),
                      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path) {
                continue
            }
            let mount = directory.appendingPathComponent("Image", isDirectory: true)
            if FileManager.default.fileExists(atPath: mount.path) {
                try? run("/usr/bin/hdiutil", ["detach", "-force", "-quiet", mount.path])
            }
            try FileManager.default.removeItem(at: directory)
        }
    }

    private static func transactionDirectories(application: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: application.resolvingSymlinksInPath().deletingLastPathComponent(),
                                                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return $0.lastPathComponent.hasPrefix(".motionpaper-update-") &&
                    values?.isDirectory == true && values?.isSymbolicLink == false
            }
            .map { $0.resolvingSymlinksInPath() }
    }

    static func acquireLease(directory: URL) throws -> UpdateLease {
        let descriptor = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw UpdateError.installationInProgress }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return UpdateLease(fileDescriptor: descriptor)
    }

    static func bundleCommit(_ application: URL) throws -> String {
        let data = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.motionpaper.app",
              info["CFBundleExecutable"] as? String == "Motionpaper",
              let commit = info["MotionpaperCommit"] as? String,
              commit.utf8.count == 40,
              commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw UpdateError.invalidApplication
        }
        return commit
    }

    static func validateApplication(_ application: URL, commit: String, version: ReleaseVersion? = nil) throws {
        guard try bundleCommit(application) == commit else { throw UpdateError.invalidApplication }
        if let version {
            let data = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["MotionpaperReleaseChannel"] as? String == "stable",
                  info["CFBundleShortVersionString"] as? String == version.description else {
                throw UpdateError.invalidApplication
            }
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures",
                                    "-R", "=identifier \"local.motionpaper.app\"", application.path])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installCommand(URL(fileURLWithPath: executable).lastPathComponent, process.terminationStatus)
        }
    }
}

public struct PreparedUpdate: Codable, Sendable {
    public let directory: URL
    public let destination: URL
    public let commit: String
    let previousCommit: String

    var replacement: URL { directory.appendingPathComponent("Motionpaper.app", isDirectory: true) }
    public var helper: URL { directory.appendingPathComponent("MotionpaperUpdater") }
    public var ready: URL { directory.appendingPathComponent("ready") }
    public var authorization: URL { directory.appendingPathComponent("install") }
    private var confirmation: URL { directory.appendingPathComponent("launched.json") }
    var completed: URL { directory.appendingPathComponent("completed") }

    public func acquireLease() throws -> UpdateLease { try UpdateInstaller.acquireLease(directory: directory) }

    public static func load(from directory: URL) throws -> Self {
        let data = try Data(contentsOf: directory.appendingPathComponent("update.json"))
        let update = try JSONDecoder().decode(Self.self, from: data)
        guard update.directory == directory,
              directory.lastPathComponent.hasPrefix(".motionpaper-update-"),
              directory.deletingLastPathComponent() == update.destination.deletingLastPathComponent(),
              directory.resolvingSymlinksInPath() == directory,
              update.destination.resolvingSymlinksInPath() == update.destination else {
            throw UpdateError.invalidApplication
        }
        return update
    }

    public func startInstaller(parentPID: Int32) async throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = [directory.path, String(parentPID)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var handedOff = false
        defer {
            if !handedOff, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw UpdateError.installerUnavailable }
            if FileManager.default.fileExists(atPath: ready.path) {
                try Task.checkCancellation()
                // This is the commit point: cancellation can no longer abort installation.
                try Data(commit.utf8).write(to: authorization, options: .atomic)
                handedOff = true
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw UpdateError.installerUnavailable
    }

    public static func confirmLaunch(arguments: [String], application: URL, commit: String, pid: Int32) throws {
        guard let index = arguments.firstIndex(of: "--complete-update") else { return }
        guard index + 2 < arguments.count, arguments[index + 2] == commit else {
            throw UpdateError.invalidApplication
        }
        let update = try load(from: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        guard update.destination == application.resolvingSymlinksInPath(),
              commit == update.commit || commit == update.previousCommit else {
            throw UpdateError.invalidApplication
        }
        let receipt = LaunchReceipt(commit: commit, pid: pid)
        try JSONEncoder().encode(receipt).write(to: update.confirmation, options: .atomic)
    }

    public func waitForLaunch(pid: Int32, commit: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            guard kill(pid, 0) == 0 else { throw UpdateError.launchFailed }
            if let data = try? Data(contentsOf: confirmation),
               let receipt = try? JSONDecoder().decode(LaunchReceipt.self, from: data),
               receipt.commit == commit, receipt.pid == pid { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw UpdateError.launchFailed
    }

    // A same-volume atomic exchange always leaves a complete app at the installed path.
    public func install(relaunch: @Sendable (URL, String) async throws -> Void) async throws {
        var preserveBackup = false
        defer { if !preserveBackup { discard() } }
        try UpdateInstaller.validateDestination(destination)
        guard try UpdateInstaller.bundleCommit(destination) == previousCommit else {
            throw UpdateError.installationChanged
        }
        try UpdateInstaller.validateApplication(replacement, commit: commit)
        try exchange()
        do {
            try await relaunch(destination, commit)
            try? Data().write(to: completed, options: .atomic)
        } catch {
            do { try exchange() }
            catch {
                preserveBackup = true
                throw UpdateError.rollbackFailed(replacement.path)
            }
            try? await relaunch(destination, previousCommit)
            throw error
        }
    }

    private func exchange() throws {
        guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public func discard() { try? FileManager.default.removeItem(at: directory) }
}

private struct LaunchReceipt: Codable {
    let commit: String
    let pid: Int32
}
