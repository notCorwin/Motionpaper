import Foundation
import Testing
@testable import UpdateCore

@Test func legacyImageCleanupPreservesReportsAndUnrelatedFiles() throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }

    let commit = String(repeating: "a", count: 40)
    let hash = String(repeating: "b", count: 64)
    let image = directory.appendingPathComponent("\(commit)-\(hash).dmg")
    let report = directory.appendingPathComponent("installation-failure-\(hash).json")
    let unrelated = directory.appendingPathComponent("\(commit)-\(hash).dmg.backup")
    let target = directory.appendingPathComponent("target")
    let link = directory.appendingPathComponent("\(String(repeating: "c", count: 40))-\(hash).dmg")
    for file in [image, report, unrelated, target] { try Data("data".utf8).write(to: file) }
    try manager.createSymbolicLink(at: link, withDestinationURL: target)

    try UpdateDownloadCleanup.removeLegacyImages(in: directory)
    #expect(!manager.fileExists(atPath: image.path))
    for file in [report, unrelated, target, link] {
        #expect(manager.fileExists(atPath: file.path))
    }
    try UpdateDownloadCleanup.removeLegacyImages(in: directory)
    try UpdateDownloadCleanup.removeLegacyImages(in: directory.appendingPathComponent("absent"))
}
