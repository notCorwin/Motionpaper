import CryptoKit
import Foundation

public struct UpdateInstallationFailure: Sendable {
    public let message: String

    private init(message: String) {
        self.message = message
    }

    public static func record(message: String, application: URL, directory: URL? = nil) throws {
        let (reportURL, applicationPath) = try reportLocation(application: application, directory: directory)
        let stored = StoredFailure(applicationPath: applicationPath, message: message)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: reportURL, options: .atomic)
    }

    /// Returns and removes a valid report. Malformed or mismatched reports are removed and treated as absent.
    public static func consume(application: URL, directory: URL? = nil) throws -> UpdateInstallationFailure? {
        let (reportURL, applicationPath) = try reportLocation(application: application, directory: directory)
        let manager = FileManager.default
        guard manager.fileExists(atPath: reportURL.path) else { return nil }

        let claimedURL = reportURL.deletingLastPathComponent()
            .appendingPathComponent(".\(reportURL.lastPathComponent).consume-\(UUID().uuidString)")
        do {
            try manager.moveItem(at: reportURL, to: claimedURL)
        } catch {
            // Another consumer may have atomically claimed the report first.
            guard manager.fileExists(atPath: reportURL.path) else { return nil }
            throw error
        }
        defer { try? manager.removeItem(at: claimedURL) }

        let data: Data
        do {
            data = try Data(contentsOf: claimedURL)
        } catch {
            // Preserve a report if a transient read failure prevented consumption.
            try? manager.moveItem(at: claimedURL, to: reportURL)
            throw error
        }
        guard let stored = try? JSONDecoder().decode(StoredFailure.self, from: data),
              stored.version == StoredFailure.currentVersion,
              stored.applicationPath == applicationPath else {
            return nil
        }
        return UpdateInstallationFailure(message: stored.message)
    }

    public static func clear(application: URL, directory: URL? = nil) throws {
        let (reportURL, _) = try reportLocation(application: application, directory: directory)
        let manager = FileManager.default
        guard manager.fileExists(atPath: reportURL.path) else { return }
        do {
            try manager.removeItem(at: reportURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Clearing before a first installation attempt is expected.
        }
    }

    private static func reportLocation(application: URL, directory: URL?) throws -> (URL, String) {
        guard application.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let canonicalApplication = application.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let applicationPath = canonicalApplication.path
        let digest = SHA256.hash(data: Data(applicationPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let reportDirectory: URL
        if let directory {
            guard directory.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            reportDirectory = directory
        } else {
            reportDirectory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                          appropriateFor: nil, create: false)
                .appendingPathComponent("local.motionpaper.app", isDirectory: true)
                .appendingPathComponent("Updates", isDirectory: true)
        }
        return (reportDirectory.appendingPathComponent("installation-failure-\(digest).json"), applicationPath)
    }
}

private struct StoredFailure: Codable {
    static let currentVersion = 1

    let version: Int
    let applicationPath: String
    let recordedAt: Date
    let message: String

    init(applicationPath: String, message: String) {
        version = Self.currentVersion
        self.applicationPath = applicationPath
        recordedAt = Date()
        self.message = message
    }
}
