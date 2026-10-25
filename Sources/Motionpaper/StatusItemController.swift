import AppKit
import PlaybackCore
import QuartzCore

@MainActor
final class StatusItemController: NSObject {
    static let identifier = "Motionpaper.StatusItem"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let symbolView = StatusSymbolView()
    let menu = NSMenu()
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
    private let installItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var onCheckForUpdates: (@MainActor () -> Void)?
    var onInstallUpdate: (@MainActor () -> Void)?

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
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.autoenablesItems = false
        menu.addItem(errorItem)
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        if let commit = Bundle.main.object(forInfoDictionaryKey: "MotionpaperCommit") as? String {
            updateItem.toolTip = "当前提交：\(commit.prefix(12))"
        }
        menu.addItem(updateItem)
        installItem.target = self
        installItem.action = #selector(installUpdate)
        installItem.isHidden = true
        menu.addItem(installItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Motionpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        update(.disabled)
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func installUpdate() { onInstallUpdate?() }

    func update(_ state: UpdateController.State) {
        updateItem.isEnabled = true
        updateItem.title = "检查更新…"
        installItem.isHidden = true
        installItem.isEnabled = true
        switch state {
        case .idle:
            break
        case .checking:
            updateItem.title = "正在检查更新…"
            updateItem.isEnabled = false
        case .available(let manifest):
            installItem.isHidden = false
            installItem.title = "更新并重新启动（\(manifest.shortCommit)）…"
        case .downloading:
            updateItem.isEnabled = false
            installItem.isHidden = false
            installItem.title = "正在下载更新…"
            installItem.isEnabled = false
        case .installing:
            updateItem.isEnabled = false
            installItem.isHidden = false
            installItem.title = "正在安装更新…"
            installItem.isEnabled = false
        }
    }

    func update(_ state: PlaybackController.State) {
        let enabled = state == .enabled
        symbolView.setPlaybackEnabled(enabled)
        errorItem.isHidden = true

        let description: String
        switch state {
        case .disabled: description = "Motionpaper：播放已停止"
        case .starting: description = "Motionpaper：正在开始播放"
        case .enabled: description = "Motionpaper：正在播放"
        case .failed(let message):
            description = "Motionpaper：无法开始播放"
            errorItem.title = "无法开始播放，请退出后重新打开"
            errorItem.toolTip = message
            errorItem.isHidden = false
        }
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        symbolView.setAccessibilityLabel(description)
    }
}

@MainActor
final class StatusSymbolView: NSView {
    private(set) var playbackEnabled = false
    private let imageView = NSImageView()
    private var hasRendered = false
    private static let inactiveOpacity: CGFloat = 0.35
    private static let animationKey = "motionpaper.flow"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let image = NSImage(named: "StatusIcon") else {
            preconditionFailure("The Motionpaper status icon is missing from the app bundle")
        }
        image.isTemplate = true
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor
        imageView.wantsLayer = true
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        setPlaybackEnabled(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Decorative content must not intercept clicks on the native status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        guard !hasRendered || enabled != playbackEnabled else { return }
        hasRendered = true
        playbackEnabled = enabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        imageView.layer?.removeAnimation(forKey: Self.animationKey)
        imageView.alphaValue = enabled ? 1 : Self.inactiveOpacity
        guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.keyTimes = [0, 0.5, 1]
        animation.values = [0.55, 1, 0.55]
        animation.duration = 1.8
        animation.repeatCount = .infinity
        animation.calculationMode = .cubic
        imageView.layer?.add(animation, forKey: Self.animationKey)
    }

    #if DEBUG
    var currentRibbonOpacity: Float {
        imageView.layer?.presentation()?.opacity ?? imageView.layer?.opacity ?? 0
    }
    #endif
}
