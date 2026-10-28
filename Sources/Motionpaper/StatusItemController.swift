import AppKit
import PlaybackCore
import QuartzCore
import ServiceManagement
import UpdateCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let identifier = "Motionpaper.StatusItem"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let symbolView = StatusSymbolView()
    let menu = NSMenu()
    private let playbackStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "随开机自动启动：否", action: nil, keyEquivalent: "")
    private let loginApprovalItem = NSMenuItem(title: "在系统设置中允许开机启动", action: nil, keyEquivalent: "")
    private let launchAtLogin = LaunchAtLoginController()
    private var isUpdatingLaunchAtLogin = false
    private let updateItem = NSMenuItem(title: "检查更新", action: nil, keyEquivalent: "")
    private let stableReleaseItem = NSMenuItem(title: "更新到正式版", action: nil, keyEquivalent: "")
    private let repositoryItem = NSMenuItem(title: "打开 GitHub 仓库", action: nil, keyEquivalent: "")
    private let isAutobuild = Bundle.main.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String != "stable"
    private var isUpdating = false
    var onCheckForUpdates: (@MainActor () -> Void)?
    var onInstallUpdate: (@MainActor () -> Void)?
    var onInstallStableRelease: (@MainActor () -> Void)?
    var onOpenRepository: (@MainActor () -> Void)?
    var onMenuWillOpen: (@MainActor () -> Void)?

    override init() {
        super.init()
        statusItem.autosaveName = Self.identifier
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.title = ""
        // Ice identifies an item by its bundle ID and CGWindow title.
        button.window?.title = Self.identifier
        button.addSubview(symbolView)
        symbolView.setAccessibilityElement(false)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 20),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
        ])
        playbackStatusItem.isEnabled = false
        menu.autoenablesItems = false
        menu.delegate = self
        let bundle = Bundle.main
        let title: String
        if bundle.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String == "stable" {
            guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !version.isEmpty else {
                preconditionFailure("A stable Motionpaper build must declare its version")
            }
            title = "Motionpaper \(version)"
        } else {
            title = "Motionpaper Autobuild"
        }
        let versionItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        if let commit = bundle.object(forInfoDictionaryKey: "MotionpaperCommit") as? String {
            versionItem.toolTip = "当前提交：\(commit.prefix(12))"
        }
        menu.addItem(versionItem)
        menu.addItem(playbackStatusItem)
        menu.addItem(.separator())
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        menu.addItem(updateItem)
        stableReleaseItem.target = self
        stableReleaseItem.action = #selector(installStableRelease)
        stableReleaseItem.isHidden = true
        menu.addItem(stableReleaseItem)
        repositoryItem.action = #selector(openRepository)
        repositoryItem.target = self
        menu.addItem(repositoryItem)
        menu.addItem(.separator())
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchAtLoginItem)
        loginApprovalItem.target = self
        loginApprovalItem.action = #selector(openLoginSettings)
        loginApprovalItem.isHidden = true
        menu.addItem(loginApprovalItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Motionpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        update(.disabled)
        updateLaunchAtLogin(launchAtLogin.status)
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func installUpdate() { onInstallUpdate?() }
    @objc private func installStableRelease() { onInstallStableRelease?() }
    @objc private func openRepository() { onOpenRepository?() }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
        updateLaunchAtLogin(launchAtLogin.status)
    }

    func updateLaunchAtLogin(_ status: SMAppService.Status) {
        let failure = launchAtLogin.failureMessage
        if failure != nil {
            launchAtLoginItem.title = "随开机自动启动：更改失败，重试"
        } else if status == .requiresApproval {
            launchAtLoginItem.title = "随开机自动启动：等待允许"
        } else {
            launchAtLoginItem.title = status == .enabled ? "随开机自动启动：是" : "随开机自动启动：否"
        }
        launchAtLoginItem.state = .off
        launchAtLoginItem.toolTip = failure ?? (status == .requiresApproval
            ? "请在系统设置的「通用 → 登录项与扩展」中允许 Motionpaper；再次点击可取消。" : nil)
        loginApprovalItem.isHidden = status != .requiresApproval
        // A fresh mainApp service can report .notFound until its first registration.
        launchAtLoginItem.isEnabled = !isUpdatingLaunchAtLogin
    }

    @objc private func toggleLaunchAtLogin() {
        guard !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        updateLaunchAtLogin(launchAtLogin.status)
        Task {
            defer {
                isUpdatingLaunchAtLogin = false
                updateLaunchAtLogin(launchAtLogin.status)
            }
            try? await launchAtLogin.toggle()
        }
    }

    func updateRepositoryError(_ message: String?) {
        repositoryItem.title = message == nil ? "打开 GitHub 仓库" : "无法打开仓库，重试"
        repositoryItem.toolTip = message
    }

    func update(_ state: UpdateController.State) {
        isUpdating = state.isBusy
        stableReleaseItem.isEnabled = !isUpdating
        updateItem.isEnabled = true
        updateItem.title = "检查更新"
        updateItem.toolTip = nil
        updateItem.action = #selector(checkForUpdates)
        switch state {
        case .idle:
            break
        case .checking:
            updateItem.title = "正在检查更新…"
            updateItem.isEnabled = false
        case .upToDate:
            updateItem.title = "已是最新版本"
            updateItem.isEnabled = false
        case .available(let manifest):
            updateItem.title = "更新并重新启动（\(manifest.version?.description ?? manifest.shortCommit)）"
            updateItem.action = #selector(installUpdate)
        case .downloading:
            updateItem.title = "正在下载更新…"
            updateItem.isEnabled = false
        case .installing:
            updateItem.title = "正在安装更新…"
            updateItem.isEnabled = false
        case .checkFailed(let message):
            updateItem.title = "检查更新失败，重试"
            updateItem.toolTip = message
        case .installFailed(let message):
            updateItem.title = "安装更新失败，重新检查"
            updateItem.toolTip = message
        }
    }

    func updateStableRelease(_ manifest: UpdateManifest?) {
        guard isAutobuild, manifest?.version != nil else {
            stableReleaseItem.isHidden = true
            return
        }
        stableReleaseItem.isHidden = false
        stableReleaseItem.isEnabled = !isUpdating
    }

    func update(_ state: PlaybackController.State) {
        symbolView.update(state)
        let description: String
        let failure: String?
        switch state {
        case .disabled:
            description = "播放已停止"
            failure = nil
        case .starting:
            description = "正在准备播放…"
            failure = nil
        case .enabled:
            description = "正在播放"
            failure = nil
        case .failed(let message):
            description = "无法播放"
            failure = message
        case .retrying(let message):
            description = "正在恢复播放…"
            failure = message
        }
        playbackStatusItem.title = description
        let toolTip = (["Motionpaper", description] + (failure.map { [$0] } ?? [])).joined(separator: "\n")
        playbackStatusItem.toolTip = toolTip
        statusItem.button?.toolTip = toolTip
        statusItem.button?.setAccessibilityLabel(toolTip)
        symbolView.updateToolTip(toolTip)
    }
}

