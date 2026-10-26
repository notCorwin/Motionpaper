import Foundation
import Testing
@testable import UpdateCore

@Test func installationFailurePersistsAndIsConsumedOnce() throws {
    let fixture = try FailureFixture()
    defer { fixture.cleanUp() }

    try UpdateInstallationFailure.record(message: "The update could not launch.",
                                         application: fixture.application, directory: fixture.reports)

    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.reports.path).count == 1)
    #expect(try UpdateInstallationFailure.consume(application: fixture.application, directory: fixture.reports)?.message
            == "The update could not launch.")
    #expect(try UpdateInstallationFailure.consume(application: fixture.application, directory: fixture.reports) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.reports.path).isEmpty)
}

@Test func installationFailuresAreScopedToCanonicalApplicationURL() throws {
    let fixture = try FailureFixture()
    defer { fixture.cleanUp() }
    let alias = fixture.root.appendingPathComponent("Motionpaper Alias.app", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.application)

    try UpdateInstallationFailure.record(message: "Scoped report", application: fixture.application,
                                         directory: fixture.reports)

    #expect(try UpdateInstallationFailure.consume(application: fixture.otherApplication,
                                                   directory: fixture.reports) == nil)
    #expect(try UpdateInstallationFailure.consume(application: alias, directory: fixture.reports)?.message
            == "Scoped report")
}

@Test func clearingInstallationFailurePreventsStaleFeedback() throws {
    let fixture = try FailureFixture()
    defer { fixture.cleanUp() }

    try UpdateInstallationFailure.clear(application: fixture.application, directory: fixture.reports)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.reports.path).isEmpty)

    try UpdateInstallationFailure.record(message: "Previous attempt failed", application: fixture.application,
                                         directory: fixture.reports)
    try UpdateInstallationFailure.clear(application: fixture.application, directory: fixture.reports)
    #expect(try UpdateInstallationFailure.consume(application: fixture.application, directory: fixture.reports) == nil)

    try UpdateInstallationFailure.record(message: "Current attempt failed", application: fixture.application,
                                         directory: fixture.reports)
    #expect(try UpdateInstallationFailure.consume(application: fixture.application, directory: fixture.reports)?.message
            == "Current attempt failed")
}

@Test func malformedInstallationFailureIsRemovedAndTreatedAsAbsent() throws {
    let fixture = try FailureFixture()
    defer { fixture.cleanUp() }

    try UpdateInstallationFailure.record(message: "Malformed report", application: fixture.application,
                                         directory: fixture.reports)
    let report = try #require(FileManager.default.contentsOfDirectory(at: fixture.reports,
                                                                      includingPropertiesForKeys: nil).first)
    try Data("not a failure report".utf8).write(to: report, options: .atomic)

    #expect(try UpdateInstallationFailure.consume(application: fixture.application, directory: fixture.reports) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.reports.path).isEmpty)
}

private struct FailureFixture {
    let root: URL
    let reports: URL
    let application: URL
    let otherApplication: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        reports = root.appendingPathComponent("Updates", isDirectory: true)
        application = root.appendingPathComponent("Motionpaper.app", isDirectory: true)
        otherApplication = root.appendingPathComponent("Other Motionpaper.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherApplication, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
