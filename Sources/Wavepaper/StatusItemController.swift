import AppKit
import PlaybackCore
import QuartzCore

@MainActor
final class StatusItemController: NSObject {
    static let identifier = "Wavepaper.StatusItem"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let symbolView = StatusSymbolView()
    let menu = NSMenu()
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
    private let downloadItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var onCheckForUpdates: (@MainActor () -> Void)?
    var onDownloadUpdate: (@MainActor () -> Void)?

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
        if let commit = Bundle.main.object(forInfoDictionaryKey: "WavepaperCommit") as? String {
            updateItem.toolTip = "当前提交：\(commit.prefix(12))"
        }
        menu.addItem(updateItem)
        downloadItem.target = self
        downloadItem.action = #selector(downloadUpdate)
        downloadItem.isHidden = true
        menu.addItem(downloadItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Wavepaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        update(.disabled)
    }

    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func downloadUpdate() { onDownloadUpdate?() }

    func update(_ state: UpdateController.State) {
        updateItem.isEnabled = true
        updateItem.title = "检查更新…"
        downloadItem.isHidden = true
        downloadItem.isEnabled = true
        switch state {
        case .idle:
            break
        case .checking:
            updateItem.title = "正在检查更新…"
            updateItem.isEnabled = false
        case .available(let manifest):
            downloadItem.isHidden = false
            downloadItem.title = "下载更新（\(manifest.shortCommit)）…"
        case .downloading:
            updateItem.isEnabled = false
            downloadItem.isHidden = false
            downloadItem.title = "正在下载更新…"
            downloadItem.isEnabled = false
        }
    }

    func update(_ state: PlaybackController.State) {
        let enabled = state == .enabled
        symbolView.setPlaybackEnabled(enabled)
        errorItem.isHidden = true

        let description: String
        switch state {
        case .disabled: description = "Wavepaper：播放已停止"
        case .starting: description = "Wavepaper：正在开始播放"
        case .enabled: description = "Wavepaper：正在播放"
        case .failed(let message):
            description = "Wavepaper：无法开始播放"
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
    private let rows = (0..<3).map { _ in NSView() }
    private let images = (0..<3).map { _ in NSImageView() }
    private var hasRendered = false
    private static let inactiveOpacity: Float = 0.35
    private static let animationKey = "wavepaper.topToBottom"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep the system glyph intact. Each clipped copy supplies exactly one row.
        // VariableColor.reversing plays both ways, so use an explicit one-way order.
        let symbol = NSImage(systemSymbolName: "water.waves", accessibilityDescription: nil)
        for (row, image) in zip(rows, images) {
            row.wantsLayer = true
            row.clipsToBounds = true
            row.layer?.masksToBounds = true
            row.setAccessibilityElement(false)
            image.image = symbol
            image.symbolConfiguration = .init(pointSize: 16, weight: .medium)
            image.imageScaling = .scaleProportionallyDown
            image.contentTintColor = .labelColor
            image.setAccessibilityElement(false)
            row.addSubview(image)
            addSubview(row)
        }
        setPlaybackEnabled(false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Decorative content must not intercept clicks on the native status button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        for index in rows.indices {
            let height = bounds.height / 3
            let y = CGFloat(2 - index) * height
            rows[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            images[index].frame = NSRect(x: 0, y: -y, width: bounds.width, height: bounds.height)
        }
    }

    func setPlaybackEnabled(_ enabled: Bool) {
        guard !hasRendered || enabled != playbackEnabled else { return }
        hasRendered = true
        playbackEnabled = enabled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = CACurrentMediaTime()
        for (index, row) in rows.enumerated() {
            row.layer?.removeAnimation(forKey: Self.animationKey)
            row.alphaValue = CGFloat(Self.inactiveOpacity)
            guard enabled, let layer = row.layer else { continue }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            let dim = Self.inactiveOpacity
            switch index {
            case 0:
                animation.keyTimes = [0, 0.23, 0.33, 0.90, 1]
                animation.values = [1, 1, dim, dim, 1]
            case 1:
                animation.keyTimes = [0, 0.23, 0.33, 0.57, 0.67, 1]
                animation.values = [dim, dim, 1, 1, dim, dim]
            default:
                animation.keyTimes = [0, 0.57, 0.67, 0.90, 1]
                animation.values = [dim, dim, 1, 1, dim]
            }
            animation.duration = 0.9
            animation.beginTime = layer.convertTime(start, from: nil)
            animation.repeatCount = .infinity
            animation.autoreverses = false
            animation.calculationMode = .linear
            layer.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    #if DEBUG
    var currentWaveOpacities: [Float] {
        rows.map { $0.layer?.presentation()?.opacity ?? $0.layer?.opacity ?? 0 }
    }
    #endif
}
