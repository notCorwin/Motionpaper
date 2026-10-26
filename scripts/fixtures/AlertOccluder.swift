import AppKit

@MainActor
final class FullScreenObserver: NSObject, NSWindowDelegate {
    var entered = false
    func windowDidEnterFullScreen(_ notification: Notification) { entered = true }
}

@main
enum AlertOccluder {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(1) }
        let report = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Motionpaper alert verification"
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        let observer = FullScreenObserver()
        window.delegate = observer
        Task {
            do {
                try Data().write(to: report.appendingPathExtension("occluder-started"))
                // The harness activates this app through LaunchServices once it is registered.
                let launchDeadline = ContinuousClock.now + .seconds(10)
                while !FileManager.default.fileExists(atPath: report.appendingPathExtension("occluder-activated").path) {
                    guard ContinuousClock.now < launchDeadline else { throw failure("LaunchServices did not activate the occluder") }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await waitForForeground()
                app.yieldActivation(toApplicationWithBundleIdentifier: CommandLine.arguments[2])
                try Data().write(to: report.appendingPathExtension("occluder-ready"))
                let deadline = ContinuousClock.now + .seconds(10)
                while !FileManager.default.fileExists(atPath: report.path) {
                    guard ContinuousClock.now < deadline else { throw failure("Alert did not appear") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let data = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any]
                guard let alertID = data?["alertWindowNumber"] as? Int,
                      let alertPID = data?["pid"] as? Int32 else { throw failure("Missing alert identity") }

                // The alert app has yielded activation before publishing its report.
                app.activate()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                try await waitForForeground()
                try verifyOrdering(alertID: alertID, alertPID: alertPID, occluder: window)

                window.level = .normal
                window.collectionBehavior = [.fullScreenPrimary]
                window.toggleFullScreen(nil)
                let fullScreenDeadline = ContinuousClock.now + .seconds(5)
                while !observer.entered {
                    guard ContinuousClock.now < fullScreenDeadline else { throw failure("Occluder did not enter full screen") }
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await waitForForeground()
                try verifyOrdering(alertID: alertID, alertPID: alertPID, occluder: window)
                print("Alert stayed above another app's floating and full-screen windows after losing focus.")
                app.terminate(nil)
            } catch {
                fputs("Alert presentation verification failed: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    @MainActor
    private static func waitForForeground() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !NSApp.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard ContinuousClock.now < deadline else {
                throw failure("Occluder did not take foreground focus; active=\(NSApp.isActive), foregroundPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private static func verifyOrdering(alertID: Int, alertPID: Int32, occluder: NSWindow) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            throw failure("Occluder did not take foreground focus")
        }
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        guard let alertIndex = windows.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == alertID }),
              let occluderIndex = windows.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == occluder.windowNumber }),
              windows[alertIndex][kCGWindowOwnerPID as String] as? Int32 == alertPID,
              let alertLayer = windows[alertIndex][kCGWindowLayer as String] as? Int,
              let occluderLayer = windows[occluderIndex][kCGWindowLayer as String] as? Int,
              let alertBounds = windows[alertIndex][kCGWindowBounds as String] as? NSDictionary,
              let occluderBounds = windows[occluderIndex][kCGWindowBounds as String] as? NSDictionary,
              let alertRect = CGRect(dictionaryRepresentation: alertBounds),
              let occluderRect = CGRect(dictionaryRepresentation: occluderBounds),
              alertRect.intersects(occluderRect), alertIndex < occluderIndex, alertLayer > occluderLayer else {
            throw failure("The alert was hidden or covered by the foreground application")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MotionpaperAlertVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
