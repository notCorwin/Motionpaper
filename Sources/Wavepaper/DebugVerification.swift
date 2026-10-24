#if DEBUG
import AppKit
import Foundation

extension AppDelegate {
    @MainActor
    func verifyUI() async {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAVEPAPER_VERIFICATION_DIRECTORY"] ?? "/tmp/wavepaper-verification")
        var observations: [String: Any] = [:]
        func record(_ phase: String) throws {
            observations["phase"] = phase
            observations["pid"] = ProcessInfo.processInfo.processIdentifier
            observations["state"] = String(describing: playback.state)
            observations["checked"] = statusItem.playbackItem.state == .on
            observations["iconEnabled"] = statusItem.symbolView.playbackEnabled
            observations["iconOpacity"] = statusItem.symbolView.alphaValue
            observations["waveOpacities"] = statusItem.symbolView.currentWaveOpacities
            observations["timestamp"] = Date().timeIntervalSince1970
            let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("verification.json"), options: .atomic)
        }
        func waitUntilEnabled() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while playback.state == .starting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard playback.state == .enabled else {
                throw NSError(domain: "WavepaperVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native playback did not become enabled"])
            }
        }
        func snapshot(_ name: String) throws {
            // Capture the containing button so the image view's alpha is composited.
            let view = statusItem.symbolView.superview ?? statusItem.symbolView
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Exercise the actual native menu target/action, not a second UI path.
            statusItem.menu.performActionForItem(at: 0)
            try await waitUntilEnabled()
            try record("enabled")
            var samples: [[String: Any]] = []
            for _ in 0..<16 {
                samples.append(["time": Date().timeIntervalSince1970,
                                "opacities": statusItem.symbolView.currentWaveOpacities])
                try await Task.sleep(for: .milliseconds(150))
            }
            observations["animationSamples"] = samples
            try await Task.sleep(for: .seconds(5.6))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                statusItem.symbolView.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("enabled-" + name)
            }
            statusItem.symbolView.appearance = nil
            statusItem.menu.performActionForItem(at: 0)
            guard playback.state == .disabled, statusItem.playbackItem.state == .off,
                  !statusItem.symbolView.playbackEnabled else {
                throw NSError(domain: "WavepaperVerification", code: 2)
            }
            try record("disabled")
            try await Task.sleep(for: .seconds(8))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                statusItem.symbolView.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("disabled-" + name)
            }
            statusItem.symbolView.appearance = nil
            statusItem.menu.performActionForItem(at: 0)
            try await waitUntilEnabled()
            try record("complete")
        } catch {
            observations["error"] = String(describing: error)
            try? record("failed")
        }
    }
}
#endif
