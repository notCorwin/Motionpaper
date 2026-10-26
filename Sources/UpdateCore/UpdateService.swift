import CryptoKit
import Foundation

public actor UpdateService {
    private let releaseURL: URL
    private let currentCommit: String
    private let currentVersion: String?
    private let channel: UpdateChannel
    private let session: URLSession
    private let directory: URL
    private var checkTasks: [UpdateChannel: Task<UpdateManifest?, any Error>] = [:]
    private var catalogRequest: Task<[Data], any Error>?
    private var downloads: [String: Task<URL, any Error>] = [:]

    public init(releaseURL: URL, currentCommit: String, currentVersion: String? = nil,
                channel: UpdateChannel = .autobuild, directory: URL, session: URLSession = .shared) {
        self.releaseURL = releaseURL
        self.currentCommit = currentCommit
        self.currentVersion = currentVersion
        self.channel = channel
        self.directory = directory
        self.session = session
    }

    public func check(channel requestedChannel: UpdateChannel? = nil) async throws -> UpdateManifest? {
        let requestedChannel = requestedChannel ?? channel
        if let task = checkTasks[requestedChannel] { return try await task.value }

        let task = Task { try await self.update(for: requestedChannel) }
        checkTasks[requestedChannel] = task
        defer { checkTasks[requestedChannel] = nil }
        return try await task.value
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
        for task in checkTasks.values { task.cancel() }
        catalogRequest?.cancel()
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

    private func update(for channel: UpdateChannel) async throws -> UpdateManifest? {
        let releases = try await catalog()
        switch channel {
        case .autobuild:
            var latest: (data: Data, publishedAt: Date)?
            for release in releases {
                try Task.checkCancellation()
                guard let publishedAt = try UpdateManifest.autobuildPublishedAt(in: release) else { continue }
                if latest == nil || publishedAt > latest!.publishedAt {
                    latest = (release, publishedAt)
                }
            }
            guard let latest else { throw UpdateError.invalidManifest }
            let manifest = try UpdateManifest.decode(latest.data, releaseURL: releaseURL)
            return manifest.commit == currentCommit ? nil : manifest

        case .stable:
            var highestVersion: ReleaseVersion?
            var latestRelease: Data?
            for release in releases {
                try Task.checkCancellation()
                guard let version = try UpdateManifest.stableVersion(in: release) else { continue }
                if highestVersion == nil || version > highestVersion! {
                    highestVersion = version
                    latestRelease = release
                }
            }

            guard let latestRelease else {
                if currentVersion != nil { throw UpdateError.invalidManifest }
                return nil
            }
            let manifest = try UpdateManifest.decodeStableRelease(latestRelease, releaseURL: releaseURL)
            guard let currentVersion else { return manifest }
            guard let current = ReleaseVersion(currentVersion), let latest = manifest.version else {
                throw UpdateError.invalidManifest
            }
            return latest > current ? manifest : nil
        }
    }

    private func catalog() async throws -> [Data] {
        if let catalogRequest { return try await catalogRequest.value }
        guard let repository = UpdateManifest.repository(in: releaseURL) else {
            throw UpdateError.invalidManifest
        }

        let request = Task { [session, releaseURL] in
            try await Self.fetchCatalog(releaseURL: releaseURL, repository: repository, session: session)
        }
        catalogRequest = request
        defer { catalogRequest = nil }
        return try await request.value
    }

    private static func fetchCatalog(releaseURL: URL,
                                     repository: (owner: String, name: String),
                                     session: URLSession) async throws -> [Data] {
        var pageURL = releaseURL
        var page = 1
        var releases: [Data] = []

        while true {
            try Task.checkCancellation()
            let (data, response) = try await fetch(pageURL, session: session, maximumSize: 1_048_576)
            let pageReleases: [[String: Any]]
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      decoded.count <= 100 else { throw UpdateError.invalidManifest }
                pageReleases = decoded
            } catch {
                throw UpdateError.invalidManifest
            }

            for release in pageReleases {
                do {
                    releases.append(try JSONSerialization.data(withJSONObject: release))
                } catch {
                    throw UpdateError.invalidManifest
                }
            }

            guard let nextPage = try nextPageURL(from: response, repository: repository, currentPage: page) else {
                return releases
            }
            pageURL = nextPage
            page += 1
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidManifest }
        guard response.statusCode == 200 else { throw UpdateError.httpStatus(response.statusCode) }
    }

    private static func fetch(_ url: URL, session: URLSession, maximumSize: Int) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidManifest }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumSize else { throw UpdateError.invalidManifest }
            data.append(byte)
        }
        return (data, response)
    }

    private static func nextPageURL(from response: HTTPURLResponse,
                                    repository: (owner: String, name: String), currentPage: Int) throws -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Link"), !header.isEmpty else { return nil }
        var nextTargets: [String] = []
        for rawLink in header.split(separator: ",") {
            let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
            let parameters = link.split(separator: ";")
            let relations = parameters.compactMap { parameter -> String? in
                let pair = parameter.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == "rel" else {
                    return nil
                }
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            }
            if relations.contains(where: { $0.split(whereSeparator: \.isWhitespace).contains("next") }) {
                guard let open = link.firstIndex(of: "<"), let close = link[open...].firstIndex(of: ">"),
                      close > open else { throw UpdateError.invalidManifest }
                nextTargets.append(String(link[link.index(after: open)..<close]))
            }
        }
        guard !nextTargets.isEmpty else { return nil }
        guard nextTargets.count == 1,
              let linkedURL = URL(string: nextTargets[0]),
              let components = URLComponents(url: linkedURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "api.github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.percentEncodedPath == "/repos/\(repository.owner)/\(repository.name)/releases",
              let queryItems = components.queryItems, queryItems.count == 2,
              Set(queryItems.compactMap(\.name)) == ["page", "per_page"],
              let pageValue = queryItems.first(where: { $0.name == "page" })?.value,
              let linkedPage = Int(pageValue), String(linkedPage) == pageValue,
              linkedPage == currentPage + 1,
              queryItems.first(where: { $0.name == "per_page" })?.value == "100" else {
            throw UpdateError.invalidManifest
        }

        var safe = URLComponents()
        safe.scheme = "https"
        safe.host = "api.github.com"
        safe.path = "/repos/\(repository.owner)/\(repository.name)/releases"
        safe.queryItems = [URLQueryItem(name: "page", value: String(linkedPage)),
                           URLQueryItem(name: "per_page", value: "100")]
        guard let url = safe.url else { throw UpdateError.invalidManifest }
        return url
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
