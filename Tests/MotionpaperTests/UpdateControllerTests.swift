import AppKit
import Foundation
import Testing
import UpdateCore
@testable import Motionpaper

private let autobuildCommit = String(repeating: "b", count: 40)
private let stableCommit = String(repeating: "c", count: 40)
private let checksum = String(repeating: "a", count: 64)
private let catalogURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100")!

@Suite(.serialized)
@MainActor
struct UpdateControllerTests {
    @Test
    func controllerChecksBothChannelsFromOneCatalogRequest() async throws {
        let fixture = try UpdateControllerFixture()

        var stableChanges: [UpdateManifest?] = []
        fixture.controller.onStableReleaseChange = { stableChanges.append($0) }
        fixture.controller.start()

        let resultsArrived = await waitUntil {
            guard stableChanges.contains(where: { $0?.version?.description == "1.2.3" }) else { return false }
            return isAvailable(fixture.controller.state)
        }
        #expect(resultsArrived)
        if case let .available(manifest) = fixture.controller.state {
            #expect(manifest.commit == autobuildCommit)
        } else {
            #expect(Bool(false), "The background check should make the Autobuild available.")
        }
        #expect(stableChanges.count == 2)
        #expect(stableChanges.first.flatMap { $0 } == nil)
        #expect(stableChanges.last.flatMap { $0?.version?.description } == "1.2.3")
        #expect(fixture.protocolState.requestCount == 1)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        let shutdown = fixture.controller.stop()
        #expect(shutdown != nil)
        if let shutdown { await shutdown.value }
        fixture.invalidateSession()
    }

    @Test
    func manualCheckDismissesPendingPromptAndStartsAnotherCheck() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.checkForUpdates()
        let firstPromptArrived = await fixture.waitForAvailablePrompt(count: 1)
        #expect(firstPromptArrived)
        guard let firstPrompt = fixture.alerts.first else {
            await fixture.stopController()
            return
        }
        #expect(firstPrompt.window.delegate != nil)
        #expect(fixture.protocolState.requestCount == 1)

        fixture.controller.checkForUpdates()

        #expect(isChecking(fixture.controller.state))
        #expect(firstPrompt.window.delegate == nil)

        // A dismissed prompt must no longer be able to install its manifest.
        firstPrompt.buttons[0].performClick(nil)
        #expect(isChecking(fixture.controller.state))

        let secondPromptArrived = await fixture.waitForAvailablePrompt(count: 2, requestCount: 2)
        #expect(secondPromptArrived)
        #expect(fixture.protocolState.requestCount == 2)
        #expect(fixture.alerts.count == 2)
        #expect(isAvailable(fixture.controller.state))

