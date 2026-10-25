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
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: (@MainActor (State) -> Void)?
    private let service: UpdateService?
    private var availableUpdate: UpdateManifest?
    private var operation: Task<Void, Never>?
    private var automaticCheck: Task<Void, Never>?
    private let logger = Logger(subsystem: "local.wavepaper.app", category: "updates")

    init() {
        let bundle = Bundle.main
        if let commit = bundle.object(forInfoDictionaryKey: "WavepaperCommit") as? String,
           let address = bundle.object(forInfoDictionaryKey: "WavepaperUpdateURL") as? String,
           let url = URL(string: address),
           let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            service = UpdateService(manifestURL: url, currentCommit: commit,
                                    directory: caches.appendingPathComponent("local.wavepaper.app/Updates", isDirectory: true))
        } else {
            service = nil
        }
    }

    func start() {
        guard service != nil, automaticCheck == nil else { return }
        automaticCheck = Task { [weak self] in
            while !Task.isCancelled {
                self?.check(userInitiated: false)
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) }
                catch { return }
            }
        }
    }

    func checkForUpdates() { check(userInitiated: true) }

    func downloadAvailableUpdate() {
        if let availableUpdate { download(availableUpdate) }
    }

    func stop() {
        automaticCheck?.cancel()
        automaticCheck = nil
        operation?.cancel()
        operation = nil
    }

    private func check(userInitiated: Bool) {
        guard operation == nil else { return }
        guard let service else {
            if userInitiated { showAlert("无法检查更新", "请使用构建脚本或 GitHub Release 提供的应用。") }
            return
        }
        state = .checking
        operation = Task { [weak self] in
            guard let self else { return }
            var requestedDownload: UpdateManifest?
            defer {
                operation = nil
                if let requestedDownload { download(requestedDownload) }
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
                        alert.informativeText = "下载并校验安装镜像后，将打开镜像供安装。"
                        alert.addButton(withTitle: "下载更新")
                        alert.addButton(withTitle: "稍后")
                        NSApp.activate()
                        if alert.runModal() == .alertFirstButtonReturn {
                            requestedDownload = manifest
                        }
                    } else {
                        showAlert("已是最新提交", "当前 Wavepaper 与最新 Release 一致。")
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

    private func download(_ manifest: UpdateManifest) {
        guard operation == nil, let service else { return }
        state = .downloading(manifest)
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                operation = nil
                state = .available(manifest)
            }
            do {
                let file = try await service.download(manifest)
                guard !Task.isCancelled else { return }
                guard NSWorkspace.shared.open(file) else {
                    showAlert("无法打开安装镜像", "请重试，或从 GitHub Release 下载更新。")
                    return
                }
                showAlert("安装更新 \(manifest.shortCommit)", "请退出 Wavepaper，将镜像中的 Wavepaper 拖入 Applications 并替换，然后重新打开应用。")
            } catch {
                guard !Task.isCancelled else { return }
                showAlert("更新下载失败", error.localizedDescription)
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
