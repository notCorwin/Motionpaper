import Foundation
import Synchronization
import Testing
@testable import UpdateCore

@Suite(.serialized)
struct UpdateNetworkTests {
    @Test
    func concurrentChannelsRecoverIndependentlyFromTransientFailures() async throws {
        let fixture = try NetworkFixture(responses: [
            .failure(.networkConnectionLost), .http(status: 503), .http(body: feed),
        ])
        defer { fixture.cleanUp() }

        async let autobuild = fixture.service.check()
        async let stable = fixture.service.check(channel: .stable)
        let results = try await (autobuild, stable)

        #expect(results.0?.commit == networkCommit)
        #expect(results.1 == nil)
        #expect(NetworkProtocol.requests.count == 4)
        #expect(NetworkProtocol.requests.filter { $0.url == networkFeedURL }.count == 2)
        #expect(NetworkProtocol.requests.filter { $0.url?.path.contains("latest") == true }.count == 2)
    }

    @Test(arguments: [304, 401, 403, 422])
    func permanentHTTPFailuresAreNotRetried(status: Int) async throws {
        let fixture = try NetworkFixture(responses: [.http(status: status), .http(body: feed)])
        defer { fixture.cleanUp() }

        await #expect(throws: UpdateError.self) { try await fixture.service.check() }
        #expect(NetworkProtocol.requests.count == 1)
    }

    @Test
    func missingAutobuildManifestRetriesAnAssetReplacementWindow() async throws {
        let fixture = try NetworkFixture(responses: [.http(status: 404), .http(body: feed)])
        defer { fixture.cleanUp() }
        #expect(try await fixture.service.check()?.commit == networkCommit)
        #expect(NetworkProtocol.requests.count == 2)
    }

    @Test
    func missingManifestHasABoundedRetryBudget() async throws {
        let fixture = try NetworkFixture(responses: [.http(status: 404)])
        defer { fixture.cleanUp() }
        await #expect(throws: UpdateError.self) { try await fixture.service.check() }
        #expect(NetworkProtocol.requests.count == 3)
    }

    @Test
    func missingDMGIsNotRetried() async throws {
        let fixture = try NetworkFixture(responses: [.http(status: 404)])
        defer { fixture.cleanUp() }
        await #expect(throws: UpdateError.self) { try await fixture.service.withDownloadedImage(networkManifest()) { try UpdateService.verify($0, manifest: networkManifest()) } }
        #expect(NetworkProtocol.requests.count == 1)
    }

    @Test(arguments: ["120", "invalid", "-1", "inf"])
    func longOrInvalidServerRetryDelaysFailPromptly(retryAfter: String) async throws {
        let fixture = try NetworkFixture(responses: [
            .http(status: 429, headers: ["Retry-After": retryAfter]), .http(body: feed),
        ])
        defer { fixture.cleanUp() }

        await #expect(throws: UpdateError.self) { try await fixture.service.check() }
        #expect(NetworkProtocol.requests.count == 1)
    }

    @Test
    func shortServerRetryDelayIsRespected() async throws {
        let fixture = try NetworkFixture(responses: [
            .http(status: 429, headers: ["Retry-After": "2"]), .http(body: feed),
        ])
        defer { fixture.cleanUp() }
        let started = ContinuousClock.now

        #expect(try await fixture.service.check()?.commit == networkCommit)
        #expect(ContinuousClock.now - started >= .seconds(2))
        #expect(NetworkProtocol.requests.count == 2)
    }

    @Test
    func retryBudgetIsBoundedAndAFreshCheckCanRecover() async throws {
        let fixture = try NetworkFixture(responses: [
            .http(status: 500), .http(status: 502), .http(status: 504), .http(body: feed),
        ])
        defer { fixture.cleanUp() }

        await #expect(throws: UpdateError.self) { try await fixture.service.check() }
        #expect(NetworkProtocol.requests.count == 3)
        #expect(try await fixture.service.check()?.commit == networkCommit)
        #expect(NetworkProtocol.requests.count == 4)
    }

