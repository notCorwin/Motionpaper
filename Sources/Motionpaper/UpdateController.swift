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
        case installFailed(UpdateManifest?, String)

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
    private var availableUpdate: UpdateManifest?
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
            service = UpdateService(releaseURL: url, currentCommit: commit,
                                    currentVersion: channel == .stable ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String : nil,
                                    channel: channel, directory: directory)
        } else {
            service = nil
        }
    }

    func start() {
        guard !stopping, maintenance == nil else { return }
        refreshInstallationFailure()
        maintenance = Task { [weak self] in
            do { try await UpdateInstaller.removeStaleInstallations(application: Bundle.main.bundleURL) }
            catch {
                self?.logger.error("Stale update cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func menuWillOpen() {
        refreshInstallationFailure()
        // Keep an installer failure visible until the user chooses to retry.
        if case .installFailed = state { return }
        checkForUpdates()
    }

    func installAvailableUpdate() {
        if case .installFailed(let manifest, _) = state {
            if let manifest, let service { install(manifest, using: service) }
            return
        }
        if let availableUpdate, let service { install(availableUpdate, using: service) }
    }

    func refreshInstallationFailure() {
        guard !stopping, !state.isBusy, operation == nil else { return }
        let retry: UpdateManifest?
        if case .installFailed(let manifest, _) = state { retry = manifest }
        else { retry = nil }
        do {
            if let failure = try UpdateInstallationFailure.consume(application: Bundle.main.bundleURL) {
                state = .installFailed(retry, failure.message)
            }
        } catch {
            logger.error("Unable to read installation result: \(error.localizedDescription, privacy: .public)")
            state = .installFailed(retry, error.localizedDescription)
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
                availableUpdate = manifest
                state = manifest.map(State.available) ?? .upToDate
            case .failure(let error):
                availableUpdate = nil
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

    private func install(_ manifest: UpdateManifest, using service: UpdateService) {
        guard !stopping, !state.isBusy, operation == nil else { return }
        state = .downloading(manifest)
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try UpdateInstallationFailure.clear(application: Bundle.main.bundleURL)
                try UpdateInstaller.validateDestination(Bundle.main.bundleURL)
                let file = try await service.download(manifest)
                try Task.checkCancellation()
                state = .installing
                let update = try await UpdateInstaller.prepare(image: file, manifest: manifest,
                                                               application: Bundle.main.bundleURL)
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
                state = .installFailed(manifest, error.localizedDescription)
                refreshInstallationFailure()
            }
        }
    }
}
