import Foundation
import Testing
import UpdateCore
@testable import Motionpaper

private let autobuildCommit = String(repeating: "b", count: 40)
private let stableCommit = String(repeating: "c", count: 40)
private let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
private let feedURL = URL(string: "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild/update.json")!
private let stableFeedURL = URL(string: "https://github.com/notCorwin/Motionpaper/releases/latest/download/update.json")!

@Suite(.serialized)
@MainActor
struct UpdateControllerTests {
    @Test
    func menuOpenChecksEachChannelsReleaseManifestOnce() async throws {
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
        #expect(fixture.protocolState.feedRequestCount == 1)
        #expect(fixture.protocolState.requestedURLs.count == 2)
        #expect(Set(fixture.protocolState.requestedURLs) == Set([feedURL, stableFeedURL]))

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

        #expect(fixture.protocolState.feedRequestCount == 0)
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
        #expect(fixture.protocolState.feedRequestCount == 1)

        await fixture.stopController()
    }

    @Test
    func aLaterMenuOpenChecksTheCurrentFeedAgain() async throws {
        let fixture = try UpdateControllerFixture()
        var stableChanges: [UpdateManifest?] = []
        fixture.controller.onStableReleaseChange = { stableChanges.append($0) }

        fixture.controller.menuWillOpen()
        let firstCheckFinished = await waitUntil {
            stableChanges.count == 2 && isAvailable(fixture.controller.state)
        }
        #expect(firstCheckFinished)
        #expect(fixture.protocolState.feedRequestCount == 1)

        fixture.protocolState.setFeed(try updateFeed(autobuildCommit: String(repeating: "a", count: 40)))
        fixture.controller.menuWillOpen()
        let secondCheckFinished = await waitUntil {
            stableChanges.count == 4 && isUpToDateState(fixture.controller.state)
        }
        #expect(secondCheckFinished)
        #expect(fixture.protocolState.feedRequestCount == 2)
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
        let fixture = try UpdateControllerFixture(feed: Data("not an update feed".utf8))

        fixture.controller.checkForUpdates()
        let firstFailureArrived = await waitUntil { checkFailure(fixture.controller.state) != nil }
        #expect(firstFailureArrived)
        guard let firstFailure = checkFailure(fixture.controller.state) else {
            await fixture.stopController()
            return
        }
        #expect(!firstFailure.isEmpty)
        #expect(fixture.protocolState.feedRequestCount == 1)

        fixture.protocolState.setFeed(try updateFeed())
        fixture.controller.checkForUpdates()
        let retrySucceeded = await waitUntil { isAvailable(fixture.controller.state) }
        #expect(retrySucceeded)
        #expect(fixture.protocolState.feedRequestCount == 2)

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
        #expect(fixture.protocolState.feedRequestCount == 0)

        fixture.controller.menuWillOpen()
        #expect(installationFailure(fixture.controller.state) == message)
        #expect(fixture.protocolState.feedRequestCount == 0)

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
        #expect(fixture.protocolState.feedRequestCount == 1)
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest])

        let firstFailureArrived = await waitUntil { installationFailure(fixture.controller.state) != nil }
        #expect(firstFailureArrived)
        guard let firstFailure = installationFailure(fixture.controller.state) else {
            await fixture.stopController()
            return
        }
        #expect(!firstFailure.isEmpty)
        #expect(fixture.protocolState.requestedURLs.count == 2)
        #expect(Set(fixture.protocolState.requestedURLs) == Set([feedURL, stableFeedURL]))

        fixture.controller.menuWillOpen()
        #expect(installationFailure(fixture.controller.state) == firstFailure)
        #expect(fixture.protocolState.feedRequestCount == 1)

        fixture.controller.installAvailableUpdate()
        fixture.controller.installAvailableUpdate()
        #expect(downloadingManifests == [manifest])
        #expect(installationFailure(fixture.controller.state) == firstFailure)

        let newerCommit = String(repeating: "d", count: 40)
        fixture.protocolState.setFeed(try updateFeed(autobuildCommit: newerCommit))
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
        #expect(fixture.protocolState.requestedURLs.count == 4)
        #expect(fixture.protocolState.requestedURLs.filter { $0 == feedURL } == [feedURL, feedURL])

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

        fixture.protocolState.setFeed(Data("not an update feed".utf8))
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

        fixture.protocolState.setFeed(try updateFeed(stableVersion: "1.2.4"))
        fixture.controller.checkForUpdates()
        #expect(await waitUntil {
            stableRelease?.version?.description == "1.2.4" && isUpToDateState(fixture.controller.state)
        })
        fixture.controller.installStableRelease()
        fixture.controller.installStableRelease()
        #expect(downloadingManifests.map { $0.version?.description } == ["1.2.3", "1.2.4"])
        #expect(await waitUntil { installationFailure(fixture.controller.state) != nil })
        #expect(fixture.protocolState.feedRequestCount == 2)

        await fixture.stopController()
    }

    @Test
    func missingAutobuildImageRefreshesOnceAndUsesTheNewManifest() async throws {
        let fixture = try UpdateControllerFixture()
        let old = try #require(try await fixture.service.check())
        let newerCommit = String(repeating: "d", count: 40)
        fixture.protocolState.setFeed(try updateFeed(autobuildCommit: newerCommit))
        fixture.protocolState.setDownloadStatuses([404, 200])

        let installedCommit = try await fixture.controller.withUpdateImage(old, using: fixture.service) { image, target in
            let data = try Data(contentsOf: image)
            #expect(data == Data("abc".utf8))
            return target.commit
        }
        #expect(installedCommit == newerCommit)
        #expect(fixture.protocolState.feedRequestCount == 2)
        #expect(fixture.protocolState.downloadRequestCount == 2)
        await fixture.stopController()
    }

    @Test
    func missingImageIsNotRetriedWhenFeedStillReferencesTheSameAsset() async throws {
        let fixture = try UpdateControllerFixture()
        let old = try #require(try await fixture.service.check())
        fixture.protocolState.setDownloadStatuses([404])
        await #expect(throws: UpdateError.self) {
            try await fixture.controller.withUpdateImage(old, using: fixture.service) { _, target in target.commit }
        }
        #expect(fixture.protocolState.feedRequestCount == 2)
        #expect(fixture.protocolState.downloadRequestCount == 1)
        await fixture.stopController()
    }

    @Test
    func missingImageCanBecomeUpToDateDuringRefresh() async throws {
        let fixture = try UpdateControllerFixture()
        let old = try #require(try await fixture.service.check())
        fixture.protocolState.setFeed(try updateFeed(autobuildCommit: String(repeating: "a", count: 40)))
        fixture.protocolState.setDownloadStatuses([404])
        let result = try await fixture.controller.withUpdateImage(old, using: fixture.service) { _, target in target.commit }
        #expect(result == nil)
        #expect(fixture.protocolState.feedRequestCount == 2)
        #expect(fixture.protocolState.downloadRequestCount == 1)
        await fixture.stopController()
    }

    @Test
    func missingReplacementImageDoesNotRepeatFallback() async throws {
        let fixture = try UpdateControllerFixture()
        let old = try #require(try await fixture.service.check())
        fixture.protocolState.setFeed(try updateFeed(autobuildCommit: String(repeating: "d", count: 40)))
        fixture.protocolState.setDownloadStatuses([404])
        await #expect(throws: UpdateError.self) {
            try await fixture.controller.withUpdateImage(old, using: fixture.service) { _, target in target.commit }
        }
        #expect(fixture.protocolState.feedRequestCount == 2)
        #expect(fixture.protocolState.downloadRequestCount == 2)
        await fixture.stopController()
    }

    @Test
    func stableImageFailureDoesNotSwitchToAutobuild() async throws {
        let fixture = try UpdateControllerFixture()
        let stable = try #require(try await fixture.service.check(channel: .stable))
        fixture.protocolState.setDownloadStatuses([404])
        await #expect(throws: UpdateError.self) {
            try await fixture.controller.withUpdateImage(stable, using: fixture.service) { _, target in target.commit }
        }
        #expect(fixture.protocolState.feedRequestCount == 0)
        #expect(fixture.protocolState.downloadRequestCount == 1)
        await fixture.stopController()
    }

    @Test
    func preparationErrorNeverTriggersDownloadFallback() async throws {
        let fixture = try UpdateControllerFixture()
        let old = try #require(try await fixture.service.check())
        fixture.protocolState.setDownloadStatuses([200])
        await #expect(throws: UpdateError.self) {
            try await fixture.controller.withUpdateImage(old, using: fixture.service) { _, _ -> String in
                throw UpdateError.httpStatus(404)
            }
        }
        #expect(fixture.protocolState.feedRequestCount == 1)
        #expect(fixture.protocolState.downloadRequestCount == 1)
        await fixture.stopController()
    }
}

