#if DEBUG
import AppKit
import Foundation
import ServiceManagement
import UpdateCore

extension AppDelegate {
    private var verificationOutput: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOTIONPAPER_VERIFICATION_DIRECTORY"] ?? "/tmp/motionpaper-verification")
    }

    func verifyUpdateTermination() {
        do {
            try FileManager.default.createDirectory(at: verificationOutput, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["phase": "readyToQuit"])
            try data.write(to: verificationOutput.appendingPathComponent("verification.json"), options: .atomic)
            updates.start()
            // Keep real asynchronous cleanup pending when the update task asks AppKit to quit.
            guard updates.stop() != nil else { throw UpdateError.installerUnavailable }
            Task { NSApp.terminate(nil) }
        } catch {
            fputs("Unable to verify update termination: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    func verifyUI() async {
        let output = verificationOutput
        var observations: [String: Any] = [:]
        func record(_ phase: String) throws {
            observations["phase"] = phase
            observations["pid"] = ProcessInfo.processInfo.processIdentifier
            observations["state"] = String(describing: playback.state)
            observations["menuItems"] = statusItem.menu.items.filter { !$0.isHidden }.map(\.title)
            observations["hasCheckedMenuItem"] = statusItem.menu.items.contains { $0.state != .off }
            observations["iconEnabled"] = statusItem.symbolView.playbackEnabled
            observations["iconOpacity"] = statusItem.symbolView.alphaValue
            observations["ribbonOpacity"] = statusItem.symbolView.currentRibbonOpacity
            observations["timestamp"] = Date().timeIntervalSince1970
            observations["menuBarWindowTitle"] = statusItem.symbolView.window?.title
            let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("verification.json"), options: .atomic)
        }
        func waitUntilEnabled() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while playback.state == .starting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard playback.state == .enabled else {
                throw NSError(domain: "MotionpaperVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native playback did not become enabled"])
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
            try await waitUntilEnabled()
            let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            let titles = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
                .compactMap { $0[kCGWindowName as String] as? String }
            observations["windowTitles"] = titles
            let visibleItems = statusItem.menu.items.filter { !$0.isHidden }
            statusItem.menuWillOpen(statusItem.menu)
            guard visibleItems.filter({ !$0.isSeparatorItem }).map(\.title)
                    == ["开机自动启动", "检查更新…", "打开 GitHub 仓库", "退出 Motionpaper"],
                  visibleItems.filter({ $0.title != "开机自动启动" }).allSatisfy({ $0.state == .off }),
                  statusItem.symbolView.playbackEnabled,
                  titles.contains(StatusItemController.identifier),
                  let quit = visibleItems.last else {
                throw NSError(domain: "MotionpaperVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected automatic playback, login/repository/update/quit actions, and stable CGWindow identity"])
            }
            try verifyApplicationMenu()
            observations["applicationMenuVerified"] = true
            try verifyUpdateMenu()
            observations["updateMenuVerified"] = true
            try record("enabled")
            var samples: [[String: Any]] = []
            for _ in 0..<16 {
                samples.append(["time": Date().timeIntervalSince1970,
                                "opacity": statusItem.symbolView.currentRibbonOpacity])
                try await Task.sleep(for: .milliseconds(150))
            }
            observations["animationSamples"] = samples
            observations["reduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let opacities = samples.compactMap { $0["opacity"] as? Float }
                guard let low = opacities.min(), let high = opacities.max(), high - low > 0.1 else {
                    throw NSError(domain: "MotionpaperVerification", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "The ribbon playback animation is not running"])
                }
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                statusItem.symbolView.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(200))
                try snapshot("enabled-" + name)
            }
            statusItem.symbolView.appearance = nil
            try record("readyToQuit")
            // Exercise the real menu action and applicationWillTerminate cleanup.
            statusItem.menu.performActionForItem(at: statusItem.menu.index(of: quit))
        } catch {
            observations["error"] = String(describing: error)
            try? record("failed")
            NSApp.terminate(nil)
        }
    }

    private func verifyApplicationMenu() throws {
        let originalOpen = statusItem.onOpenRepository
        defer {
            statusItem.onOpenRepository = originalOpen
            statusItem.menuWillOpen(statusItem.menu)
        }
        func require(_ valid: Bool) throws {
            guard valid else {
                throw NSError(domain: "MotionpaperVerification", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Login item states or repository action are incorrect"])
            }
        }
        let login = statusItem.menu.item(withTitle: "开机自动启动")
        try require(login?.action != nil && login?.target === statusItem)
        for (status, state) in [(SMAppService.Status.notRegistered, NSControl.StateValue.off),
                                (.notFound, .off), (.enabled, .on), (.requiresApproval, .mixed)] {
            statusItem.updateLaunchAtLogin(status)
            try require(login?.state == state && login?.isEnabled == true)
        }
        statusItem.menuWillOpen(statusItem.menu)
        let expected: NSControl.StateValue = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
        try require(login?.state == expected)
        var opens = 0
        statusItem.onOpenRepository = { opens += 1 }
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: "打开 GitHub 仓库"))
        try require(opens == 1)
        guard let address = Bundle.main.object(forInfoDictionaryKey: "MotionpaperRepositoryURL") as? String,
              let url = URL(string: address) else {
            try require(false)
            return
        }
        try require(url.scheme == "https" && url.host == "github.com" && url.pathComponents.count == 3)
        try require(Bundle.main.object(forInfoDictionaryKey: "MotionpaperUpdateURL") as? String
                    == address + "/releases/latest/download/update.json")
    }

    private func verifyUpdateMenu() throws {
        let originalCheck = statusItem.onCheckForUpdates
        let originalInstall = statusItem.onInstallUpdate
        defer {
            statusItem.onCheckForUpdates = originalCheck
            statusItem.onInstallUpdate = originalInstall
            statusItem.update(UpdateController.State.idle)
        }
        var checks = 0
        var installs = 0
        statusItem.onCheckForUpdates = { checks += 1 }
        statusItem.onInstallUpdate = { installs += 1 }
        func require(_ valid: Bool) throws {
            guard valid else {
                throw NSError(domain: "MotionpaperVerification", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Update menu states or actions are incorrect"])
            }
        }
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: "检查更新…"))
        try require(checks == 1)
        statusItem.update(UpdateController.State.checking)
        try require(statusItem.menu.item(withTitle: "正在检查更新…")?.isEnabled == false)
        let commit = String(repeating: "a", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "commit": commit, "publishedAt": "2026-10-25T00:00:00Z",
            "downloadURL": "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg",
            "sha256": String(repeating: "b", count: 64), "size": 1,
        ])
        let manifest = try UpdateManifest.decode(data, manifestURL: URL(string: "https://github.com/notCorwin/Motionpaper/releases/latest/download/update.json")!)
        statusItem.update(UpdateController.State.available(manifest))
        let installTitle = "更新并重新启动（aaaaaaaaaaaa）…"
        try require(statusItem.menu.item(withTitle: installTitle)?.isHidden == false)
        try require(statusItem.menu.item(withTitle: "检查更新…")?.isEnabled == true)
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: installTitle))
        try require(installs == 1)
        statusItem.update(UpdateController.State.downloading(manifest))
        try require(statusItem.menu.item(withTitle: "正在下载更新…")?.isEnabled == false)
        try require(statusItem.menu.item(withTitle: "检查更新…")?.isEnabled == false)
        statusItem.update(UpdateController.State.installing)
        try require(statusItem.menu.item(withTitle: "正在安装更新…")?.isEnabled == false)
        try require(statusItem.menu.item(withTitle: "检查更新…")?.isEnabled == false)
    }

    func verifyTermination() {
        let path = verificationOutput.appendingPathComponent("verification.json")
        do {
            let data = try Data(contentsOf: path)
            var observations = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            observations["shutdownState"] = String(describing: playback.state)
            observations["shutdownIconEnabled"] = statusItem.symbolView.playbackEnabled
            if observations["error"] == nil {
                observations["phase"] = "terminated"
            }
            let result = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            try result.write(to: path, options: .atomic)
        } catch {
            fputs("Unable to record termination verification: \(error)\n", stderr)
        }
    }
}
#endif
