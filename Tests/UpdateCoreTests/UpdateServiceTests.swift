import Foundation
import Testing
@testable import UpdateCore

private let releaseURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases/latest")!
private let stableListURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100")!
private let commit = String(repeating: "a", count: 40)
private let nextCommit = String(repeating: "b", count: 40)
private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

private func releaseData(commit: String = commit, checksum: String = digest, size: Int = 3,
                         publishedAt: String = "2026-10-25T00:00:00Z", tag: String? = nil,
                         draft: Bool = false, prerelease: Bool = false, assetName: String? = nil,
                         assetState: String = "uploaded", download: String? = nil,
                         assetDigest: String? = nil, additionalAssets: [[String: Any]] = [],
                         body: String? = nil) throws -> Data {
    let tagName = tag ?? "Autobuild-\(commit)"
    let expectedDownload = "https://github.com/notCorwin/Motionpaper/releases/download/\(tagName)/Motionpaper-\(String(commit.prefix(12))).dmg"
    let asset: [String: Any] = [
        "name": assetName ?? "Motionpaper-\(String(commit.prefix(12))).dmg",
        "state": assetState,
        "browser_download_url": download ?? expectedDownload,
        "size": size,
        "digest": assetDigest ?? "sha256:\(checksum)",
    ]
    var release: [String: Any] = [
        "tag_name": tagName,
        "draft": draft,
        "prerelease": prerelease,
        "published_at": publishedAt,
        "assets": [asset] + additionalAssets,
    ]
    if let body { release["body"] = body }
    return try JSONSerialization.data(withJSONObject: release)
}

private func stableRelease(version: String, commit: String = commit, checksum: String = digest, size: Int = 3,
                           publishedAt: String = "2026-10-25T00:00:00Z", tag: String? = nil,
                           draft: Bool = false, prerelease: Bool = false, targetCommit: String? = nil,
                           assetName: String? = nil, assetState: String = "uploaded",
                           download: String? = nil, assetDigest: String? = nil,
                           additionalAssets: [[String: Any]] = []) -> [String: Any] {
    let tagName = tag ?? "v\(version)"
    let target = targetCommit ?? commit
    let name = assetName ?? "Motionpaper-\(version)-\(String(target.prefix(12))).dmg"
    let expectedDownload = "https://github.com/notCorwin/Motionpaper/releases/download/\(tagName)/\(name)"
    let asset: [String: Any] = [
        "name": name,
        "state": assetState,
        "browser_download_url": download ?? expectedDownload,
        "size": size,
        "digest": assetDigest ?? "sha256:\(checksum)",
    ]
    return [
        "tag_name": tagName,
        "target_commitish": target,
        "draft": draft,
        "prerelease": prerelease,
        "published_at": publishedAt,
        "assets": [asset] + additionalAssets,
    ]
}

private func stableJSON(_ releases: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: releases)
}

