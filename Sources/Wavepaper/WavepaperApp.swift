import AppKit
import OSLog
import PlaybackCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackController { try await NativeWallpaperSession.acquire() }
    let statusItem = StatusItemController()
    let updates = UpdateController()
    private let logger = Logger(subsystem: "local.wavepaper.app", category: "playback")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        statusItem.onDownloadUpdate = { [weak self] in self?.updates.downloadAvailableUpdate() }
        updates.onStateChange = { [weak self] state in self?.statusItem.update(state) }
        playback.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.update(state)
            self.logger.info("Playback state: \(String(describing: state), privacy: .public)")
        }
        playback.setEnabled(true)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") {
            Task { await verifyUI() }
            return
        }
        #endif
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
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
