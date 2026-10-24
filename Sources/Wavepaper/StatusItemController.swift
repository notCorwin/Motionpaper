import AppKit
import PlaybackCore
import QuartzCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let symbolView = StatusSymbolView()
    let menu = NSMenu()
    let playbackItem = NSMenuItem(title: "启用播放", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var onToggle: (() -> Void)?

    override init() {
        super.init()
        statusItem.autosaveName = "Wavepaper.StatusItem"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.title = ""
        button.addSubview(symbolView)
        symbolView.setAccessibilityElement(false)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 20),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
        ])
        playbackItem.target = self
        playbackItem.action = #selector(togglePlayback)
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.autoenablesItems = false
        menu.addItem(playbackItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Wavepaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        update(.disabled)
    }

    func update(_ state: PlaybackController.State) {
        let enabled = state == .enabled
        symbolView.setPlaybackEnabled(enabled)
        playbackItem.state = enabled ? .on : .off
        playbackItem.isEnabled = state != .starting
        playbackItem.title = state == .starting ? "正在启用…" : "启用播放"
        errorItem.isHidden = true

        let description: String
        switch state {
        case .disabled: description = "Wavepaper：播放已禁用"
        case .starting: description = "Wavepaper：正在启用播放"
        case .enabled: description = "Wavepaper：播放已启用"
        case .failed(let message):
            description = "Wavepaper：无法启用播放"
            errorItem.title = "无法启用播放，请重试"
            errorItem.toolTip = message
            errorItem.isHidden = false
        }
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        symbolView.setAccessibilityLabel(description)
    }

    @objc private func togglePlayback() { onToggle?() }
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
