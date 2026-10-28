import Foundation
import Synchronization
import Testing
@testable import UpdateCore

private let feedURL = URL(string: "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json")!
private let stableFeedURL = URL(string: "https://github.com/notCorwin/Motionpaper/releases/latest/download/update.json")!
private let commit = String(repeating: "a", count: 40)
private let nextCommit = String(repeating: "b", count: 40)
private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

private func entry(commit: String = commit, version: String? = nil) -> [String: Any] {
    let tag = version.map { "v\($0)" } ?? "Autobuild"
    let name = version.map { "Motionpaper-v\($0).dmg" } ?? "Motionpaper-\(commit.prefix(12)).dmg"
    var result: [String: Any] = [
        "commit": commit, "publishedAt": "2026-10-28T00:00:00Z", "sha256": digest, "size": 3,
        "downloadURL": "https://github.com/notCorwin/Motionpaper/releases/download/\(tag)/\(name)",
    ]
    if let version { result["version"] = version }
    return result
}

private func feedData(autobuild: [String: Any]? = entry(), stable: [String: Any]? = entry(version: "1.2.3")) throws -> Data {
    var feed: [String: Any] = [:]
    if let autobuild { feed["autobuild"] = autobuild }
    if let stable { feed["stable"] = stable }
    return try JSONSerialization.data(withJSONObject: feed)
}

@Suite(.serialized)
struct UpdateServiceTests {
    @Test
    func staticFeedBindsBothChannelsToExactRepositoryArtifacts() throws {
        let feed = try UpdateFeed(data: feedData(), url: feedURL)
        #expect(feed.autobuild?.commit == commit)
        #expect(feed.autobuild?.shortCommit == "aaaaaaaaaaaa")
        #expect(feed.autobuild?.version == nil)
        #expect(feed.stable?.version == ReleaseVersion("1.2.3"))
        #expect(feed.stable?.sha256 == digest)
        #expect(feed.stable?.size == 3)
        #expect(feed.stable?.downloadURL.lastPathComponent == "Motionpaper-v1.2.3.dmg")

        var fractionalDate = entry()
        fractionalDate["publishedAt"] = "2026-10-28T00:00:00.123Z"
        #expect(try UpdateFeed(data: feedData(autobuild: fractionalDate), url: feedURL).autobuild != nil)
    }

    @Test
    func malformedFeedsAndUnboundArtifactsAreRejected() throws {
        let invalidFields: [(String, Any)] = [
            ("commit", String(repeating: "a", count: 39)), ("commit", "../outside"),
            ("sha256", String(repeating: "A", count: 64)), ("size", 0), ("size", -1), ("size", 1.5),
            ("publishedAt", "yesterday"), ("version", "1.2.3"),
            ("downloadURL", "https://example.com/Motionpaper.dmg"),
            ("downloadURL", "https://github.com/another/Motionpaper/releases/download/Autobuild/Motionpaper-aaaaaaaaaaaa.dmg"),
            ("downloadURL", "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-obsolete/Motionpaper-aaaaaaaaaaaa.dmg"),
            ("downloadURL", "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/Motionpaper-bbbbbbbbbbbb.dmg"),
            ("downloadURL", "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/Motionpaper-aaaaaaaaaaaa.dmg?redirect=1"),
        ]
        for (field, value) in invalidFields {
            var invalid = entry()
            invalid[field] = value
            #expect(throws: UpdateError.self) { try UpdateFeed(data: feedData(autobuild: invalid), url: feedURL) }
        }
        var stable = entry(version: "1.2.3")
        stable.removeValue(forKey: "version")
        #expect(throws: UpdateError.self) { try UpdateFeed(data: feedData(stable: stable), url: feedURL) }
        for version in ["v1.2.3", "1.2", "01.2.3", "1.2.3-beta.1"] {
            #expect(throws: UpdateError.self) { try UpdateFeed(data: feedData(stable: entry(version: version)), url: feedURL) }
        }
        for data in [Data("not JSON".utf8), Data("[]".utf8), Data("{}".utf8), Data(repeating: 32, count: 16_385)] {
            #expect(throws: UpdateError.self) { try UpdateFeed(data: data, url: feedURL) }
        }
        for address in [
            "http://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json",
            "https://github.com/notCorwin/Motionpaper/releases/download/Other/update.json",
            "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json?cache=1",
            "https://user@github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json",
            "https://github.com:443/notCorwin/Motionpaper/releases/download/Autobuild/update.json",
            "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json#fragment",
        ] {
            #expect(throws: UpdateError.self) { try UpdateFeed(data: feedData(), url: URL(string: address)!) }
        }
    }