@Test func manifestBindsGitHubReleaseAndArtifactToRepositoryAndCommit() throws {
    let manifest = try UpdateManifest.decode(try releaseData(), releaseURL: releaseURL)
    #expect(manifest.commit == commit)
    #expect(manifest.shortCommit == "aaaaaaaaaaaa")
    #expect(manifest.size == 3)
    #expect(manifest.sha256 == digest)
    #expect(manifest.downloadURL.absoluteString == "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg")

    for address in [
        "https://example.com/Motionpaper.dmg",
        "https://github.com/another/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg",
        "https://github.com/notCorwin/Motionpaper/releases/latest/download/Motionpaper-aaaaaaaaaaaa.dmg",
        "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg?redirect=1",
    ] {
        #expect(throws: (any Error).self) {
            try UpdateManifest.decode(try releaseData(download: address), releaseURL: releaseURL)
        }
    }

    for invalidURL in [
        "http://api.github.com/repos/notCorwin/Motionpaper/releases/latest",
        "https://github.com/repos/notCorwin/Motionpaper/releases/latest",
        "https://user@api.github.com/repos/notCorwin/Motionpaper/releases/latest",
        "https://api.github.com:443/repos/notCorwin/Motionpaper/releases/latest",
        "https://api.github.com/repos/notCorwin/Motionpaper/releases/latest?preview=1",
        "https://api.github.com/repos/notCorwin/Motionpaper/releases/latest#latest",
        "https://api.github.com/repos/notCorwin/Motionpaper/releases/latest/",
        "https://api.github.com/repos/notCorwin/Motionpaper/releases",
    ] {
        #expect(throws: (any Error).self) {
            try UpdateManifest.decode(try releaseData(), releaseURL: URL(string: invalidURL)!)
        }
    }

    let duplicate = [
        "name": "Motionpaper-aaaaaaaaaaaa.dmg",
        "state": "uploaded",
        "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg",
        "size": 3,
        "digest": "sha256:\(digest)",
    ] as [String: Any]
    let unrelatedAsset = [
        "name": "Motionpaper-symbols.zip",
        "state": "uploaded",
        "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-symbols.zip",
        "size": 1,
    ] as [String: Any]
    #expect(try UpdateManifest.decode(try releaseData(additionalAssets: [unrelatedAsset]), releaseURL: releaseURL).commit == commit)
    for data in [
        try releaseData(commit: "abc"),
        try releaseData(tag: "Autobuild-\(String(repeating: "A", count: 40))"),
        try releaseData(draft: true),
        try releaseData(prerelease: true),
        try releaseData(publishedAt: "not-a-date"),
        try releaseData(assetState: "uploading"),
        try releaseData(assetName: "Motionpaper-other.dmg"),
        try releaseData(assetDigest: digest),
        try releaseData(assetDigest: "sha256:bad"),
        try releaseData(checksum: "bad"),
        try releaseData(size: 0),
        try releaseData(additionalAssets: [duplicate]),
        try releaseData(body: String(repeating: "x", count: 66_000)),
    ] {
        #expect(throws: (any Error).self) {
            try UpdateManifest.decode(data, releaseURL: releaseURL)
        }
    }
}

@Test func stableManifestValidatesVersionCommitDigestAndExactRepositoryArtifact() throws {
    let data = try JSONSerialization.data(withJSONObject: stableRelease(version: "1.2.3"))
    let manifest = try UpdateManifest.decodeStableRelease(data, releaseURL: stableListURL)
    #expect(manifest.version?.description == "1.2.3")
    #expect(manifest.commit == commit)
    #expect(manifest.publishedAt == ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z"))
    #expect(manifest.downloadURL.absoluteString == "https://github.com/notCorwin/Motionpaper/releases/download/v1.2.3/Motionpaper-1.2.3-aaaaaaaaaaaa.dmg")

    for release in [
        stableRelease(version: "1.2.3", tag: "v1.2.3-rc.1"),
        stableRelease(version: "1.2.3", targetCommit: String(commit.prefix(12))),
        stableRelease(version: "1.2.3", targetCommit: String(repeating: "A", count: 40)),
        stableRelease(version: "1.2.3", assetDigest: "sha256:BAD"),
        stableRelease(version: "1.2.3", download: "https://github.com/another/Motionpaper/releases/download/v1.2.3/Motionpaper-1.2.3-aaaaaaaaaaaa.dmg"),
        stableRelease(version: "1.2.3", download: "https://github.com/notCorwin/Motionpaper/releases/download/v1.2.4/Motionpaper-1.2.3-aaaaaaaaaaaa.dmg"),
        stableRelease(version: "1.2.3", assetName: "Motionpaper-1.2.3.dmg"),
        stableRelease(version: "1.2.3", size: 0),
        stableRelease(version: "1.2.3", assetState: "uploading"),
        stableRelease(version: "1.2.3", publishedAt: "not-a-date"),
        stableRelease(version: "1.2.3", draft: true),
        stableRelease(version: "1.2.3", prerelease: true),
    ] {
        #expect(throws: (any Error).self) {
            try UpdateManifest.decodeStableRelease(JSONSerialization.data(withJSONObject: release), releaseURL: stableListURL)
        }
    }

    #expect(throws: (any Error).self) {
        try UpdateManifest.decodeStableRelease(data,
            releaseURL: URL(string: "https://api.github.com/repos/another/Motionpaper/releases?per_page=100")!)
    }
    #expect(throws: (any Error).self) {
        try UpdateManifest.decodeStableRelease(data, releaseURL: releaseURL)
    }
}