@MainActor
private final class UpdateControllerFixture {
    let protocolState = UpdateControllerURLProtocol.state
    let session: URLSession
    let controller: UpdateController
    let service: UpdateService
    private let directory: URL

    init(currentCommit: String = String(repeating: "a", count: 40), feed: Data? = nil) throws {
        let feedData: Data
        if let feed { feedData = feed }
        else { feedData = try updateFeed() }
        protocolState.reset(with: feedData)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateControllerURLProtocol.self]
        session = URLSession(configuration: configuration)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionpaper-update-controller-\(UUID().uuidString)", isDirectory: true)

        service = UpdateService(feedURL: feedURL, currentCommit: currentCommit,
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

private func updateFeed(autobuildCommit commit: String = autobuildCommit,
                             stableVersion: String = "1.2.3") throws -> Data {
    let autobuildTag = "Autobuild"
    let autobuildName = "Motionpaper-\(commit.prefix(12)).dmg"
    let stableTag = "v\(stableVersion)"
    let stableName = "Motionpaper-v\(stableVersion).dmg"
    let releases: [String: Any] = [
        "autobuild": [
            "commit": commit, "publishedAt": "2026-10-25T00:00:00Z",
            "downloadURL": "https://github.com/notCorwin/Motionpaper/releases/download/\(autobuildTag)/\(autobuildName)",
            "size": 3, "sha256": checksum,
        ],
        "stable": [
            "commit": stableCommit, "version": stableVersion, "publishedAt": "2026-10-25T00:00:00Z",
            "downloadURL": "https://github.com/notCorwin/Motionpaper/releases/download/\(stableTag)/\(stableName)",
            "size": 3, "sha256": checksum,
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

    func send(_ data: Data, url: URL, status: Int = 200) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(data.count)]) else {
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
    private var feedData = Data()
    private var urls: [URL] = []
    private var downloadStatuses: [Int] = []
    private var downloadCount = 0

    var feedRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.filter { $0 == feedURL }.count
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    var downloadRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return downloadCount
    }

    func reset(with data: Data) {
        lock.lock()
        defer { lock.unlock() }
        feedData = data
        urls = []
        downloadStatuses = []
        downloadCount = 0
    }

    func setFeed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        feedData = data
    }

    func setDownloadStatuses(_ statuses: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        downloadStatuses = statuses
        downloadCount = 0
    }

    func respond(to loader: UpdateControllerURLProtocol, url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        var data = feedData
        let isImage = url?.pathExtension == "dmg"
        let status: Int
        if isImage, !downloadStatuses.isEmpty {
            status = downloadStatuses[min(downloadCount, downloadStatuses.count - 1)]
            downloadCount += 1
        } else {
            status = 0
        }
        lock.unlock()

        if let url, isImage, status != 0 {
            loader.send(Data((status == 200 ? "abc" : "missing").utf8), url: url, status: status)
            return
        }

        guard let url, url == feedURL || url == stableFeedURL else {
            loader.fail(URLError(.unsupportedURL))
            return
        }
        if let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let channel = url == stableFeedURL ? "stable" : "autobuild"
            if let entry = document[channel] {
                data = (try? JSONSerialization.data(withJSONObject: [channel: entry])) ?? data
            }
        }
        let body = data
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
            loader.send(body, url: url)
        }
    }
}