    @Test
    func releaseVersionUsesStrictNumericSemanticOrdering() {
        #expect(ReleaseVersion("1.2.3")?.description == "1.2.3")
        #expect(ReleaseVersion("2.9.0")! < ReleaseVersion("2.10.0")!)
        #expect(ReleaseVersion("2.10.0")! < ReleaseVersion("10.0.0")!)
        #expect(ReleaseVersion("99999999999999999999.0.0")! > ReleaseVersion("10.0.0")!)
        for version in ["1", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "-1.2.3", "1.2.3\n"] {
            #expect(ReleaseVersion(version) == nil)
        }
    }

    @Test
    func channelsCompareFullCommitsAndStableVersionsIndependently() async throws {
        let fixture = Fixture(responses: [.init(body: try feedData())])
        defer { fixture.close() }
        #expect(try await fixture.service(currentCommit: commit).check() == nil)
        let samePrefix = String(commit.prefix(12)) + String(repeating: "b", count: 28)
        #expect(try await fixture.service(currentCommit: samePrefix).check()?.commit == commit)
        #expect(try await fixture.service(currentCommit: commit).check(channel: .stable)?.version == ReleaseVersion("1.2.3"))
        #expect(try await fixture.service(currentVersion: "1.2.2", channel: .stable).check()?.version == ReleaseVersion("1.2.3"))
        #expect(try await fixture.service(currentVersion: "1.2.3", channel: .stable).check() == nil)
        #expect(try await fixture.service(currentVersion: "1.3.0", channel: .stable).check() == nil)
    }

    @Test
    func absentChannelsHaveExplicitMeaning() async throws {
        let fixture = Fixture(responses: [.init(body: try feedData(stable: nil))])
        defer { fixture.close() }
        #expect(try await fixture.service().check(channel: .stable) == nil)
        await #expect(throws: UpdateError.self) { try await fixture.service(currentVersion: "1.0.0", channel: .stable).check() }
        FeedProtocol.configure([.init(body: try feedData(autobuild: nil))])
        await #expect(throws: UpdateError.self) { try await fixture.service().check() }
        #expect(try await fixture.service(channel: .stable).check()?.version == ReleaseVersion("1.2.3"))
    }

    @Test
    func concurrentChecksCoalesceWithinEachChannelAndUseTheirOwnRelease() async throws {
        let fixture = Fixture(responses: [.init(body: try feedData())])
        defer { fixture.close() }
        let service = fixture.service()
        async let first = service.check()
        async let second = service.check()
        async let stable = service.check(channel: .stable)
        let results = try await (first, second, stable)
        #expect(results.0?.commit == commit)
        #expect(results.1 == results.0)
        #expect(results.2?.version == ReleaseVersion("1.2.3"))
        #expect(FeedProtocol.requests.count == 2)
        #expect(Set(FeedProtocol.requests.compactMap(\.url)) == Set([feedURL, stableFeedURL]))
    }

