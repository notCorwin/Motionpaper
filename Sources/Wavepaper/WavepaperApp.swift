import AppKit
import OSLog
import PlaybackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackController { try await NativeWallpaperSession.acquire() }
    let statusItem = StatusItemController()
    private let preferences: UserDefaults
    private let logger = Logger(subsystem: "local.wavepaper.app", category: "playback")

    override init() {
        #if DEBUG
        preferences = CommandLine.arguments.contains("--verify-ui")
            ? UserDefaults(suiteName: "local.wavepaper.verification")! : .standard
        #else
        preferences = .standard
        #endif
        preferences.register(defaults: ["playbackEnabled": true])
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        playback.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.update(state)
            self.logger.info("Playback state: \(String(describing: state), privacy: .public)")
        }
        statusItem.onToggle = { [weak self] in
            guard let self else { return }
            let enabled = self.playback.state != .enabled
            self.preferences.set(enabled, forKey: "playbackEnabled")
            self.playback.setEnabled(enabled)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") {
            Task { await verifyUI() }
            return
        }
        #endif
        playback.setEnabled(preferences.bool(forKey: "playbackEnabled"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback.setEnabled(false)
    }
}

@main
enum WavepaperApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        if let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            return
        }
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