@Test func releaseVersionUsesStrictNumericSemanticOrdering() {
    #expect(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.99")!)
    #expect(ReleaseVersion("2.0.0")! > ReleaseVersion("1.99.99")!)
    #expect(ReleaseVersion("1.2.3") == ReleaseVersion("1.2.3"))
    for invalid in ["1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1.2.3-rc.1", "1.2.x", " 1.2.3"] {
        #expect(ReleaseVersion(invalid) == nil)
    }
}

@Test func downloadValidationRejectsTamperingAndReusesVerifiedCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = try UpdateManifest.decode(try releaseData(), releaseURL: releaseURL)
    let file = directory.appendingPathComponent("\(commit)-\(digest).dmg")
    try Data("abc".utf8).write(to: file)
    #expect(try UpdateService.verify(file, manifest: manifest))

    // A valid cache must work without any network access.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = UpdateService(releaseURL: releaseURL, currentCommit: "other", directory: directory,
                                session: session)
    #expect(try await service.download(manifest) == file)
    try Data("abd".utf8).write(to: file)
    #expect(try !UpdateService.verify(file, manifest: manifest))
    try Data("ab".utf8).write(to: file)
    #expect(try !UpdateService.verify(file, manifest: manifest))
}

@Test func checkingComparesFullCommitAndRejectsHTTPFailuresAndUncached304() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let current = UpdateService(releaseURL: releaseURL, currentCommit: commit, directory: FileManager.default.temporaryDirectory,
                                session: session)
    #expect(try await current.check() == nil)

    // Matching the 12-character display prefix is not enough to treat a release as current.
    let samePrefixDifferentCommit = String(commit.prefix(12)) + String(repeating: "b", count: 28)
    let older = UpdateService(releaseURL: releaseURL, currentCommit: samePrefixDifferentCommit,
                              directory: FileManager.default.temporaryDirectory, session: session)
    #expect(try await older.check()?.commit == commit)

    let failureConfiguration = URLSessionConfiguration.ephemeral
    failureConfiguration.protocolClasses = [HTTPStatusProtocol.self]
    let failureSession = URLSession(configuration: failureConfiguration)
    defer { failureSession.invalidateAndCancel() }
    let failing = UpdateService(releaseURL: releaseURL, currentCommit: commit,
                                directory: FileManager.default.temporaryDirectory, session: failureSession)
    HTTPStatusProtocol.setResponse(status: 200, body: try releaseData())
    #expect(try await failing.check() == nil)
    for status in [404, 500, 304] {
        HTTPStatusProtocol.setResponse(status: status, body: Data())
        await #expect(throws: UpdateError.self) { try await failing.check() }
    }
}

@Test func repeatedChecksFetchLatestReleaseWithoutConditionalCaching() async throws {
    RefreshProtocol.configure([
        .init(status: 200, body: try releaseData(commit: commit)),
        .init(status: 200, body: try releaseData(commit: commit)),
        .init(status: 200, body: try releaseData(commit: nextCommit)),
    ])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RefreshProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = UpdateService(releaseURL: releaseURL, currentCommit: commit,
                                directory: FileManager.default.temporaryDirectory, session: session)

    #expect(try await service.check() == nil)
    #expect(try await service.check() == nil)
    #expect(try await service.check()?.commit == nextCommit)

    let requests = RefreshProtocol.recordedRequests()
    #expect(requests.count == 3)
    #expect(requests.map(\.cachePolicy) == Array(repeating: .reloadIgnoringLocalAndRemoteCacheData, count: 3))
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28" })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    #expect(requests.allSatisfy { $0.url == releaseURL })
}

