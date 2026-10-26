import CryptoKit
import Foundation

public actor UpdateService {
    private let releaseURL: URL
    private let currentCommit: String
    private let currentVersion: String?
    private let channel: UpdateChannel
    private let session: URLSession
    private let directory: URL
    private var checkRequest: Task<UpdateManifest?, any Error>?
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

    public func check() async throws -> UpdateManifest? {
        if let checkRequest { return try await checkRequest.value }
        let request = Task { [session, releaseURL, currentCommit, currentVersion, channel] in
            switch channel {
            case .autobuild:
                let (data, _) = try await Self.fetch(releaseURL, session: session, maximumSize: 65_536)
                let manifest = try UpdateManifest.decode(data, releaseURL: releaseURL)
                return manifest.commit == currentCommit ? nil : manifest
            case .stable:
                return try await Self.checkStable(releaseURL: releaseURL, currentVersion: currentVersion,
                                                  session: session)
            }
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
            guard data.count < maximumSize else { throw UpdateError.invalidManifest }
            data.append(byte)
        }
        return (data, response)
    }

    private static func checkStable(releaseURL: URL, currentVersion: String?, session: URLSession) async throws -> UpdateManifest? {
        guard let repository = UpdateManifest.stableRepository(in: releaseURL) else {
            throw UpdateError.invalidManifest
        }

        var pageURL = releaseURL
        var page = 1
        var bestVersion: ReleaseVersion?
        var bestRelease: Data?

        while true {
            let (data, response) = try await fetch(pageURL, session: session, maximumSize: 1_048_576)
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  releases.count <= 100 else { throw UpdateError.invalidManifest }

            for release in releases {
                guard let draft = release["draft"] as? Bool,
                      let prerelease = release["prerelease"] as? Bool else { throw UpdateError.invalidManifest }
                guard !draft, !prerelease,
                      let tag = release["tag_name"] as? String,
                      tag.hasPrefix("v"),
                      let version = ReleaseVersion(String(tag.dropFirst())) else { continue }
                if bestVersion == nil || version > bestVersion! {
                    bestVersion = version
                    bestRelease = try JSONSerialization.data(withJSONObject: release)
                }
            }

            guard let nextPage = try nextPageURL(from: response, repository: repository, currentPage: page) else {
                break
            }
            pageURL = nextPage
            page += 1
        }

        guard let bestRelease else { return nil }
        let manifest = try UpdateManifest.decodeStableRelease(bestRelease, releaseURL: releaseURL)
        guard let currentVersion else { return manifest }
        guard let current = ReleaseVersion(currentVersion), let latest = manifest.version else {
            throw UpdateError.invalidManifest
        }
        return latest > current ? manifest : nil
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
                let target = String(link[link.index(after: open)..<close])
                nextTargets.append(target)
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
