import AppKit
import OSLog
import UpdateCore

@MainActor
final class UpdateController {
    enum State {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        case installing
        case checkFailed(String)
        case installFailed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            default: false
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: (@MainActor (State) -> Void)?
    var onStableReleaseChange: (@MainActor (UpdateManifest?) -> Void)?
    private let service: UpdateService?
    private let channel: UpdateChannel
    private var availableStableRelease: UpdateManifest?
    private var operation: Task<Void, Never>?
    private var stableCheck: Task<Void, Never>?
    private var maintenance: Task<Void, Never>?
    private var stopping = false
    private var shutdown: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.motionpaper.app", category: "updates")

    init(service: UpdateService, channel: UpdateChannel) {
        self.service = service
        self.channel = channel
    }

    init() {
        let bundle = Bundle.main
        channel = UpdateChannel(rawValue: bundle.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String ?? "") ?? .autobuild
        if let commit = bundle.object(forInfoDictionaryKey: "MotionpaperCommit") as? String,
           let address = bundle.object(forInfoDictionaryKey: "MotionpaperUpdateURL") as? String,
           let url = URL(string: address),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let directory = caches.appendingPathComponent("local.motionpaper.app/Updates", isDirectory: true)
            service = UpdateService(feedURL: url, currentCommit: commit,
                                    currentVersion: channel == .stable ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil,
                                    channel: channel, directory: directory)
        } else {
            service = nil
        }
    }

    func start() {
        guard !stopping, maintenance == nil else { return }
        refreshInstallationFailure()
        maintenance = Task { [weak self, service] in
            do { try await UpdateInstaller.removeStaleInstallations(application: Bundle.main.bundleURL) }
            catch {
                self?.logger.error("Stale update cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            do { try await service?.removeStaleDownloads() }
            catch {
                self?.logger.error("Stale download cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func menuWillOpen() {
        refreshInstallationFailure()
        // Keep an installer failure visible until the user chooses to check again.
        if case .installFailed = state { return }
        checkForUpdates()
    }

    func installAvailableUpdate() {
        guard case .available(let manifest) = state, let service else { return }
        install(manifest, using: service)
    }

    func refreshInstallationFailure() {
        guard !stopping, !state.isBusy, operation == nil else { return }
        do {
            if let failure = try UpdateInstallationFailure.consume(application: Bundle.main.bundleURL) {
                state = .installFailed(failure.message)
            }
        } catch {
            logger.error("Unable to read installation result: \(error.localizedDescription, privacy: .public)")
            state = .installFailed(error.localizedDescription)
        }
    }

    func installStableRelease() {
        if let availableStableRelease, let service { install(availableStableRelease, using: service) }
    }

    func stop() -> Task<Void, Never>? {
        if let shutdown { return shutdown }
        stopping = true
        let cleanup = maintenance
        cleanup?.cancel()
        maintenance = nil
        let pending = operation
        pending?.cancel()
        operation = nil
        let stable = stableCheck
        stable?.cancel()
        stableCheck = nil
        guard cleanup != nil || pending != nil || stable != nil else { return nil }
        let shutdown = Task { [service] in
            await service?.cancel()
            await pending?.value
            await stable?.value
            await cleanup?.value
        }
        self.shutdown = shutdown
        return shutdown
    }

    func checkForUpdates() {
        guard !stopping, !state.isBusy, operation == nil else { return }
        guard let service else {
            state = .checkFailed("请使用构建脚本或 GitHub Release 提供的应用。")
            return
        }
        checkStableRelease()
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            let result: Result<UpdateManifest?, any Error>
            do {
                result = .success(try await service.check())
            } catch {
                result = .failure(error)
            }
            operation = nil
            guard !Task.isCancelled, !stopping else { return }
            switch result {
            case .success(let manifest):
                state = manifest.map(State.available) ?? .upToDate
            case .failure(let error):
                state = .checkFailed(error.localizedDescription)
                logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            }
            refreshInstallationFailure()
        }
    }

    private func checkStableRelease() {
        guard channel == .autobuild, let service, stableCheck == nil else { return }
        availableStableRelease = nil
        onStableReleaseChange?(nil)
        stableCheck = Task { [weak self] in
            guard let self else { return }
            defer { stableCheck = nil }
            do {
                let manifest = try await service.check(channel: .stable)
                guard !Task.isCancelled, !stopping else { return }
                availableStableRelease = manifest
                onStableReleaseChange?(manifest)
            } catch {
                guard !Task.isCancelled, !stopping else { return }
                logger.error("Stable release check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // A rolling Autobuild can replace its asset after the user checked for updates.
    // Refresh once on a missing image, and only follow a different asset URL.
    func withUpdateImage<Value: Sendable>(
        _ manifest: UpdateManifest, using service: UpdateService,
        operation: @escaping @Sendable (URL, UpdateManifest) async throws -> Value
    ) async throws -> Value? {
        func attempt(_ target: UpdateManifest) async throws -> Result<Value, any Error> {
            try await service.withDownloadedImage(target) { image in
                do { return .success(try await operation(image, target)) }
                catch { return .failure(error) }
            }
        }

        let result: Result<Value, any Error>
        do {
            result = try await attempt(manifest)
        } catch UpdateError.httpStatus(404) where channel == .autobuild && manifest.version == nil {
            guard let latest = try await service.check(channel: .autobuild) else { return nil }
            guard latest.downloadURL != manifest.downloadURL else { throw UpdateError.httpStatus(404) }
            state = .downloading(latest)
            result = try await attempt(latest)
        }
        return try result.get()
    }

    private func install(_ manifest: UpdateManifest, using service: UpdateService) {
        guard !stopping, !state.isBusy, operation == nil else { return }
        state = .downloading(manifest)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try UpdateInstallationFailure.clear(application: Bundle.main.bundleURL)
                try UpdateInstaller.validateDestination(Bundle.main.bundleURL)
                let update = try await withUpdateImage(manifest, using: service) { [weak self] image, target in
                    try Task.checkCancellation()
                    await MainActor.run { self?.state = .installing }
                    return try await UpdateInstaller.prepare(image: image, manifest: target,
                                                             application: Bundle.main.bundleURL)
                }
                guard let update else {
                    operation = nil
                    guard !Task.isCancelled, !stopping else { return }
                    state = .upToDate
                    return
                }
                var handedOff = false
                defer { if !handedOff { update.discard() } }
                try await update.startInstaller(parentPID: ProcessInfo.processInfo.processIdentifier)
                handedOff = true
                operation = nil
                // Start AppKit's modal termination loop outside the main queue,
                // leaving it available to finish asynchronous shutdown tasks.
                RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            } catch {
                operation = nil
                guard !Task.isCancelled, !stopping else { return }
                logger.error("Update installation failed: \(error.localizedDescription, privacy: .public)")
                state = .installFailed(error.localizedDescription)
                refreshInstallationFailure()
            }
        }
    }
}
