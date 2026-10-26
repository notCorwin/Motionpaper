import CryptoKit
import Foundation

public actor UpdateService {
    private let releaseURL: URL
    private let currentCommit: String
    private let session: URLSession
    private let directory: URL
    private var checkRequest: Task<UpdateManifest?, any Error>?
    private var downloads: [String: Task<URL, any Error>] = [:]

    public init(releaseURL: URL, currentCommit: String, directory: URL, session: URLSession = .shared) {
        self.releaseURL = releaseURL
        self.currentCommit = currentCommit
        self.directory = directory
        self.session = session
    }

    public func check() async throws -> UpdateManifest? {
        if let checkRequest { return try await checkRequest.value }
        let request = Task { [session, releaseURL, currentCommit] in
            var request = URLRequest(url: releaseURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (bytes, response) = try await session.bytes(for: request)
            try Self.validate(response)
            var data = Data()
            for try await byte in bytes {
                guard data.count < 65_536 else { throw UpdateError.invalidManifest }
                data.append(byte)
            }
            let manifest = try UpdateManifest.decode(data, releaseURL: releaseURL)
            return manifest.commit == currentCommit ? nil : manifest
        }
        checkRequest = request
        defer { checkRequest = nil }
        return try await request.value
    }

    public func download(_ manifest: UpdateManifest) async throws -> URL {
        if let download = downloads[manifest.sha256] { return try await download.value }
        let download = Task { [session, directory] in
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(manifest.commit)-\(manifest.sha256).dmg")
            if manager.fileExists(atPath: destination.path) {
                if try Self.verify(destination, manifest: manifest) { return destination }
                try manager.removeItem(at: destination)
            }
            let request = URLRequest(url: manifest.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            let (temporary, response) = try await session.download(for: request, delegate: DownloadSizeLimit(size: manifest.size))
            defer { try? manager.removeItem(at: temporary) }
            try Self.validate(response)
            guard try Self.verify(temporary, manifest: manifest) else { throw UpdateError.checksumMismatch }
            try Task.checkCancellation()
            try manager.moveItem(at: temporary, to: destination)
            return destination
        }
        downloads[manifest.sha256] = download
        defer { downloads[manifest.sha256] = nil }
        return try await download.value
    }

    public func cancel() {
        checkRequest?.cancel()
        for download in downloads.values { download.cancel() }
    }

    public static func verify(_ file: URL, manifest: UpdateManifest) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == manifest.size else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == manifest.sha256
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidManifest }
        guard response.statusCode == 200 else { throw UpdateError.httpStatus(response.statusCode) }
    }
}

private final class DownloadSizeLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let size: Int64

    init(size: Int64) { self.size = size }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size || totalBytesExpectedToWrite > size { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