    @Test
    func missingStableReleaseIsAbsentForAutobuildButAnErrorForInstalledStable() async throws {
        let fixture = Fixture(responses: [.init(status: 404)])
        defer { fixture.close() }
        #expect(try await fixture.service().check(channel: .stable) == nil)
        await #expect(throws: UpdateError.self) {
            try await fixture.service(currentVersion: "1.0.0", channel: .stable).check()
        }
        #expect(FeedProtocol.requests.count == 2)
        #expect(FeedProtocol.requests.allSatisfy { $0.url == stableFeedURL })
    }

    @Test
    func checksFetchFreshFeedsWithoutValidators() async throws {
        let fixture = Fixture(responses: [
            .init(body: try feedData(), headers: ["ETag": "\"first\""]),
            .init(body: try feedData(autobuild: entry(commit: nextCommit))),
            .init(status: 304),
        ])
        defer { fixture.close() }
        let service = fixture.service(currentCommit: commit)
        #expect(try await service.check() == nil)
        #expect(try await service.check()?.commit == nextCommit)
        await #expect(throws: UpdateError.self) { try await service.check() }
        #expect(FeedProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
        #expect(FeedProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store" })
    }

    @Test(arguments: [false, true])
    func cancelledCallersNeverStartRequests(downloading: Bool) async throws {
        let fixture = Fixture(responses: [.init(body: try feedData())])
        defer { fixture.close() }
        let service = fixture.service()
        let manifest = try #require(UpdateFeed(data: feedData(), url: feedURL).autobuild)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            if downloading { _ = try await service.withDownloadedImage(manifest) { _ in true } }
            else { _ = try await service.check() }
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(FeedProtocol.requests.isEmpty)
    }

    @Test
    func cancelledWaiterCannotSucceedOrCancelAnotherChannelsCheck() async throws {
        let fixture = Fixture(responses: [.init(body: try feedData())])
        defer { fixture.close() }
        let service = fixture.service()
        let cancelled = Task { try await service.check() }
        let deadline = ContinuousClock.now + .seconds(2)
        while FeedProtocol.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(FeedProtocol.requests.count == 1)
        async let stable = service.check(channel: .stable)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await stable?.version == ReleaseVersion("1.2.3"))
        #expect(FeedProtocol.requests.count == 2)
    }

    @Test
    func unchecked304AndOversizedFeedsAreRejected() async throws {
        for response in [FeedProtocol.Response(status: 304), .init(body: Data(repeating: 32, count: 16_385))] {
            let fixture = Fixture(responses: [response])
            defer { fixture.close() }
            await #expect(throws: UpdateError.self) { try await fixture.service().check() }
            #expect(FeedProtocol.requests.count == 1)
        }
    }
}

private struct Fixture {
    let session: URLSession

    init(responses: [FeedProtocol.Response]) {
        FeedProtocol.configure(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedProtocol.self]
        session = URLSession(configuration: configuration)
    }

    func service(currentCommit: String = "other", currentVersion: String? = nil,
                 channel: UpdateChannel = .autobuild) -> UpdateService {
        UpdateService(feedURL: feedURL, currentCommit: currentCommit, currentVersion: currentVersion,
                      channel: channel, directory: FileManager.default.temporaryDirectory, session: session)
    }

    func close() { session.invalidateAndCancel() }
}

private final class FeedProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
    }
    private struct Script {
        var responses: [Response] = []
        var requests: [URLRequest] = []
    }
    private static let state = Mutex(Script())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func configure(_ responses: [Response]) { state.withLock { $0 = Script(responses: responses) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var response = Self.state.withLock { script in
            script.requests.append(request)
            return script.responses[min(script.requests.count - 1, script.responses.count - 1)]
        }
        guard let url = request.url else { return }
        if response.status == 200,
           let document = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           document["autobuild"] != nil && document["stable"] != nil {
            let channel = url == stableFeedURL ? "stable" : "autobuild"
            response.body = (try? JSONSerialization.data(withJSONObject: [channel: document[channel]!])) ?? response.body
        }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else { return }
        let body = response.body
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
