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
    private var checkRequest: Task<FeedResponse, any Error>?
    private var cachedFeed: FeedResponse?
    private var downloads: [String: Task<URL, any Error>] = [:]

    public init(feedURL: URL, currentCommit: String, currentVersion: String? = nil,
                channel: UpdateChannel = .autobuild, directory: URL, session: URLSession = .shared) {
        self.feedURL = feedURL
        self.currentCommit = currentCommit
        self.currentVersion = currentVersion
        self.channel = channel
        self.directory = directory
        self.session = session
    }

    public func check(channel requestedChannel: UpdateChannel? = nil) async throws -> UpdateManifest? {
        try Task.checkCancellation()
        let feed = try await feed()
        try Task.checkCancellation()
        switch requestedChannel ?? channel {
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

    public func download(_ manifest: UpdateManifest) async throws -> URL {
        try Task.checkCancellation()
        if let download = downloads[manifest.sha256] {
            let file = try await download.value
            try Task.checkCancellation()
            return file
        }
        let download = Task { [session, directory] in
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(manifest.commit)-\(manifest.sha256).dmg")
            if manager.fileExists(atPath: destination.path) {
                if try Self.verify(destination, manifest: manifest) { return destination }
                try manager.removeItem(at: destination)
            }
            return try await Self.withNetworkRetries {
                let request = URLRequest(url: manifest.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
                let validator = DownloadValidator(size: manifest.size)
                let temporary: URL
                let response: URLResponse
                do {
                    (temporary, response) = try await session.download(for: request, delegate: validator)
                } catch {
                    // A rejected response cancels URLSession, but must retain its HTTP or integrity error.
                    try validator.validate()
                    throw error
                }
                defer { try? manager.removeItem(at: temporary) }
                try validator.validate()
                try Self.validate(response)
                guard try Self.verify(temporary, manifest: manifest) else { throw UpdateError.checksumMismatch }
                try Task.checkCancellation()
                try manager.moveItem(at: temporary, to: destination)
                return destination
            }
        }
        downloads[manifest.sha256] = download
        defer { downloads[manifest.sha256] = nil }
        let file = try await download.value
        try Task.checkCancellation()
        return file
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

    private struct FeedResponse: Sendable {
        let feed: UpdateFeed
        let etag: String?
    }

    private func feed() async throws -> UpdateFeed {
        if let checkRequest { return try await checkRequest.value.feed }
        let request = Task { [session, feedURL, cachedFeed] in
            try await Self.withNetworkRetries {
                try await Self.fetchFeed(feedURL, session: session, cached: cachedFeed)
            }
        }
        checkRequest = request
        defer { checkRequest = nil }
        let response = try await request.value
        cachedFeed = response
        return response.feed
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidManifest }
        guard response.statusCode == 200 else {
            throw ResponseFailure(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        }
    }

    private static func fetchFeed(_ url: URL, session: URLSession, cached: FeedResponse?) async throws -> FeedResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(cached?.etag, forHTTPHeaderField: "If-None-Match")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let response = response as? HTTPURLResponse, response.statusCode == 304,
           let cached, let etag = cached.etag {
            // If-None-Match uses weak comparison; a 304 cannot validate another document.
            func opaqueTag(_ tag: String) -> Substring { tag.hasPrefix("W/") ? tag.dropFirst(2) : tag[...] }
            if let received = response.value(forHTTPHeaderField: "ETag"), opaqueTag(received) != opaqueTag(etag) {
                throw UpdateError.invalidManifest
            }
            return cached
        }
        try validate(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16_384 else { throw UpdateError.invalidManifest }
            data.append(byte)
        }
        let feed = try UpdateFeed(data: data, url: url)
        let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        return FeedResponse(feed: feed, etag: etag?.isEmpty == false ? etag : nil)
    }

    private static func withNetworkRetries<Value>(_ operation: () async throws -> Value) async throws -> Value {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard attempt < 2, let delay = retryDelay(for: error, attempt: attempt) else {
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
