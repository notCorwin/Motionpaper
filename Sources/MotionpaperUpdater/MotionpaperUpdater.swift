import AppKit
import AppUI
import Darwin
import OSLog
import UpdateCore

@main
enum MotionpaperUpdater {
    @MainActor
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let pid = Int32(arguments[2]), pid > 0 else { return }
        let logger = Logger(subsystem: "local.motionpaper.app", category: "installer")
        var prepared: PreparedUpdate?
        do {
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let update = try PreparedUpdate.load(from: directory)
            let lease = try update.acquireLease()
            defer { try? lease.close() }
            prepared = update
            guard let parent = NSRunningApplication(processIdentifier: pid),
                  parent.bundleURL?.resolvingSymlinksInPath() == update.destination else {
                throw UpdateError.installerUnavailable
            }
            try waitForExit(of: pid, ready: update.ready)
            guard (try? Data(contentsOf: update.authorization)) == Data(update.commit.utf8) else {
                update.discard()
                return
            }
            prepared = nil // install owns cleanup once replacement begins.
            try await update.install { application, commit in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.createsNewApplicationInstance = true
                configuration.arguments = ["--complete-update", update.directory.path, commit]
                let launched = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
                do {
                    try await update.waitForLaunch(pid: launched.processIdentifier, commit: commit)
                } catch {
                    // Stop the unconfirmed new process before restoring its app bundle.
                    launched.forceTerminate()
                    let deadline = ContinuousClock.now + .seconds(5)
                    while kill(launched.processIdentifier, 0) == 0, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    throw error
                }
            }
        } catch {
            switch error {
            case UpdateError.rollbackFailed: break
            default: prepared?.discard()
            }
            logger.error("Installation failed: \(error.localizedDescription, privacy: .public)")
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "无法安装更新"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            AlertPresentation.runModal(alert)
        }
    }

    private static func waitForExit(of pid: Int32, ready: URL) throws {
        let queue = kqueue()
        guard queue >= 0 else { throw POSIXError(.EIO) }
        defer { close(queue) }
        var event = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC),
                           flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                           fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            throw UpdateError.installerUnavailable
        }
        // Acknowledge only after the kernel is watching this exact parent process.
        try Data().write(to: ready, options: .atomic)
        var result = kevent()
        var timeout = timespec(tv_sec: 60, tv_nsec: 0)
        let count = kevent(queue, nil, 0, &result, 1, &timeout)
        guard count == 1, result.flags & UInt16(EV_ERROR) == 0 else {
            throw UpdateError.applicationStillRunning
        }
    }
}
