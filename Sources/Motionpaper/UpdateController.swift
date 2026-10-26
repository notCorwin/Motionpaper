import AppKit
import AppUI
import OSLog
import UpdateCore

@MainActor
final class UpdateController {
    enum State {
        case idle
        case checking
        case available(UpdateManifest)
        case downloading(UpdateManifest)
        case installing
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
    private var automaticCheck: Task<Void, Never>?
    private var stopping = false
    private var shutdown: Task<Void, Never>?
    private var pendingAlert: UpdateAlert?
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
        guard !stopping, service != nil, automaticCheck == nil else { return }
        automaticCheck = Task { [weak self] in
            do { try await UpdateInstaller.removeStaleInstallations(application: Bundle.main.bundleURL) }
            catch {
                self?.logger.error("Stale update cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            while !Task.isCancelled {
                self?.check(userInitiated: false)
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) }
                catch { return }
            }
        }
    }

    func checkForUpdates() { check(userInitiated: true) }

    func installAvailableUpdate() {
        if let availableUpdate, let service { install(availableUpdate, using: service) }
    }

    func installStableRelease() {
        if let availableStableRelease, let service { install(availableStableRelease, using: service) }
    }

    func stop() -> Task<Void, Never>? {
        if let shutdown { return shutdown }
        stopping = true
        let checks = automaticCheck
        checks?.cancel()
        automaticCheck = nil
        let pending = operation
        pending?.cancel()
        operation = nil
        let stable = stableCheck
        stable?.cancel()
        stableCheck = nil
        pendingAlert?.dismiss()
        guard checks != nil || pending != nil || stable != nil else { return nil }
        let shutdown = Task { [service] in
            await service?.cancel()
            await pending?.value
            await stable?.value
            await checks?.value
        }
        self.shutdown = shutdown
        return shutdown
    }

    private func check(userInitiated: Bool) {
        guard !stopping, operation == nil else { return }
        guard let service else {
            if userInitiated {
                operation = Task { [weak self] in
                    guard let self else { return }
                    defer { operation = nil }
                    await showAlert("无法检查更新", "请使用构建脚本或 GitHub Release 提供的应用。")
                }
            }
            return
        }
        checkStableRelease()
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            var requestedInstall: UpdateManifest?
            defer {
                operation = nil
                if let requestedInstall, !Task.isCancelled, !stopping { install(requestedInstall, using: service) }
            }
            do {
                let manifest = try await service.check()
                guard !Task.isCancelled else { return }
                availableUpdate = manifest
                state = manifest.map(State.available) ?? .idle
                if userInitiated {
                    if let manifest {
                        let alert = NSAlert()
                        alert.messageText = "发现更新 \(manifest.version?.description ?? manifest.shortCommit)"
                        alert.informativeText = "下载完成后将自动安装并重新启动 Motionpaper。"
                        alert.addButton(withTitle: "更新并重新启动")
                        alert.addButton(withTitle: "稍后")
                        if await presentAlert(alert) == .alertFirstButtonReturn, !Task.isCancelled, !stopping {
                            requestedInstall = manifest
                        }
                    } else {
                        let release = channel == .stable ? "正式版" : "Autobuild"
                        await showAlert("已是最新发布版本", "当前 Motionpaper 已是最新发布的\(release)。")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                availableUpdate = nil
                state = .idle
                logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated { await showAlert("无法检查更新", error.localizedDescription) }
            }
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
        guard !stopping, operation == nil else { return }
        state = .downloading(manifest)
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                operation = nil
                state = availableUpdate.map(State.available) ?? .idle
            }
            do {
                try UpdateInstaller.validateDestination(Bundle.main.bundleURL)
                let file = try await service.download(manifest)
                guard !Task.isCancelled else { return }
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
                guard !Task.isCancelled else { return }
                logger.error("Update installation failed: \(error.localizedDescription, privacy: .public)")
                await showAlert("无法安装更新", error.localizedDescription)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = await presentAlert(alert)
    }

    private func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard !stopping, !Task.isCancelled else { return .cancel }
        return await withCheckedContinuation { continuation in
            pendingAlert?.dismiss()
            let presentation = UpdateAlert(alert: alert) { [weak self] response in
                self?.pendingAlert = nil
                continuation.resume(returning: response)
            }
            pendingAlert = presentation
            presentation.show()
        }
    }
}

@MainActor
private final class UpdateAlert: NSObject, NSWindowDelegate {
    private let alert: NSAlert
    private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?

    init(alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    func show() {
        alert.layout()
        alert.window.delegate = self
        for button in alert.buttons {
            button.target = self
            button.action = #selector(selectButton(_:))
        }
        AlertPresentation.show(alert)
    }

    @objc private func selectButton(_ button: NSButton) {
        guard let index = alert.buttons.firstIndex(of: button) else { return }
        finish(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
    }

    func dismiss() { finish(.cancel) }

    func windowWillClose(_ notification: Notification) { finish(.cancel, closeWindow: false) }

    private func finish(_ response: NSApplication.ModalResponse, closeWindow: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        alert.window.delegate = nil
        if closeWindow { alert.window.close() }
        completion(response)
    }
}
