import CryptoKit
import Foundation
import Synchronization

public actor UpdateService {
    private let feedURL: URL
    private let currentCommit: String
    private let currentVersion: String?
    private let channel: UpdateChannel
    private let session: URLSession
    private let directory: URL
    private var checkRequests: [UpdateChannel: Task<UpdateFeed, any Error>] = [:]
    private var downloads: [DownloadKey: DownloadRequest] = [:]

    private struct DownloadKey: Hashable {
        let url: URL
        let sha256: String
        let size: Int64
    }

    private struct DownloadRequest {
        let task: Task<TemporaryImage, any Error>
        var users: Int
    }

    public init(feedURL: URL, currentCommit: String, currentVersion: String? = nil,
                channel: UpdateChannel = .autobuild, directory: URL, session: URLSession? = nil) {
        self.feedURL = feedURL
        self.currentCommit = currentCommit
        self.currentVersion = currentVersion
        self.channel = channel
        self.directory = directory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func check(channel requestedChannel: UpdateChannel? = nil) async throws -> UpdateManifest? {
        try Task.checkCancellation()
        let requestedChannel = requestedChannel ?? channel
        let feed: UpdateFeed
        do {
            feed = try await self.feed(for: requestedChannel)
        } catch UpdateError.httpStatus(404) where requestedChannel == .stable && currentVersion == nil {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        switch requestedChannel {
        case .autobuild:
            guard let manifest = feed.autobuild else { throw UpdateError.invalidManifest }
            return manifest.commit == currentCommit ? nil : manifest
        case .stable:
            guard let manifest = feed.stable else {
                if currentVersion != nil { throw UpdateError.invalidManifest }
                return nil
            }
            guard let currentVersion else { return manifest }
            guard let current = ReleaseVersion(currentVersion), let latest = manifest.version else {
                throw UpdateError.invalidManifest
            }
            return latest > current ? manifest : nil
        }
    }

    /// Shares an in-flight download, retaining its temporary image until all users finish.
    public func withDownloadedImage<Value: Sendable>(
        _ manifest: UpdateManifest, operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let key = DownloadKey(url: manifest.downloadURL, sha256: manifest.sha256, size: manifest.size)
        let task: Task<TemporaryImage, any Error>
        if var existing = downloads[key] {
            existing.users += 1
            downloads[key] = existing
            task = existing.task
        } else {
            task = Task { [session, directory] in
                let image = try TemporaryImage(directory: directory)
                return try await Self.withNetworkRetries {
                    var request = URLRequest(url: manifest.downloadURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
                    request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                    let validator = DownloadValidator(size: manifest.size)
                    let temporary: URL
                    let response: URLResponse
                    do {
                        (temporary, response) = try await session.download(for: request, delegate: validator)
                    } catch {
                        try validator.validate()
                        throw error
                    }
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try validator.validate()
                    try Self.validate(response)
                    guard try Self.verify(temporary, manifest: manifest) else { throw UpdateError.checksumMismatch }
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: temporary, to: image.url)
                    return image
                }
            }
            downloads[key] = DownloadRequest(task: task, users: 1)
        }
        defer {
            if var request = downloads[key] {
                request.users -= 1
                downloads[key] = request.users == 0 ? nil : request
            }
        }
        let image = try await task.value
        defer { withExtendedLifetime(image) {} }
        try Task.checkCancellation()
        return try await operation(image.url)
    }

    /// Removes abandoned temporary downloads while leaving other processes' active images intact.
    public func removeStaleDownloads() throws {
        try TemporaryImage.removeStale(in: directory)
        try UpdateDownloadCleanup.removeLegacyImages(in: directory)
    }

    public func cancel() {
        for request in checkRequests.values { request.cancel() }
        for download in downloads.values { download.task.cancel() }
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

    private func feed(for channel: UpdateChannel) async throws -> UpdateFeed {
        if let request = checkRequests[channel] { return try await request.value }
        let url = try UpdateFeed.url(for: channel, source: feedURL)
        let request = Task { [session] in
            try await Self.withNetworkRetries(retryNotFound: channel == .autobuild) {
                try await Self.fetchFeed(url, session: session)
            }
        }
        checkRequests[channel] = request
        defer { checkRequests[channel] = nil }
        return try await request.value
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidManifest }
        guard response.statusCode == 200 else {
            throw ResponseFailure(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
    }

    private static func fetchFeed(_ url: URL, session: URLSession) async throws -> UpdateFeed {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try validate(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_384 else { throw UpdateError.invalidManifest }
            data.append(byte)
        }
        return try UpdateFeed(data: data, url: url)
    }

    private static func withNetworkRetries<Value>(retryNotFound: Bool = false, _ operation: () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                let delay = retryNotFound && (error as? ResponseFailure)?.status == 404
                    ? Duration.seconds(1) : retryDelay(for: error, attempt: attempt)
                guard attempt < 2, let delay else {
                    if let response = error as? ResponseFailure { throw UpdateError.httpStatus(response.status) }
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: delay)
            }
        }
    }

    private static func retryDelay(for error: any Error, attempt: Int) -> Duration? {
        let backoff = Duration.seconds(1 << attempt)
        if let response = error as? ResponseFailure {
            guard [408, 429, 500, 502, 503, 504].contains(response.status) else { return nil }
            guard let retryAfter = response.retryAfter else { return backoff }
            let seconds: TimeInterval
            if let value = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
                seconds = value
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                guard let date = formatter.date(from: retryAfter) else { return nil }
                seconds = max(0, date.timeIntervalSinceNow)
            }
            // Do not retry before the server allows it, or keep a menu action waiting on a long rate limit.
            guard seconds.isFinite, seconds >= 0, seconds <= 30 else { return nil }
            return max(backoff, .seconds(seconds))
        }
        guard let error = error as? URLError,
              [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
               .dnsLookupFailed, .notConnectedToInternet].contains(error.code) else { return nil }
        return backoff
    }
}

private final class TemporaryImage: Sendable {
    let directory: URL
    let lease: UpdateLease
    var url: URL { directory.appendingPathComponent("image.dmg") }

    init(directory root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let creating = root.appendingPathComponent(".creating-\(id)", isDirectory: true)
        let published = root.appendingPathComponent("download-\(id)", isDirectory: true)
        try manager.createDirectory(at: creating, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let lock = try UpdateInstaller.acquireLease(directory: creating)
            try manager.moveItem(at: creating, to: published)
            directory = published
            lease = lock
        } catch {
            try? manager.removeItem(at: creating)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        try? lease.close()
    }

    static func removeStale(in root: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let name = directory.lastPathComponent
            guard name.hasPrefix("download-"), UUID(uuidString: String(name.dropFirst("download-".count))) != nil,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink == false else { continue }
            let lease: UpdateLease
            do { lease = try UpdateInstaller.acquireLease(directory: directory) }
            catch UpdateError.installationInProgress { continue }
            catch let error as POSIXError where error.code == .ENOENT { continue }
            defer { try? lease.close() }
            do { try manager.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { continue }
        }
    }
}

private struct ResponseFailure: Error {
    let status: Int
    let retryAfter: String?
}

private final class DownloadValidator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let size: Int64
    private let failure = Mutex<(any Error)?>(nil)

    init(size: Int64) { self.size = size }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let error: (any Error)?
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            error = ResponseFailure(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } else if totalBytesWritten > size || totalBytesExpectedToWrite > size {
            error = UpdateError.checksumMismatch
        } else {
            error = nil
        }
        if let error {
            failure.withLock { if $0 == nil { $0 = error } }
            downloadTask.cancel()
        }
    }

    func validate() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
