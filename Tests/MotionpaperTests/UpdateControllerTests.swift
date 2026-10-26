import Foundation
import Testing
import UpdateCore
@testable import Motionpaper

private let autobuildCommit = String(repeating: "b", count: 40)
private let stableCommit = String(repeating: "c", count: 40)
private let checksum = String(repeating: "a", count: 64)
private let autobuildURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases/latest")!
private let stableURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100")!

@Test @MainActor
func autobuildIsAvailableWhileStableCheckIsPending() async throws {
    let state = UpdateControllerURLProtocol.state
    state.reset()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateControllerURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer {
        state.releaseStable(with: Data("[]".utf8))
        session.invalidateAndCancel()
    }

    let directory = FileManager.default.temporaryDirectory
    let service = UpdateService(releaseURL: autobuildURL, currentCommit: String(repeating: "a", count: 40),
                                channel: .autobuild, directory: directory, session: session)
    let stableService = UpdateService(releaseURL: stableURL, currentCommit: "unused", channel: .stable,
                                      directory: directory, session: session)
    let controller = UpdateController(service: service, stableService: stableService, channel: .autobuild)
    var stableChanges: [UpdateManifest?] = []
    controller.onStableReleaseChange = { stableChanges.append($0) }

    controller.start()

    #expect(await waitUntil { state.stableRequestURL != nil })
    #expect(await waitUntil {
        if case .available = controller.state { return true }
        return false
    })
    #expect(state.stableRequestURL == stableURL)
    if case let .available(manifest) = controller.state {
        #expect(manifest.commit == autobuildCommit)
    } else {
        #expect(Bool(false), "The Autobuild result should be available before the stable response.")
    }
    #expect(stableChanges.count == 1)
    #expect(stableChanges.first.flatMap { $0 } == nil)

    state.releaseStable(with: try stableReleaseList())
    #expect(await waitUntil { stableChanges.contains { $0 != nil } })
    #expect(stableChanges.count == 2)
    #expect(stableChanges.last.flatMap { $0?.version?.description } == "1.2.3")

    let shutdown = controller.stop()
    #expect(shutdown != nil)
    if let shutdown { await shutdown.value }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func stableReleaseList() throws -> Data {
    let tag = "v1.2.3"
    let name = "Motionpaper-1.2.3-\(stableCommit.prefix(12)).dmg"
    let release: [String: Any] = [
        "tag_name": tag,
        "target_commitish": stableCommit,
        "published_at": "2026-10-25T00:00:00Z",
        "draft": false,
        "prerelease": false,
        "assets": [[
            "name": name,
            "state": "uploaded",
            "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/\(tag)/\(name)",
            "size": 3,
            "digest": "sha256:\(checksum)",
        ]],
    ]
    return try JSONSerialization.data(withJSONObject: [release])
}

private final class UpdateControllerURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = UpdateControllerURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == autobuildURL.path {
            do { send(try autobuildManifest()) }
            catch { client?.urlProtocol(self, didFailWithError: error) }
        } else {
            Self.state.hold(self, url: request.url)
        }
    }

    override func stopLoading() {}

    func send(_ data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func autobuildManifest() throws -> Data {
        let tag = "Autobuild-\(autobuildCommit)"
        let name = "Motionpaper-\(autobuildCommit.prefix(12)).dmg"
        return try JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "published_at": "2026-10-25T00:00:00Z",
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": name,
                "state": "uploaded",
                "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/\(tag)/\(name)",
                "size": 3,
                "digest": "sha256:\(checksum)",
            ]],
        ])
    }
}

private final class UpdateControllerURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var heldProtocol: UpdateControllerURLProtocol?
    private var releasedBody: Data?
    private var requestedURL: URL?

    var stableRequestURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedURL
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        heldProtocol = nil
        releasedBody = nil
        requestedURL = nil
    }

    func hold(_ loader: UpdateControllerURLProtocol, url: URL?) {
        lock.lock()
        heldProtocol = loader
        requestedURL = url
        let body = releasedBody
        lock.unlock()
        if let body { loader.send(body) }
    }

    func releaseStable(with body: Data) {
        lock.lock()
        releasedBody = body
        let loader = heldProtocol
        heldProtocol = nil
        lock.unlock()
        loader?.send(body)
    }
}