    @Test(arguments: [false, true])
    func cancellationInterruptsBackoffAndAllowsAFreshRequest(downloading: Bool) async throws {
        let fixture = try NetworkFixture(responses: [
            .http(status: 503, headers: ["Retry-After": "30"]),
            .http(body: downloading ? Data("abc".utf8) : feed),
        ])
        defer { fixture.cleanUp() }
        let request = Task {
            if downloading {
                _ = try await fixture.service.withDownloadedImage(networkManifest()) { try UpdateService.verify($0, manifest: networkManifest()) }
            } else {
                _ = try await fixture.service.check()
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while NetworkProtocol.requests.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NetworkProtocol.requests.count == 1)
        await fixture.service.cancel()

        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(NetworkProtocol.requests.count == 1)
        if downloading {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
            #expect(try await fixture.service.withDownloadedImage(networkManifest()) { try UpdateService.verify($0, manifest: networkManifest()) })
        } else {
            #expect(try await fixture.service.check()?.commit == networkCommit)
        }
        #expect(NetworkProtocol.requests.count == 2)
    }

    @Test
    func malformedFeedIsNotRetried() async throws {
        let fixture = try NetworkFixture(responses: [.http(body: Data("invalid".utf8)), .http(body: feed)])
        defer { fixture.cleanUp() }

        await #expect(throws: UpdateError.self) { try await fixture.service.check() }
        #expect(NetworkProtocol.requests.count == 1)
    }

    @Test
    func downloadsShareOnlyInFlightDataAndLeaveNoCache() async throws {
        let fixture = try NetworkFixture(responses: [
            .http(status: 503, body: Data("Service unavailable".utf8)), .http(body: Data("abc".utf8)),
        ])
        defer { fixture.cleanUp() }
        let manifest = networkManifest()
        async let first = fixture.service.withDownloadedImage(manifest) { url in
            try await Task.sleep(for: .milliseconds(100))
            return try UpdateService.verify(url, manifest: manifest)
        }
        async let second = fixture.service.withDownloadedImage(manifest) { url in
            try await Task.sleep(for: .milliseconds(150))
            return try UpdateService.verify(url, manifest: manifest)
        }
        let result = try await (first, second)
        #expect(result.0 && result.1)
        #expect(NetworkProtocol.requests.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
        #expect(try await fixture.service.withDownloadedImage(manifest) { try UpdateService.verify($0, manifest: manifest) })
        #expect(NetworkProtocol.requests.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test
    func temporaryImageIsRemovedAfterOperationFailure() async throws {
        let fixture = try NetworkFixture(responses: [.http(body: Data("abc".utf8))])
        defer { fixture.cleanUp() }
        await #expect(throws: UpdateError.self) {
            try await fixture.service.withDownloadedImage(networkManifest()) { _ -> Bool in throw UpdateError.invalidApplication }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test
    func staleCleanupRemovesAbandonedImagesButPreservesActiveDownload() async throws {
        let fixture = try NetworkFixture(responses: [.http(body: Data("abc".utf8))])
        defer { fixture.cleanUp() }
        let abandoned = fixture.directory.appendingPathComponent("download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: abandoned.appendingPathComponent("image.dmg"))
        let service = fixture.service
        let valid = try await service.withDownloadedImage(networkManifest()) { image in
            try await service.removeStaleDownloads()
            return try UpdateService.verify(image, manifest: networkManifest())
        }
        #expect(valid)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    @Test(arguments: ["abd", "ab", "abcd"])
    func invalidDownloadsAreNotRetriedOrCached(body: String) async throws {
        let fixture = try NetworkFixture(responses: [.http(body: Data(body.utf8)), .http(body: Data("abc".utf8))])
        defer { fixture.cleanUp() }

        await #expect(throws: UpdateError.self) { try await fixture.service.withDownloadedImage(networkManifest()) { try UpdateService.verify($0, manifest: networkManifest()) } }
        #expect(NetworkProtocol.requests.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }
}

private let networkFeedURL = URL(string: "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json")!
private let networkCommit = String(repeating: "b", count: 40)
private let networkDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let feed = Data("""
{"autobuild":{"commit":"\(networkCommit)","publishedAt":"2026-10-28T00:00:00Z","size":3,"sha256":"\(networkDigest)",
"downloadURL":"https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/Motionpaper-bbbbbbbbbbbb.dmg"}}
""".utf8)

private func networkManifest() -> UpdateManifest {
    UpdateManifest(commit: networkCommit, publishedAt: Date(),
                   downloadURL: URL(string: "https://github.com/notCorwin/Motionpaper/update.dmg")!,
                   sha256: networkDigest, size: 3)
}

private struct NetworkFixture {
    let directory: URL
    let session: URLSession
    let service: UpdateService

    init(responses: [NetworkProtocol.Response]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateNetworkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        NetworkProtocol.configure(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkProtocol.self]
        session = URLSession(configuration: configuration)
        service = UpdateService(feedURL: networkFeedURL, currentCommit: "other", directory: directory, session: session)
    }

    func cleanUp() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class NetworkProtocol: URLProtocol, @unchecked Sendable {
    enum Response: Sendable {
        case http(status: Int = 200, body: Data = Data(), headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private struct Script {
        let responses: [Response]
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(Script(responses: []))
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func configure(_ responses: [Response]) { state.withLock { $0 = Script(responses: responses) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.state.withLock { script in
            script.requests.append(request)
            return script.responses[min(script.requests.count - 1, script.responses.count - 1)]
        }
        switch response {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let body, var headers):
            headers["Content-Length"] = String(body.count)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
