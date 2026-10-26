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
        func recordReady(alert: NSWindow? = nil) throws {
            var observations: [String: Any] = [
                "phase": "readyToQuit", "pid": ProcessInfo.processInfo.processIdentifier,
                "alertVisible": alert?.isVisible == true,
            ]
            if let alert {
                observations["alertWindowNumber"] = alert.windowNumber
            }
            let data = try JSONSerialization.data(withJSONObject: observations)
            try data.write(to: verificationOutput.appendingPathComponent("verification.json"), options: .atomic)
        }
        do {
            try FileManager.default.createDirectory(at: verificationOutput, withIntermediateDirectories: true)
            updates.start()
            if CommandLine.arguments.contains("--verify-alert-termination") {
                updates.checkForUpdates()
                Task {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while true {
                        if NSApp.isActive,
                           let alert = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                            guard let value = ProcessInfo.processInfo.environment["MOTIONPAPER_VERIFICATION_FOREGROUND_PID"],
                                  let pid = Int32(value), let foreground = NSRunningApplication(processIdentifier: pid) else {
                                fputs("The foreground verification application is missing\n", stderr)
                                exit(1)
                            }
                            // Let the other app take focus only after this alert has activated.
                            NSApp.yieldActivation(to: foreground)
                            do { try recordReady(alert: alert) }
                            catch { exit(1) }
                            return
                        }
                        guard ContinuousClock.now < deadline else {
                            fputs("The update alert did not become visible and active; active=\(NSApp.isActive), foregroundPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)\n", stderr)
                            exit(1)
                        }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                }
                return
            }
            try recordReady()
            if CommandLine.arguments.contains("--verify-external-termination") { return }
            // Keep real asynchronous cleanup pending when the update task asks AppKit to quit.
            guard updates.stop() != nil else { throw UpdateError.installerUnavailable }
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        } catch {
            fputs("Unable to verify update termination: \(error)\n", stderr)
            exit(1)
        }
    }

    func verifyUpdateLaunch() async {
        do {
            var deadline = ContinuousClock.now + .seconds(10)
            while playback.state == .starting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if CommandLine.arguments.contains("--verify-playback-retry") {
                guard case .failed = playback.state,
                      let retry = statusItem.menu.item(withTitle: "重试播放"),
                      retry.isEnabled, !retry.isHidden else {
                    throw NSError(domain: "MotionpaperVerification", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "Playback failure did not offer retry"])
                }
                statusItem.menu.performActionForItem(at: statusItem.menu.index(of: retry))
                guard playback.state == .starting, retry.isHidden, !retry.isEnabled else {
                    throw NSError(domain: "MotionpaperVerification", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "Retry did not restart native playback acquisition"])
                }
                deadline = ContinuousClock.now + .seconds(10)
                while playback.state == .starting, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard playback.state == .enabled, retry.isHidden, !retry.isEnabled else {
                    throw NSError(domain: "MotionpaperVerification", code: 8,
                                  userInfo: [NSLocalizedDescriptionKey: "Playback did not recover after retry"])
                }
            }
            try FileManager.default.createDirectory(at: verificationOutput, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: [
                "phase": "readyToQuit", "state": String(describing: playback.state),
                "pid": ProcessInfo.processInfo.processIdentifier,
            ])
            try data.write(to: verificationOutput.appendingPathComponent("verification.json"), options: .atomic)
            NSApp.terminate(nil)
        } catch {
            fputs("Unable to verify update launch: \(error)\n", stderr)
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
            statusItem.menuWillOpen(statusItem.menu)
            let visibleItems = statusItem.menu.items.filter { !$0.isHidden }
            let versionTitle = Bundle.main.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String == "stable"
                ? "Motionpaper \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"
                : "Motionpaper Autobuild"
            let loginTitle = SMAppService.mainApp.status == .enabled ? "随开机自动启动：是" : "随开机自动启动：否"
            guard visibleItems.map(\.title)
                    == [versionTitle, "", "检查更新", "打开 GitHub 仓库", "", loginTitle, "", "退出 Motionpaper"],
                  visibleItems.enumerated().filter({ $0.element.isSeparatorItem }).map(\.offset) == [1, 4, 6],
                  visibleItems.first?.isEnabled == false,
                  visibleItems.first?.action == nil,
                  visibleItems.allSatisfy({ $0.state == .off }),
                  !visibleItems.contains(where: { $0.title == "更新到正式版" }),
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
        let originalRetry = statusItem.onRetryPlayback
        defer {
            statusItem.onOpenRepository = originalOpen
            statusItem.onRetryPlayback = originalRetry
            statusItem.update(playback.state)
            statusItem.menuWillOpen(statusItem.menu)
        }
        func require(_ valid: Bool) throws {
            guard valid else {
                throw NSError(domain: "MotionpaperVerification", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Login item states or repository action are incorrect"])
            }
        }
        let login = statusItem.menu.items.first { $0.title.hasPrefix("随开机自动启动：") }
        try require(login?.action != nil && login?.target === statusItem)
        let approvalTip = "请在系统设置的「通用 → 登录项与扩展」中允许 Motionpaper；再次点击可取消。"
        let statuses: [(SMAppService.Status, String, String?)] = [
            (.notRegistered, "随开机自动启动：否", nil),
            (.notFound, "随开机自动启动：否", nil),
            (.enabled, "随开机自动启动：是", nil),
            (.requiresApproval, "随开机自动启动：否", approvalTip),
        ]
        for (status, title, toolTip) in statuses {
            statusItem.updateLaunchAtLogin(status)
            try require(login?.title == title && login?.state == .off && login?.isEnabled == true
                        && login?.toolTip == toolTip)
        }
        statusItem.menuWillOpen(statusItem.menu)
        let actualLoginTitle = SMAppService.mainApp.status == .enabled ? "随开机自动启动：是" : "随开机自动启动：否"
        try require(login?.title == actualLoginTitle && login?.state == .off)
        var opens = 0
        statusItem.onOpenRepository = { opens += 1 }
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: "打开 GitHub 仓库"))
        try require(opens == 1)

        var retries = 0
        statusItem.onRetryPlayback = { retries += 1 }
        let diagnostic = "Native playback acquisition failed"
        statusItem.update(.failed(diagnostic))
        guard let retryItem = statusItem.menu.item(withTitle: "重试播放") else {
            try require(false)
            return
        }
        try require(!retryItem.isHidden && retryItem.isEnabled && retryItem.action != nil
                    && retryItem.target === statusItem && retryItem.toolTip == diagnostic)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: retryItem))
        try require(retries == 1)

        guard let address = Bundle.main.object(forInfoDictionaryKey: "MotionpaperRepositoryURL") as? String,
              let url = URL(string: address) else {
            try require(false)
            return
        }
        try require(url.scheme == "https" && url.host == "github.com" && url.pathComponents.count == 3)
        let owner = url.pathComponents[1]
        let repository = url.pathComponents[2]
        let releasesURL = "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=100"
        try require(Bundle.main.object(forInfoDictionaryKey: "MotionpaperUpdateURL") as? String
                    == releasesURL)
    }

    private func verifyUpdateMenu() throws {
        let originalCheck = statusItem.onCheckForUpdates
        let originalInstall = statusItem.onInstallUpdate
        let originalStableInstall = statusItem.onInstallStableRelease
        defer {
            statusItem.onCheckForUpdates = originalCheck
            statusItem.onInstallUpdate = originalInstall
            statusItem.onInstallStableRelease = originalStableInstall
            statusItem.updateStableRelease(nil)
            statusItem.update(UpdateController.State.idle)
        }
        var checks = 0
        var installs = 0
        var stableInstalls = 0
        statusItem.onCheckForUpdates = { checks += 1 }
        statusItem.onInstallUpdate = { installs += 1 }
        statusItem.onInstallStableRelease = { stableInstalls += 1 }
        func require(_ valid: Bool) throws {
            guard valid else {
                throw NSError(domain: "MotionpaperVerification", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Update menu states or actions are incorrect"])
            }
        }
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: "检查更新"))
        try require(checks == 1)
        statusItem.update(UpdateController.State.checking)
        try require(statusItem.menu.item(withTitle: "正在检查更新…")?.isEnabled == false)

        let stableManifest = UpdateManifest(
            commit: String(repeating: "c", count: 40), publishedAt: Date(),
            downloadURL: URL(string: "https://github.com/notCorwin/Motionpaper/releases/download/v1.0.0/Motionpaper-v1.0.0.dmg")!,
            sha256: String(repeating: "d", count: 64), size: 1, version: ReleaseVersion("1.0.0")!
        )
        let stableTitle = "更新到正式版"
        let isStableChannel = Bundle.main.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String == "stable"
        statusItem.updateStableRelease(nil)
        try require(statusItem.menu.item(withTitle: stableTitle)?.isHidden == true)
        statusItem.update(UpdateController.State.idle)
        statusItem.updateStableRelease(stableManifest)
        if isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isHidden == true)
        } else {
            let visibleItems = statusItem.menu.items.filter { !$0.isHidden }
            guard let checkIndex = visibleItems.firstIndex(where: { $0.title == "检查更新" }),
                  let stableIndex = visibleItems.firstIndex(where: { $0.title == stableTitle }),
                  let repositoryIndex = visibleItems.firstIndex(where: { $0.title == "打开 GitHub 仓库" }),
                  let stableItem = statusItem.menu.item(withTitle: stableTitle) else {
                try require(false)
                return
            }
            try require(!stableItem.isHidden && stableItem.isEnabled
                        && checkIndex < stableIndex && stableIndex < repositoryIndex)
            statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: stableTitle))
            try require(stableInstalls == 1)
            statusItem.update(UpdateController.State.checking)
            try require(stableItem.isEnabled == false)
            statusItem.update(UpdateController.State.idle)
            try require(stableItem.isEnabled == true)
            let newerVersion = "1.2.3"
            let newerStable = UpdateManifest(
                commit: stableManifest.commit, publishedAt: Date(),
                downloadURL: URL(string: "https://github.com/notCorwin/Motionpaper/releases/download/v\(newerVersion)/Motionpaper-v\(newerVersion).dmg")!,
                sha256: stableManifest.sha256, size: stableManifest.size, version: ReleaseVersion(newerVersion)!
            )
            statusItem.updateStableRelease(newerStable)
            try require(statusItem.menu.item(withTitle: stableTitle) === stableItem && !stableItem.isHidden)
            try require(!statusItem.menu.items.contains(where: { !$0.isHidden && $0.title.hasPrefix(stableTitle + " ") }))
            statusItem.updateStableRelease(stableManifest)
        }

        let commit = String(repeating: "a", count: 40)
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "Autobuild-\(commit)",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-10-25T00:00:00Z",
            "assets": [[
                "name": "Motionpaper-aaaaaaaaaaaa.dmg",
                "state": "uploaded",
                "browser_download_url": "https://github.com/notCorwin/Motionpaper/releases/download/Autobuild-\(commit)/Motionpaper-aaaaaaaaaaaa.dmg",
                "size": 1,
                "digest": "sha256:\(String(repeating: "b", count: 64))",
            ]],
        ])
        let releaseURL = URL(string: "https://api.github.com/repos/notCorwin/Motionpaper/releases?per_page=100")!
        let manifest = try UpdateManifest.decode(data, releaseURL: releaseURL)
        statusItem.update(UpdateController.State.available(manifest))
        let installTitle = "更新并重新启动（aaaaaaaaaaaa）…"
        try require(statusItem.menu.item(withTitle: installTitle)?.isHidden == false)
        try require(statusItem.menu.item(withTitle: "检查更新")?.isEnabled == true)
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: installTitle))
        try require(installs == 1)

        statusItem.update(UpdateController.State.available(stableManifest))
        let versionedInstallTitle = "更新并重新启动（1.0.0）…"
        try require(statusItem.menu.item(withTitle: versionedInstallTitle)?.isHidden == false)
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: versionedInstallTitle))
        try require(installs == 2)

        statusItem.update(UpdateController.State.downloading(manifest))
        try require(statusItem.menu.item(withTitle: "正在下载更新…")?.isEnabled == false)
        try require(statusItem.menu.item(withTitle: "检查更新")?.isEnabled == false)
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == false)
        }
        statusItem.update(UpdateController.State.available(manifest))
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == true)
        }
        statusItem.update(UpdateController.State.installing)
        try require(statusItem.menu.item(withTitle: "正在安装更新…")?.isEnabled == false)
        try require(statusItem.menu.item(withTitle: "检查更新")?.isEnabled == false)
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == false)
        }
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
