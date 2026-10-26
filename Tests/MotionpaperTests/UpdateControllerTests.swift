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
        #expect(fixture.protocolState.catalogRequestCount == 1)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        await fixture.stopController()
    }

    @Test
    func manualCheckShowsAvailableUpdate() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.checkForUpdates()
        let updateArrived = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(updateArrived)
        if case let .available(manifest) = fixture.controller.state {
            #expect(manifest.commit == autobuildCommit)
            #expect(manifest.version == nil)
        } else {
            #expect(Bool(false), "A newer Autobuild should be available.")
        }

        await fixture.stopController()
    }

    @Test
    func manualCheckShowsUpToDateWhenNoUpdateIsAvailable() async throws {
        let fixture = try UpdateControllerFixture(currentCommit: autobuildCommit)

        fixture.controller.checkForUpdates()
        let isUpToDate = await waitUntil { isUpToDateState(fixture.controller.state) }
        #expect(isUpToDate)

        await fixture.stopController()
    }

    @Test
    func failedCheckCanBeRetried() async throws {
        let fixture = try UpdateControllerFixture(catalog: Data("not a release catalog".utf8))

        fixture.controller.checkForUpdates()
        let firstFailureArrived = await waitUntil { checkFailure(fixture.controller.state) != nil }
        #expect(firstFailureArrived)
        guard let firstFailure = checkFailure(fixture.controller.state) else {
            await fixture.stopController()
            return
        }
        #expect(!firstFailure.isEmpty)
        #expect(fixture.protocolState.catalogRequestCount == 1)

        fixture.protocolState.setCatalog(try releasesCatalog())
        fixture.controller.checkForUpdates()
        let retrySucceeded = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(retrySucceeded)
        #expect(fixture.protocolState.catalogRequestCount == 2)

        await fixture.stopController()
    }

    @Test
    func installationFailureRecordedDuringCheckAppearsAfterTheCheckAndIsConsumedOnce() async throws {
        let fixture = try UpdateControllerFixture()
        let application = Bundle.main.bundleURL
        try UpdateInstallationFailure.clear(application: application)
        defer { try? UpdateInstallationFailure.clear(application: application) }

        fixture.controller.checkForUpdates()
        #expect(isChecking(fixture.controller.state))

        let message = "The previous installation could not launch"
        try UpdateInstallationFailure.record(message: message, application: application)
        fixture.controller.refreshInstallationFailure()
        #expect(isChecking(fixture.controller.state))

        let reportWasPublished = await waitUntil {
            guard case let .installFailed(manifest, failure) = fixture.controller.state else { return false }
            return manifest == nil && failure == message
        }
        #expect(reportWasPublished)
        #expect(try UpdateInstallationFailure.consume(application: application) == nil)

        await fixture.stopController()
    }

    @Test
    func failedInstallCanBeRetriedOnceWithTheSameManifest() async throws {
        let fixture = try UpdateControllerFixture()
        fixture.controller.checkForUpdates()
        let updateArrived = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(updateArrived)
        guard case let .available(manifest) = fixture.controller.state else {
            await fixture.stopController()
            return
        }

        var downloadingManifests: [UpdateManifest] = []
        fixture.controller.onStateChange = { state in
            if case let .downloading(manifest) = state { downloadingManifests.append(manifest) }
        }

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest])

        let firstFailureArrived = await waitUntil { installationFailure(fixture.controller.state) != nil }
        #expect(firstFailureArrived)
        guard let firstFailure = installationFailure(fixture.controller.state) else {
            await fixture.stopController()
            return
        }
        #expect(firstFailure.manifest == manifest)
        #expect(!firstFailure.message.isEmpty)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest, manifest])

        let secondFailureArrived = await waitUntil { installationFailure(fixture.controller.state) != nil }
        #expect(secondFailureArrived)
        #expect(installationFailure(fixture.controller.state)?.manifest == manifest)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        await fixture.stopController()
    }
}

@MainActor
private final class UpdateControllerFixture {
    let protocolState = UpdateControllerURLProtocol.state
    let session: URLSession
    let controller: UpdateController
    private let directory: URL

    init(currentCommit: String = String(repeating: "a", count: 40), catalog: Data? = nil) throws {
        let catalogData: Data
        if let catalog { catalogData = catalog }
        else { catalogData = try releasesCatalog() }
        protocolState.reset(with: catalogData)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateControllerURLProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionpaper-update-controller-\(UUID().uuidString)", isDirectory: true)

        let service = UpdateService(releaseURL: catalogURL, currentCommit: currentCommit,
                                    channel: .autobuild, directory: directory, session: session)
        controller = UpdateController(service: service, channel: .autobuild)
    }

    func stopController() async {
        if let shutdown = controller.stop() { await shutdown.value }
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct InstallationFailure {
    let manifest: UpdateManifest?
    let message: String
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
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
private func isAvailable(_ state: UpdateController.State) -> Bool {
    if case .available = state { return true }
    return false
}

@MainActor
private func isChecking(_ state: UpdateController.State) -> Bool {
    if case .checking = state { return true }
    return false
}

@MainActor
private func isUpToDateState(_ state: UpdateController.State) -> Bool {
    if case .upToDate = state { return true }
    return false
}

@MainActor
private func checkFailure(_ state: UpdateController.State) -> String? {
    if case let .checkFailed(message) = state { return message }
    return nil
}

@MainActor
private func installationFailure(_ state: UpdateController.State) -> InstallationFailure? {
    if case let .installFailed(manifest, message) = state {
        return InstallationFailure(manifest: manifest, message: message)
    }
    return nil
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

    func send(_ data: Data, url: URL) {
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: any Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class UpdateControllerURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var catalogData = Data()
    private var urls: [URL] = []

    var catalogRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.filter { $0 == catalogURL }.count
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func reset(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        catalogData = data
        urls = []
    }

    func setCatalog(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        catalogData = data
    }

    func respond(to loader: UpdateControllerURLProtocol, url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        let data = catalogData
        lock.unlock()

        guard let url, url == catalogURL else {
            loader.fail(URLError(.unsupportedURL))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            loader.send(data, url: url)
        }
    }
}
