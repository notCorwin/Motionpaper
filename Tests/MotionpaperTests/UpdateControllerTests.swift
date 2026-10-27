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
    func menuOpenChecksBothChannelsFromOneCatalogRequest() async throws {
        let fixture = try UpdateControllerFixture()

        var stableChanges: [UpdateManifest?] = []
        fixture.controller.onStableReleaseChange = { stableChanges.append($0) }
        fixture.controller.start()
        fixture.controller.menuWillOpen()

        let resultsArrived = await waitUntil {
            guard stableChanges.contains(where: { $0?.version?.description == "1.2.3" }) else { return false }
            return isAvailable(fixture.controller.state)
        }
        #expect(resultsArrived)
        if case let .available(manifest) = fixture.controller.state {
            #expect(manifest.commit == autobuildCommit)
        } else {
            #expect(Bool(false), "Opening the menu should make the Autobuild available.")
        }
        #expect(stableChanges.count == 2)
        #expect(stableChanges.first.flatMap { $0 } == nil)
        #expect(stableChanges.last.flatMap { $0?.version?.description } == "1.2.3")
        #expect(fixture.protocolState.catalogRequestCount == 1)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        await fixture.stopController()
    }

    @Test
    func startupDoesNotCheckTheNetwork() async throws {
        let fixture = try UpdateControllerFixture()
        let application = Bundle.main.bundleURL
        try UpdateInstallationFailure.clear(application: application)
        defer { try? UpdateInstallationFailure.clear(application: application) }

        fixture.controller.start()
        try await Task.sleep(for: .milliseconds(150))

        #expect(fixture.protocolState.catalogRequestCount == 0)
        #expect(isIdle(fixture.controller.state))
        await fixture.stopController()
    }

    @Test
    func repeatedMenuOpensWhileCheckingDoNotStartDuplicateRequests() async throws {
        let fixture = try UpdateControllerFixture()

        fixture.controller.menuWillOpen()
        #expect(isChecking(fixture.controller.state))
        for _ in 0..<5 {
            fixture.controller.menuWillOpen()
        }

        let updateArrived = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(updateArrived)
        #expect(fixture.protocolState.catalogRequestCount == 1)

        await fixture.stopController()
    }

    @Test
    func aLaterMenuOpenChecksTheCurrentCatalogAgain() async throws {
        let fixture = try UpdateControllerFixture()
        var stableChanges: [UpdateManifest?] = []
        fixture.controller.onStableReleaseChange = { stableChanges.append($0) }

        fixture.controller.menuWillOpen()
        let firstCheckFinished = await waitUntil {
            stableChanges.count == 2 && isAvailable(fixture.controller.state)
        }
        #expect(firstCheckFinished)
        #expect(fixture.protocolState.catalogRequestCount == 1)

        fixture.protocolState.setCatalog(try releasesCatalog(autobuildCommit: String(repeating: "a", count: 40)))
        fixture.controller.menuWillOpen()
        let secondCheckFinished = await waitUntil { isUpToDateState(fixture.controller.state) }
        #expect(secondCheckFinished)
        #expect(fixture.protocolState.catalogRequestCount == 2)
        #expect(stableChanges.count == 4)
        #expect(stableChanges.last.flatMap { $0?.version?.description } == "1.2.3")

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
    func menuOpenShowsPersistedInstallationFailureWithoutStartingACheck() async throws {
        let fixture = try UpdateControllerFixture()
        let application = Bundle.main.bundleURL
        try UpdateInstallationFailure.clear(application: application)
        defer { try? UpdateInstallationFailure.clear(application: application) }

        let message = "The previous installation could not launch"
        try UpdateInstallationFailure.record(message: message, application: application)
        fixture.controller.menuWillOpen()

        #expect(installationFailure(fixture.controller.state) == message)
        #expect(fixture.protocolState.catalogRequestCount == 0)

        fixture.controller.menuWillOpen()
        #expect(installationFailure(fixture.controller.state) == message)
        #expect(fixture.protocolState.catalogRequestCount == 0)

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
            installationFailure(fixture.controller.state) == message
        }
        #expect(reportWasPublished)
        #expect(try UpdateInstallationFailure.consume(application: application) == nil)

        await fixture.stopController()
    }

    @Test
    func failedInstallCanCheckForANewerReleaseBeforeInstallingAgain() async throws {
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
        #expect(isDownloading(fixture.controller.state))
        for _ in 0..<5 {
            fixture.controller.menuWillOpen()
        }
        #expect(isDownloading(fixture.controller.state))
        #expect(fixture.protocolState.catalogRequestCount == 1)
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest])

        let firstFailureArrived = await waitUntil { installationFailure(fixture.controller.state) != nil }
        #expect(firstFailureArrived)
        guard let firstFailure = installationFailure(fixture.controller.state) else {
            await fixture.stopController()
            return
        }
        #expect(!firstFailure.isEmpty)
        #expect(fixture.protocolState.requestedURLs == [catalogURL])

        fixture.controller.menuWillOpen()
        #expect(installationFailure(fixture.controller.state) == firstFailure)
        #expect(fixture.protocolState.catalogRequestCount == 1)

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest])
        #expect(installationFailure(fixture.controller.state) == firstFailure)

        let newerCommit = String(repeating: "d", count: 40)
        fixture.protocolState.setCatalog(try releasesCatalog(autobuildCommit: newerCommit))
        fixture.controller.checkForUpdates()
        let newerUpdateArrived = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(newerUpdateArrived)
        guard case let .available(newerManifest) = fixture.controller.state else {
            await fixture.stopController()
            return
        }
        #expect(newerManifest.commit == newerCommit)

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest, newerManifest])

        let secondFailureArrived = await waitUntil { installationFailure(fixture.controller.state) != nil }
        #expect(secondFailureArrived)
        #expect(fixture.protocolState.requestedURLs == [catalogURL, catalogURL])

        await fixture.stopController()
    }

    @Test
    func failedInstallDoesNotOfferTheOldTargetWhenTheNextCheckFails() async throws {
        let fixture = try UpdateControllerFixture()
        fixture.controller.checkForUpdates()
        #expect(await waitUntil { isAvailable(fixture.controller.state) })

        var attempts = 0
        fixture.controller.onStateChange = { state in
            if isDownloading(state) { attempts += 1 }
        }
        fixture.controller.installAvailableUpdate()
        #expect(await waitUntil { installationFailure(fixture.controller.state) != nil })

        fixture.protocolState.setCatalog(Data("not a release catalog".utf8))
        fixture.controller.checkForUpdates()
        #expect(await waitUntil { checkFailure(fixture.controller.state) != nil })
        fixture.controller.installAvailableUpdate()
        #expect(attempts == 1)
        #expect(checkFailure(fixture.controller.state) != nil)

        await fixture.stopController()
    }

    @Test
    func failedStableInstallCanRecheckAndUseTheNewStableRelease() async throws {
        let fixture = try UpdateControllerFixture(currentCommit: autobuildCommit)
        var stableRelease: UpdateManifest?
        fixture.controller.onStableReleaseChange = { stableRelease = $0 }
        fixture.controller.checkForUpdates()
        #expect(await waitUntil { stableRelease != nil && isUpToDateState(fixture.controller.state) })

        var downloadingManifests: [UpdateManifest] = []
        fixture.controller.onStateChange = { state in
            if case let .downloading(manifest) = state { downloadingManifests.append(manifest) }
        }
        fixture.controller.installStableRelease()
        #expect(await waitUntil { installationFailure(fixture.controller.state) != nil })
        #expect(downloadingManifests.map { $0.version?.description } == ["1.2.3"])
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests.count == 1)

        fixture.protocolState.setCatalog(try releasesCatalog(stableVersion: "1.2.4"))
        fixture.controller.checkForUpdates()
        #expect(await waitUntil {
            stableRelease?.version?.description == "1.2.4" && isUpToDateState(fixture.controller.state)
        })
        fixture.controller.installStableRelease()
        fixture.controller.installStableRelease()
        #expect(downloadingManifests.map { $0.version?.description } == ["1.2.3", "1.2.4"])
        #expect(await waitUntil { installationFailure(fixture.controller.state) != nil })
        #expect(fixture.protocolState.catalogRequestCount == 2)

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
private func isIdle(_ state: UpdateController.State) -> Bool {
    if case .idle = state { return true }
    return false
}

@MainActor
private func isChecking(_ state: UpdateController.State) -> Bool {
    if case .checking = state { return true }
    return false
}

@MainActor
private func isDownloading(_ state: UpdateController.State) -> Bool {
    if case .downloading = state { return true }
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
private func installationFailure(_ state: UpdateController.State) -> String? {
    if case let .installFailed(message) = state {
        return message
    }
    return nil
}

private func releasesCatalog(autobuildCommit commit: String = autobuildCommit,
                             stableVersion: String = "1.2.3") throws -> Data {
    let autobuildTag = "Autobuild-\(commit)"
    let autobuildName = "Motionpaper-\(commit.prefix(12)).dmg"
    let stableTag = "v\(stableVersion)"
    let stableName = "Motionpaper-v\(stableVersion).dmg"
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
