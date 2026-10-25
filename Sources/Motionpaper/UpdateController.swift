import AppKit
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
    private let service: UpdateService?
    private var availableUpdate: UpdateManifest?
    private var operation: Task<Void, Never>?
    private var automaticCheck: Task<Void, Never>?
    private var stopping = false
    private var shutdown: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.motionpaper.app", category: "updates")

    init() {
        let bundle = Bundle.main
        if let commit = bundle.object(forInfoDictionaryKey: "MotionpaperCommit") as? String,
           let address = bundle.object(forInfoDictionaryKey: "MotionpaperUpdateURL") as? String,
           let url = URL(string: address),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            service = UpdateService(manifestURL: url, currentCommit: commit,
                                    directory: caches.appendingPathComponent("local.motionpaper.app/Updates", isDirectory: true))
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
        if let availableUpdate { install(availableUpdate) }
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
        guard checks != nil || pending != nil else { return nil }
        let shutdown = Task { [service] in
            await service?.cancel()
            await pending?.value
            await checks?.value
        }
        self.shutdown = shutdown
        return shutdown
    }

    private func check(userInitiated: Bool) {
        guard !stopping, operation == nil else { return }
        guard let service else {
            if userInitiated { showAlert("无法检查更新", "请使用构建脚本或 GitHub Release 提供的应用。") }
            return
        }
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            var requestedInstall: UpdateManifest?
            defer {
                operation = nil
                if let requestedInstall, !Task.isCancelled, !stopping { install(requestedInstall) }
            }
            do {
                let manifest = try await service.check()
                guard !Task.isCancelled else { return }
                availableUpdate = manifest
                state = manifest.map(State.available) ?? .idle
                if userInitiated {
                    if let manifest {
                        let alert = NSAlert()
                        alert.messageText = "发现更新 \(manifest.shortCommit)"
                        alert.informativeText = "下载完成后将自动安装并重新启动 Motionpaper。"
                        alert.addButton(withTitle: "更新并重新启动")
                        alert.addButton(withTitle: "稍后")
                        NSApp.activate()
                        if alert.runModal() == .alertFirstButtonReturn, !Task.isCancelled, !stopping {
                            requestedInstall = manifest
                        }
                    } else {
                        showAlert("已是最新提交", "当前 Motionpaper 与最新 Release 一致。")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                state = availableUpdate.map(State.available) ?? .idle
                logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
                if userInitiated { showAlert("无法检查更新", error.localizedDescription) }
            }
        }
    }

    private func install(_ manifest: UpdateManifest) {
        guard !stopping, operation == nil, let service else { return }
        state = .downloading(manifest)
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                operation = nil
                state = .available(manifest)
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
                NSApp.terminate(nil)
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Update installation failed: \(error.localizedDescription, privacy: .public)")
                showAlert("无法安装更新", error.localizedDescription)
            }
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }
}
