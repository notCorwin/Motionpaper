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

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--verify-update-termination") {
            verifyUpdateTermination()
            return
        }
        #endif
        statusItem.onCheckForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        statusItem.onInstallUpdate = { [weak self] in self?.updates.installAvailableUpdate() }
        statusItem.onInstallStableRelease = { [weak self] in self?.updates.installStableRelease() }
        statusItem.onOpenRepository = { [weak self] in self?.openRepository() }
        statusItem.onRetryPlayback = { [weak self] in self?.playback.setEnabled(true) }
        updates.onStateChange = { [weak self] state in self?.statusItem.update(state) }
        updates.onStableReleaseChange = { [weak self] manifest in self?.statusItem.updateStableRelease(manifest) }
        playback.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.update(state)
            self.logger.info("Playback state: \(String(describing: state), privacy: .public)")
            if state == .enabled { self.confirmUpdateLaunch() }
        }
        playback.setEnabled(true)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-update-launch") {
            Task { await verifyUpdateLaunch() }
            return
        }
        if CommandLine.arguments.contains("--verify-ui") {
            Task { await verifyUI() }
            return
        }
        #endif
        updates.start()
    }

    private func confirmUpdateLaunch() {
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "MotionpaperCommit") as? String else { return }
        do {
            try PreparedUpdate.confirmLaunch(arguments: CommandLine.arguments, application: Bundle.main.bundleURL,
                                             commit: commit, pid: ProcessInfo.processInfo.processIdentifier)
        } catch {
            logger.error("Update launch confirmation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openRepository() {
        if let address = Bundle.main.object(forInfoDictionaryKey: "MotionpaperRepositoryURL") as? String,
           let url = URL(string: address), NSWorkspace.shared.open(url) {
            return
        }
        let alert = NSAlert()
        alert.messageText = "无法打开 GitHub 仓库"
        alert.informativeText = "请检查默认浏览器，或使用 GitHub Release 提供的应用。"
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if termination != nil { return .terminateLater }
        guard let cleanup = updates.stop() else { return .terminateNow }
        termination = Task {
            await cleanup.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback.setEnabled(false)
        #if DEBUG
        if CommandLine.arguments.contains("--verify-ui") || CommandLine.arguments.contains("--verify-update-termination")
            || CommandLine.arguments.contains("--verify-update-launch") {
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
        let verifyLifecycle = CommandLine.arguments.contains("--verify-assertion-lifecycle")
        var interfaceAvailable = false
        let failure: String?
        do {
            try NativeWallpaperSession.checkCompatibility()
            interfaceAvailable = true
            if verifyLifecycle {
                try await verifyAssertionLifecycle()
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
            let assertionLifecycleVerified: Bool
            let error: String?
        }
        do {
            let report = Report(systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                architecture: architecture, interfaceAvailable: interfaceAvailable,
                                assertionLifecycleVerified: verifyLifecycle && failure == nil, error: failure)
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

    @MainActor
    private static func verifyAssertionLifecycle() async throws {
        weak var observedSession: NativeWallpaperSession?
        let controller = PlaybackController {
            let session = try await NativeWallpaperSession.acquire()
            observedSession = session
            return session
        }
        defer { controller.setEnabled(false) }
        for _ in 0..<2 {
            controller.setEnabled(true)
            let deadline = ContinuousClock.now + .seconds(10)
            while controller.state == .starting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard controller.state == .enabled, observedSession != nil else {
                throw NSError(domain: "MotionpaperCompatibility", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Native assertion acquisition failed: \(controller.state)"])
            }
            // Exercise the controller's ownership during normal playback. This
            // checks the assertion lifecycle, not rendered desktop frames.
            try await Task.sleep(for: .seconds(2))
            guard observedSession != nil else {
                throw NSError(domain: "MotionpaperCompatibility", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The controller released its native session while enabled"])
            }
            controller.setEnabled(false)
            guard controller.state == .disabled, observedSession == nil else {
                throw NSError(domain: "MotionpaperCompatibility", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "The controller retained its native session after disabling playback"])
            }
        }
    }
}