@Test func concurrentChecksShareOneRequest() async throws {
    CoalescingProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoalescingProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = UpdateService(releaseURL: releaseURL, currentCommit: "other",
                                directory: FileManager.default.temporaryDirectory, session: session)

    async let first = service.check()
    async let second = service.check()
    async let third = service.check()
    let results = try await [first, second, third]
    #expect(results.compactMap { $0?.commit } == Array(repeating: commit, count: 3))
    #expect(CoalescingProtocol.requestCount() == 1)
}

@Test func stableDiscoveryPaginatesSelectsHighestVersionAndAppliesChannelRules() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StableReleaseProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    var firstPage = [
        stableRelease(version: "2.10.0", publishedAt: "2026-10-26T00:00:00Z"),
        stableRelease(version: "100.0.0", prerelease: true),
        stableRelease(version: "101.0.0", draft: true),
        ["tag_name": "Autobuild-\(commit)", "draft": false, "prerelease": false],
    ]
    firstPage += (0..<96).map { index in
        ["tag_name": "Autobuild-\(String(format: "%040x", index + 1))", "draft": false, "prerelease": false]
    }
    let pageTwoRelease = stableRelease(version: "10.2.3", publishedAt: "2025-01-01T00:00:00Z")
    let nextPage = "https://api.github.com/repos/notCorwin/Motionpaper/releases?page=2&per_page=100"
    StableReleaseProtocol.configure([
        .init(status: 200, body: try stableJSON(firstPage), headers: ["Link": "<\(nextPage)>; rel=\"next\""]),
        .init(status: 200, body: try stableJSON([pageTwoRelease]), headers: [:]),
    ])

    let migration = UpdateService(releaseURL: stableListURL, currentCommit: commit, channel: .stable,
                                  directory: FileManager.default.temporaryDirectory, session: session)
    let discovered = try await migration.check()
    #expect(discovered?.version == ReleaseVersion("10.2.3"))
    #expect(discovered?.commit == commit) // A same-commit stable release is offered to Autobuild users.

    let requests = StableReleaseProtocol.recordedRequests()
    #expect(requests.map(\.url?.absoluteString) == [stableListURL.absoluteString, nextPage])
    #expect(requests.allSatisfy { $0.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache" })

    StableReleaseProtocol.configure([.init(status: 200, body: try stableJSON([pageTwoRelease]), headers: [:])])
    let upgradeSameCommit = UpdateService(releaseURL: stableListURL, currentCommit: commit, currentVersion: "10.2.2",
                                          channel: .stable, directory: FileManager.default.temporaryDirectory,
                                          session: session)
    #expect(try await upgradeSameCommit.check()?.version == ReleaseVersion("10.2.3"))

    StableReleaseProtocol.configure([.init(status: 200, body: try stableJSON([pageTwoRelease]), headers: [:])])
    let current = UpdateService(releaseURL: stableListURL, currentCommit: commit, currentVersion: "10.2.3",
                                channel: .stable, directory: FileManager.default.temporaryDirectory,
                                session: session)
    #expect(try await current.check() == nil)

    StableReleaseProtocol.configure([.init(status: 200, body: try stableJSON([pageTwoRelease]), headers: [:])])
    let newerInstalled = UpdateService(releaseURL: stableListURL, currentCommit: nextCommit, currentVersion: "10.3.0",
                                       channel: .stable, directory: FileManager.default.temporaryDirectory,
                                       session: session)
    #expect(try await newerInstalled.check() == nil)

    // GitHub may end on a full page without a next relation; the Link header defines the end.
    StableReleaseProtocol.configure([.init(status: 200, body: try stableJSON(firstPage), headers: [:])])
    let fullTerminalPage = UpdateService(releaseURL: stableListURL, currentCommit: "other", currentVersion: "1.0.0",
                                         channel: .stable, directory: FileManager.default.temporaryDirectory,
                                         session: session)
    #expect(try await fullTerminalPage.check()?.version == ReleaseVersion("2.10.0"))

    // A next relation pointing outside the exact repository endpoint is rejected and never fetched.
    let foreignNext = "https://api.github.com/repos/another/Motionpaper/releases?page=2&per_page=100"
    StableReleaseProtocol.configure([.init(status: 200, body: try stableJSON(firstPage),
                                           headers: ["Link": "<\(foreignNext)>; rel=\"next\""])])
    let rejectsForeignPage = UpdateService(releaseURL: stableListURL, currentCommit: "other", channel: .stable,
                                           directory: FileManager.default.temporaryDirectory, session: session)
    await #expect(throws: UpdateError.self) { try await rejectsForeignPage.check() }
    #expect(StableReleaseProtocol.recordedRequests().count == 1)

    StableReleaseProtocol.configure([
        .init(status: 200, body: try stableJSON([stableRelease(version: "1.0.0")]), headers: [:]),
        .init(status: 500, body: Data(), headers: [:]),
    ])
    let freshCheck = UpdateService(releaseURL: stableListURL, currentCommit: "other", channel: .stable,
                                  directory: FileManager.default.temporaryDirectory, session: session)

    #expect(try await freshCheck.check()?.version == ReleaseVersion("1.0.0"))
    await #expect(throws: UpdateError.self) { try await freshCheck.check() }
    #expect(StableReleaseProtocol.recordedRequests().count == 2)
}

