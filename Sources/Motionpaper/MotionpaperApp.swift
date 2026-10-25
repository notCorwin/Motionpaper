import AppKit
import OSLog
import PlaybackCore
import UpdateCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playback = PlaybackController { try await NativeWallpaperSession.acquire() }
    let statusItem = StatusItemController()
    let updates = UpdateController()
    private let logger = Logger(subsystem: "local.motionpaper.app", category: "playback")
    private var termination: Task<Void, Never>?
    private var readyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--verify-update-termination") {
            verifyUpdateTermination()
            return
        }
        #endif
        statusItem.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        statusItem.onInstallUpdate = { [weak self] in self?.updates.installAvailableUpdate() }
        updates.onStateChange = { [weak self] state in self?.statusItem.update(state) }
        playback.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.update(state)
            self.logger.info("Playback state: \(String(describing: state), privacy: .public)")
        }
        playback.setEnabled(true)
        if let commit = Bundle.main.object(forInfoDictionaryKey: "MotionpaperCommit") as? String {
            do {
                try PreparedUpdate.confirmLaunch(arguments: CommandLine.arguments, application: Bundle.main.bundleURL,
                                                  commit: commit, pid: ProcessInfo.processInfo.processIdentifier)
            } catch {
                logger.error("Update launch confirmation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") {
            Task { await verifyUI() }
            return
        }
        #endif
        updates.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if termination != nil { return .terminateCancel }
        guard let cleanup = updates.stop() else { return .terminateNow }
        termination = Task {
            await cleanup.value
            readyToTerminate = true
            sender.terminate(nil)
        }
        // terminateLater runs a nested AppKit loop that can strand MainActor tasks
        // when termination itself was requested by the update task.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback.setEnabled(false)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") || CommandLine.arguments.contains("--verify-update-termination") {
            verifyTermination()
        }
        #endif
    }
}

@main
enum MotionpaperApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        #if DEBUG
        let verifyingTermination = CommandLine.arguments.contains("--verify-update-termination")
        #else
        let verifyingTermination = false
        #endif
        if !verifyingTermination, let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            return
        }
        if !verifyingTermination, !CommandLine.arguments.contains("--complete-update"),
           (try? UpdateInstaller.installationInProgress(application: Bundle.main.bundleURL)) == true {
            return
        }
        application.setActivationPolicy(verifyingTermination ? .prohibited : .accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