        await fixture.stopController()
    }

    @Test
    func installActionDismissesPendingPromptAndStartsOneInstall() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.checkForUpdates()
        let promptArrived = await fixture.waitForAvailablePrompt()
        #expect(promptArrived)
        guard let prompt = fixture.alerts.first else {
            await fixture.stopController()
            return
        }
        #expect(prompt.window.delegate != nil)

        var downloadingTransitions = 0
        fixture.controller.onStateChange = { state in
            if case .downloading = state { downloadingTransitions += 1 }
        }

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()

        #expect(isDownloading(fixture.controller.state))
        #expect(downloadingTransitions == 1)
        #expect(prompt.window.delegate == nil)

        // The controller is stopped before yielding so no real download or install can run.
        await fixture.stopController()
        #expect(downloadingTransitions == 1)
    }

    @Test
    func firstPromptButtonStartsOneInstall() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.checkForUpdates()
        let promptArrived = await fixture.waitForAvailablePrompt()
        #expect(promptArrived)
        guard let prompt = fixture.alerts.first else {
            await fixture.stopController()
            return
        }
        #expect(prompt.window.delegate != nil)

        var downloadingTransitions = 0
        fixture.controller.onStateChange = { state in
            if case .downloading = state { downloadingTransitions += 1 }
        }

        prompt.buttons[0].performClick(nil)
        prompt.buttons[0].performClick(nil)
        fixture.controller.installAvailableUpdate()

        #expect(isDownloading(fixture.controller.state))
        #expect(downloadingTransitions == 1)
        #expect(prompt.window.delegate == nil)

        // Cancel the newly started task synchronously, before it can touch the filesystem or network.
        await fixture.stopController()
        #expect(downloadingTransitions == 1)
    }

    @Test
    func choosingLaterAllowsAnotherCheckWithoutInstalling() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.checkForUpdates()
        let firstPromptArrived = await fixture.waitForAvailablePrompt()
        #expect(firstPromptArrived)
        guard let firstPrompt = fixture.alerts.first else {
            await fixture.stopController()
            return
        }
        #expect(firstPrompt.window.delegate != nil)

        var downloadingTransitions = 0
        fixture.controller.onStateChange = { state in
            if case .downloading = state { downloadingTransitions += 1 }
        }

        firstPrompt.buttons[1].performClick(nil)

        #expect(firstPrompt.window.delegate == nil)
        #expect(isAvailable(fixture.controller.state))
        #expect(downloadingTransitions == 0)

        fixture.controller.checkForUpdates()
        #expect(isChecking(fixture.controller.state))

        let secondPromptArrived = await fixture.waitForAvailablePrompt(count: 2, requestCount: 2)
        #expect(secondPromptArrived)
        #expect(fixture.protocolState.requestCount == 2)
        #expect(fixture.alerts.count == 2)
        #expect(isAvailable(fixture.controller.state))
        #expect(downloadingTransitions == 0)

        await fixture.stopController()
    }
}

@MainActor
private final class UpdateControllerFixture {
    let protocolState = UpdateControllerURLProtocol.state
    let session: URLSession
    let controller: UpdateController
    private let alertRecorder: UpdateControllerAlertRecorder

    var alerts: [NSAlert] { alertRecorder.alerts }

    init() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        protocolState.reset(with: try releasesCatalog())

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateControllerURLProtocol.self]
        session = URLSession(configuration: configuration)

        let service = UpdateService(releaseURL: catalogURL, currentCommit: String(repeating: "a", count: 40),
                                    channel: .autobuild, directory: FileManager.default.temporaryDirectory,
                                    session: session)
        let recorder = UpdateControllerAlertRecorder()
        alertRecorder = recorder
        controller = UpdateController(service: service, channel: .autobuild) { alert in
            recorder.alerts.append(alert)
        }
    }

    func waitForAvailablePrompt(count: Int = 1, requestCount: Int? = nil) async -> Bool {
        await waitUntil {
            alerts.count >= count && isAvailable(controller.state)
                && (requestCount.map { protocolState.requestCount >= $0 } ?? true)
        }
    }

    func stopController() async {
        if let shutdown = controller.stop() { await shutdown.value }
        session.invalidateAndCancel()
    }

    func invalidateSession() { session.invalidateAndCancel() }
}

@MainActor
private final class UpdateControllerAlertRecorder {
    var alerts: [NSAlert] = []
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

@MainActor
private func isChecking(_ state: UpdateController.State) -> Bool {
    if case .checking = state { return true }
    return false
}

@MainActor
private func isAvailable(_ state: UpdateController.State) -> Bool {
    if case .available = state { return true }
    return false
}

@MainActor
private func isDownloading(_ state: UpdateController.State) -> Bool {
    if case .downloading = state { return true }
    return false
}

private func releasesCatalog() throws -> Data {
    let autobuildTag = "Autobuild-\(autobuildCommit)"
    let autobuildName = "Motionpaper-\(autobuildCommit.prefix(12)).dmg"
    let stableTag = "v1.2.3"
    let stableName = "Motionpaper-v1.2.3.dmg"
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
