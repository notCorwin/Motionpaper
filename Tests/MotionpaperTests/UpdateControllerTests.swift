import Foundation
import Testing
import UpdateCore
@testable import Motionpaper

private let autobuildCommit = String(repeating: "b", count: 40)
private let stableCommit = String(repeating: "c", count: 40)
private let checksum = String(repeating: "a", count: 64)
private let catalogURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100")!

@Test @MainActor
func controllerChecksBothChannelsFromOneCatalogRequest() async throws {
    let state = UpdateControllerURLProtocol.state
    state.reset(with: try releasesCatalog())

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateControllerURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let service = UpdateService(releaseURL: catalogURL, currentCommit: String(repeating: "a", count: 40),
                                channel: .autobuild, directory: FileManager.default.temporaryDirectory,
                                session: session)
    let controller = UpdateController(service: service, channel: .autobuild)
    var stableChanges: [UpdateManifest?] = []
    controller.onStableReleaseChange = { stableChanges.append($0) }

    controller.start()

    let resultsArrived = await waitUntil {
        guard stableChanges.contains(where: { $0?.version?.description == "1.2.3" }) else { return false }
        if case .available = controller.state { return true }
        return false
    }
    #expect(resultsArrived)
    if case let .available(manifest) = controller.state {
        #expect(manifest.commit == autobuildCommit)
    } else {
        #expect(Bool(false), "The background check should make the Autobuild available.")
    }
    #expect(stableChanges.count == 2)
    #expect(stableChanges.first.flatMap { $0 } == nil)
    #expect(stableChanges.last.flatMap { $0?.version?.description } == "1.2.3")
    #expect(state.requestCount == 1)
    #expect(state.requestedURLs == [catalogURL])

    let shutdown = controller.stop()
    #expect(shutdown != nil)
    if let shutdown { await shutdown.value }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
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

private func releasesCatalog() throws -> Data {
    let autobuildTag = "Autobuild-\(autobuildCommit)"
    let autobuildName = "Motionpaper-\(autobuildCommit.prefix(12)).dmg"
    let stableTag = "v1.2.3"
    let stableName = "Motionpaper-1.2.3-\(stableCommit.prefix(12)).dmg"
    let releases: [[String: Any]] = [
        [
            "tag_name": autobuildTag,
            "published_at": "2026-10-25T00:00:00Z",
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": autobuildName,
                "state": "uploaded",
                "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/\(autobuildTag)/\(autobuildName)",
                "size": 3,
                "digest": "sha256:\(checksum)",
            ]],
        ],
        [
            "tag_name": stableTag,
            "target_commitish": stableCommit,
            "published_at": "2026-10-25T00:00:00Z",
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": stableName,
                "state": "uploaded",
                "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/\(stableTag)/\(stableName)",
                "size": 3,
                "digest": "sha256:\(checksum)",
            ]],
        ],
    ]
    return try JSONSerialization.data(withJSONObject: releases)
}

private final class UpdateControllerURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = UpdateControllerURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.respond(to: self, url: request.url)
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
}

private final class UpdateControllerURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responseData = Data()
    private var urls: [URL] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func reset(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responseData = data
        urls = []
    }

    func respond(to loader: UpdateControllerURLProtocol, url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        let data = responseData
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            loader.send(data)
        }
    }
}