@MainActor
final class StatusSymbolView: NSView {
    private enum Mode {
        case inactive, playing, warning
    }

    private var mode: Mode?
    private let imageView = NSImageView()
    private let warningImageView = NSImageView()
    private static let inactiveOpacity: Float = 0.35
    private static let animationKey = "motionpaper.flow"
    private static let warningAnimationKey = "motionpaper.warning"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let image = NSImage(named: "StatusIcon") else {
            preconditionFailure("The Motionpaper status icon is missing from the app bundle")
        }
        image.isTemplate = true
        imageView.image = image
        guard let warning = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) else {
            preconditionFailure("The Motionpaper warning symbol is unavailable")
        }
        warning.isTemplate = true
        warningImageView.image = warning
        for view in [imageView, warningImageView] {
            view.imageScaling = .scaleProportionallyDown
            view.contentTintColor = .labelColor
            view.wantsLayer = true
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        update(.disabled)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Decorative content must not intercept clicks on the native status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        warningImageView.frame = bounds
    }

    func update(_ state: PlaybackController.State) {
        let next: Mode = switch state {
        case .disabled, .starting: .inactive
        case .enabled: .playing
        case .failed, .retrying: .warning
        }
        guard next != mode else { return }
        mode = next
        render()
    }

    func updateToolTip(_ description: String) {
        toolTip = description
        imageView.toolTip = description
        warningImageView.toolTip = description
    }

    @objc private nonisolated func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.render() }
    }

    private func render() {
        guard let mode else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageView.layer?.removeAnimation(forKey: Self.animationKey)
        imageView.layer?.removeAnimation(forKey: Self.warningAnimationKey)
        warningImageView.layer?.removeAnimation(forKey: Self.warningAnimationKey)
        imageView.layer?.opacity = switch mode {
        case .inactive: Self.inactiveOpacity
        case .playing: 1
        case .warning: 0
        }
        warningImageView.layer?.opacity = mode == .warning ? 1 : 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch mode {
        case .inactive:
            break
        case .playing:
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.keyTimes = [0, 0.5, 1]
            animation.values = [0.55, 1, 0.55]
            animation.duration = 1.8
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic
            imageView.layer?.add(animation, forKey: Self.animationKey)
        case .warning:
            let start = CACurrentMediaTime()
            for (view, values) in [(imageView, [0, 1, 0]), (warningImageView, [1, 0, 1])] {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.keyTimes = [0, 0.5, 1]
                animation.values = values
                animation.duration = 2
                animation.beginTime = start
                animation.repeatCount = .infinity
                animation.calculationMode = .discrete
                view.layer?.add(animation, forKey: Self.warningAnimationKey)
            }
        }
    }

    #if DEBUG
    var playbackEnabled: Bool { mode == .playing }
    var warningEnabled: Bool { mode == .warning }
    var warningAnimationEnabled: Bool {
        imageView.layer?.animation(forKey: Self.warningAnimationKey) != nil
            && warningImageView.layer?.animation(forKey: Self.warningAnimationKey) != nil
    }

    var currentRibbonOpacity: Float {
        imageView.layer?.presentation()?.opacity ?? imageView.layer?.opacity ?? 0
    }

    var currentWarningOpacity: Float {
        warningImageView.layer?.presentation()?.opacity ?? warningImageView.layer?.opacity ?? 0
    }
    #endif
}