private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? releaseData()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HTTPStatusProtocol: URLProtocol, @unchecked Sendable {
    private static let state = HTTPStatusState()

    static func setResponse(status: Int, body: Data) { state.setResponse(status: status, body: body) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.response
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class HTTPStatusState: @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private var currentResponse = StubResponse(status: 500, body: Data())

    var response: StubResponse {
        lock.lock()
        defer { lock.unlock() }
        return currentResponse
    }

    func setResponse(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        currentResponse = StubResponse(status: status, body: body)
    }
}

private final class RefreshProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let body: Data
    }

    private static let state = RefreshProtocolState()

    static func configure(_ responses: [StubResponse]) { state.configure(responses) }
    static func recordedRequests() -> [URLRequest] { state.recordedRequests() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let stub = Self.state.nextResponse(for: request)
        guard let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                             headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RefreshProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [RefreshProtocol.StubResponse] = []
    private var requests: [URLRequest] = []

    func configure(_ responses: [RefreshProtocol.StubResponse]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        requests = []
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func nextResponse(for request: URLRequest) -> RefreshProtocol.StubResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return responses[min(requests.count - 1, responses.count - 1)]
    }
}

private final class CoalescingProtocol: URLProtocol, @unchecked Sendable {
    private static let state = CoalescingProtocolState()

    static func reset() { state.reset() }
    static func requestCount() -> Int { state.requestCount }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.recordRequest()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: (try? releaseData()) ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private final class StableReleaseProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private static let state = StableReleaseState()

    static func configure(_ responses: [StubResponse]) { state.configure(responses) }
    static func recordedRequests() -> [URLRequest] { state.recordedRequests() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.nextResponse(for: request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                             headerFields: stub.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StableReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StableReleaseProtocol.StubResponse] = []
    private var requests: [URLRequest] = []

    func configure(_ responses: [StableReleaseProtocol.StubResponse]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        requests = []
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func nextResponse(for request: URLRequest) -> StableReleaseProtocol.StubResponse {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return responses[min(requests.count - 1, responses.count - 1)]
    }
}

private final class CoalescingProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordRequest() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }
}
