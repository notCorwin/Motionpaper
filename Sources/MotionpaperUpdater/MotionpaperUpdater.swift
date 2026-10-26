import AppKit
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
        var applicationToReport: URL?
        var parentExited = false
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
            applicationToReport = update.destination
            try UpdateInstallationFailure.clear(application: update.destination)
            try waitForExit(of: pid, ready: update.ready)
            parentExited = true
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
            guard let application = applicationToReport, prepared != nil || parentExited else { return }
            do {
                try UpdateInstallationFailure.record(message: error.localizedDescription, application: application)
            } catch {
                logger.error("Could not persist installation failure for \(application.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            guard parentExited else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
            } catch {
                logger.error("Could not reopen Motionpaper after installation failure at \(application.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
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
