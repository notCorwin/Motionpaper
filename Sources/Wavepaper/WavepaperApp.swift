import AppKit
import OSLog
import PlaybackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackController { try await NativeWallpaperSession.acquire() }
    let statusItem = StatusItemController()
    private let logger = Logger(subsystem: "local.wavepaper.app", category: "playback")

    func applicationDidFinishLaunching(_ notification: Notification) {
        playback.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.update(state)
            self.logger.info("Playback state: \(String(describing: state), privacy: .public)")
        }
        playback.setEnabled(true)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") {
            Task { await verifyUI() }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback.setEnabled(false)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") {
            verifyTermination()
        }
        #endif
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
