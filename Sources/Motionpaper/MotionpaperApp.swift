import AppKit
import Darwin
import Dispatch
import OSLog
import PlaybackCore
import UpdateCore
import WallpaperCore

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
        if CommandLine.arguments.contains("--verify-compatibility") {
            Task { await verifyCompatibility() }
            dispatchMain()
        }
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

    @MainActor
    private static func verifyCompatibility() async -> Never {
        let verifyPlayback = CommandLine.arguments.contains("--verify-playback")
        var interfaceAvailable = false
        let failure: String?
        do {
            try NativeWallpaperSession.checkCompatibility()
            interfaceAvailable = true
            if verifyPlayback {
                let first = try await NativeWallpaperSession.acquire()
                first.release()
                let second = try await NativeWallpaperSession.acquire()
                second.release()
            }
            failure = nil
        } catch {
            failure = String(describing: error)
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        struct Report: Encodable {
            let systemVersion: String
            let architecture: String
            let interfaceAvailable: Bool
            let playbackVerified: Bool
            let error: String?
        }
        do {
            let report = Report(systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                architecture: architecture, interfaceAvailable: interfaceAvailable,
                                playbackVerified: verifyPlayback && failure == nil, error: failure)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(report)
            data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            exit(EXIT_FAILURE)
        }
        exit(failure == nil ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
