#if DEBUG
import AppKit
import Foundation
import PlaybackCore
import ServiceManagement
import UpdateCore

extension AppDelegate {
    private var verificationOutput: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOTIONPAPER_VERIFICATION_DIRECTORY"] ?? "/tmp/motionpaper-verification")
    }

    func verifyUpdateTermination() {
        func recordReady(menuOnlyVerified: Bool = false, updateTitle: String? = nil,
                         updateToolTip: String? = nil, visibleTitledWindows: Int? = nil) throws {
            var observations: [String: Any] = [
                "phase": "readyToQuit", "pid": ProcessInfo.processInfo.processIdentifier,
                "menuOnlyVerified": menuOnlyVerified,
            ]
            if let updateTitle { observations["updateMenuTitle"] = updateTitle }
            if let updateToolTip { observations["updateMenuToolTip"] = updateToolTip }
            if let visibleTitledWindows { observations["visibleTitledWindows"] = visibleTitledWindows }
            let data = try JSONSerialization.data(withJSONObject: observations)
            try data.write(to: verificationOutput.appendingPathComponent("verification.json"), options: .atomic)
        }
        do {
            try FileManager.default.createDirectory(at: verificationOutput, withIntermediateDirectories: true)
            updates.onStateChange = { [weak self] state in self?.statusItem.update(state) }
            statusItem.onMenuWillOpen = { [weak self] in self?.updates.menuWillOpen() }
            updates.start()
            if CommandLine.arguments.contains("--verify-menu-only") {
                Task { @MainActor in
                    do {
                        @MainActor
                        func waitForCheckFailure() async throws -> String {
                            let deadline = ContinuousClock.now + .seconds(5)
                            while ContinuousClock.now < deadline {
                                if case let .checkFailed(message) = updates.state { return message }
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            throw NSError(domain: "MotionpaperVerification", code: 9,
                                          userInfo: [NSLocalizedDescriptionKey: "The update check did not expose a retry state"])
                        }

                        guard case .idle = updates.state else {
                            throw NSError(domain: "MotionpaperVerification", code: 13,
                                          userInfo: [NSLocalizedDescriptionKey: "An update check started before the menu opened"])
                        }
                        statusItem.menuWillOpen(statusItem.menu)
                        guard case .checking = updates.state else {
                            throw NSError(domain: "MotionpaperVerification", code: 10,
                                          userInfo: [NSLocalizedDescriptionKey: "Opening the menu did not start an update check"])
                        }
                        _ = try await waitForCheckFailure()
                        statusItem.menuWillOpen(statusItem.menu)
                        guard case .checking = updates.state else {
                            throw NSError(domain: "MotionpaperVerification", code: 14,
                                          userInfo: [NSLocalizedDescriptionKey: "Reopening the menu did not retry the update check"])
                        }
                        let message = try await waitForCheckFailure()
                        statusItem.update(.idle)
                        try verifyUpdateMenu()
                        let failure = UpdateController.State.checkFailed(message)
                        statusItem.update(failure)
                        guard let updateItem = statusItem.menu.item(withTitle: "检查更新失败，重试"),
                              updateItem.isEnabled, updateItem.toolTip == message else {
                            throw NSError(domain: "MotionpaperVerification", code: 11,
                                          userInfo: [NSLocalizedDescriptionKey: "The failed check did not appear as a retryable menu item"])
                        }
                        let visibleTitledWindows = NSApp.windows.filter {
                            $0.isVisible && $0.styleMask.contains(.titled)
                        }.count
                        guard visibleTitledWindows == 0 else {
                            throw NSError(domain: "MotionpaperVerification", code: 12,
                                          userInfo: [NSLocalizedDescriptionKey: "Menu-only update verification opened a titled window"])
                        }
                        try recordReady(menuOnlyVerified: true, updateTitle: updateItem.title,
                                        updateToolTip: updateItem.toolTip,
                                        visibleTitledWindows: visibleTitledWindows)
                    } catch {
                        fputs("Unable to verify menu-only update behavior: \(error)\n", stderr)
                        exit(1)
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
            observations["warningEnabled"] = statusItem.symbolView.warningEnabled
            observations["warningAnimationEnabled"] = statusItem.symbolView.warningAnimationEnabled
            observations["warningOpacity"] = statusItem.symbolView.currentWarningOpacity
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
            statusItem.updateLaunchAtLogin(SMAppService.mainApp.status)
            let visibleItems = statusItem.menu.items.filter { !$0.isHidden }
            let versionTitle = Bundle.main.object(forInfoDictionaryKey: "MotionpaperReleaseChannel") as? String == "stable"
                ? "Motionpaper \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")"
                : "Motionpaper Autobuild"
            let loginStatus = SMAppService.mainApp.status
            let loginTitle: String
            switch loginStatus {
            case .enabled: loginTitle = "随开机自动启动：是"
            case .requiresApproval: loginTitle = "随开机自动启动：等待允许"
            default: loginTitle = "随开机自动启动：否"
            }
            var expectedMenuItems = [versionTitle, "", "检查更新", "打开 GitHub 仓库", "", loginTitle]
            if loginStatus == .requiresApproval { expectedMenuItems.append("在系统设置中允许开机启动") }
            expectedMenuItems.append(contentsOf: ["", "退出 Motionpaper"])
            let separatorOffsets = loginStatus == .requiresApproval ? [1, 4, 7] : [1, 4, 6]
            guard visibleItems.map(\.title) == expectedMenuItems,
                  visibleItems.enumerated().filter({ $0.element.isSeparatorItem }).map(\.offset) == separatorOffsets,
                  visibleItems.first?.isEnabled == false,
                  visibleItems.first?.action == nil,
                  visibleItems.allSatisfy({ $0.state == .off }),
                  !visibleItems.contains(where: { $0.title == "更新到正式版" }),
                  statusItem.symbolView.playbackEnabled,
                  !statusItem.symbolView.warningEnabled,
                  !statusItem.symbolView.warningAnimationEnabled,
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
            statusItem.update(.failed("警告图标效果验证"))
            var warningSamples: [[String: Any]] = []
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(200))
                warningSamples.append(["ribbon": statusItem.symbolView.currentRibbonOpacity,
                                       "warning": statusItem.symbolView.currentWarningOpacity])
            }
            observations["warningSamples"] = warningSamples
            let showsRibbon = warningSamples.contains {
                ($0["ribbon"] as? Float ?? 0) > 0.9 && ($0["warning"] as? Float ?? 1) < 0.1
            }
            let showsWarning = warningSamples.contains {
                ($0["warning"] as? Float ?? 0) > 0.9 && ($0["ribbon"] as? Float ?? 1) < 0.1
            }
            guard showsWarning,
                  NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || showsRibbon else {
                throw NSError(domain: "MotionpaperVerification", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "The warning indicator did not display the expected symbols"])
            }
            statusItem.update(playback.state)
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
        let originalMenuWillOpen = statusItem.onMenuWillOpen
        defer {
            statusItem.onOpenRepository = originalOpen
            statusItem.onRetryPlayback = originalRetry
            statusItem.onMenuWillOpen = originalMenuWillOpen
            statusItem.updateRepositoryError(nil)
            statusItem.update(playback.state)
            statusItem.updateLaunchAtLogin(SMAppService.mainApp.status)
        }
        func require(_ valid: Bool) throws {
            guard valid else {
                throw NSError(domain: "MotionpaperVerification", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "Login item states or repository action are incorrect"])
            }
        }
        func requirePlaybackIndicator(playback: Bool, warning: Bool) throws {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard statusItem.symbolView.playbackEnabled == playback,
                  statusItem.symbolView.warningEnabled == warning,
                  statusItem.symbolView.warningAnimationEnabled == (warning && !reduceMotion) else {
                throw NSError(domain: "MotionpaperVerification", code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "Playback warning indicator is incorrect"])
            }
        }
        var menuOpenings = 0
        statusItem.onMenuWillOpen = { menuOpenings += 1 }
        let login = statusItem.menu.items.first { $0.title.hasPrefix("随开机自动启动：") }
        try require(login?.action != nil && login?.target === statusItem)
        guard let approvalItem = statusItem.menu.item(withTitle: "在系统设置中允许开机启动") else {
            try require(false)
            return
        }
        let approvalTip = "请在系统设置的「通用 → 登录项与扩展」中允许 Motionpaper；再次点击可取消。"
        let statuses: [(SMAppService.Status, String, String?, Bool)] = [
            (.notRegistered, "随开机自动启动：否", nil, false),
            (.notFound, "随开机自动启动：否", nil, false),
            (.enabled, "随开机自动启动：是", nil, false),
            (.requiresApproval, "随开机自动启动：等待允许", approvalTip, true),
        ]
        for (status, title, toolTip, showsApproval) in statuses {
            statusItem.updateLaunchAtLogin(status)
            try require(login?.title == title && login?.state == .off && login?.isEnabled == true
                        && login?.toolTip == toolTip
                        && approvalItem.title == "在系统设置中允许开机启动"
                        && approvalItem.isHidden == !showsApproval)
        }
        statusItem.menuWillOpen(statusItem.menu)
        let actualLoginStatus = SMAppService.mainApp.status
        let actualLoginTitle: String
        switch actualLoginStatus {
        case .enabled: actualLoginTitle = "随开机自动启动：是"
        case .requiresApproval: actualLoginTitle = "随开机自动启动：等待允许"
        default: actualLoginTitle = "随开机自动启动：否"
        }
        try require(login?.title == actualLoginTitle && login?.state == .off
                    && approvalItem.isHidden == (actualLoginStatus != .requiresApproval))
        menuOpenings = 0
        statusItem.menuWillOpen(statusItem.menu)
        try require(menuOpenings == 1)

        var opens = 0
        statusItem.onOpenRepository = { opens += 1 }
        statusItem.menu.performActionForItem(at: statusItem.menu.indexOfItem(withTitle: "打开 GitHub 仓库"))
        try require(opens == 1)
        let repositoryError = "The repository could not be opened"
        statusItem.updateRepositoryError(repositoryError)
        guard let retryRepository = statusItem.menu.item(withTitle: "无法打开仓库，重试") else {
            try require(false)
            return
        }
        try require(retryRepository.isEnabled && retryRepository.toolTip == repositoryError)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: retryRepository))
        try require(opens == 2)
        statusItem.updateRepositoryError(nil)
        try require(retryRepository.title == "打开 GitHub 仓库" && retryRepository.toolTip == nil)

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
        try requirePlaybackIndicator(playback: false, warning: true)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: retryItem))
        try require(retries == 1)
        for state in [PlaybackController.State.starting, .enabled, .disabled] {
            statusItem.update(state)
            try requirePlaybackIndicator(playback: state == .enabled, warning: false)
            try require(retryItem.isHidden && !retryItem.isEnabled)
            statusItem.update(.failed(diagnostic))
            try requirePlaybackIndicator(playback: false, warning: true)
        }

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
        func requireUpdateItem(_ title: String, enabled: Bool = true, toolTip: String? = nil) throws -> NSMenuItem {
            let items = statusItem.menu.items.filter {
                !$0.isHidden && $0.title != "更新到正式版"
                    && ($0.title.contains("更新") || $0.title == "已是最新版本")
            }
            guard items.count == 1, let item = items.first,
                  item.title == title, item.isEnabled == enabled, item.toolTip == toolTip else {
                throw NSError(domain: "MotionpaperVerification", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Expected a single update menu item: \(title)"])
            }
            return item
        }
        let checkItem = try requireUpdateItem("检查更新")
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: checkItem))
        try require(checks == 1)
        statusItem.update(UpdateController.State.checking)
        _ = try requireUpdateItem("正在检查更新…", enabled: false)

        statusItem.update(UpdateController.State.upToDate)
        _ = try requireUpdateItem("已是最新版本", enabled: false)

        let checkError = "The release catalog could not be read"
        statusItem.update(UpdateController.State.checkFailed(checkError))
        let failedCheckItem = try requireUpdateItem("检查更新失败，重试", toolTip: checkError)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: failedCheckItem))
        try require(checks == 2)

        let missingManifestError = "The previous update target is unavailable"
        statusItem.update(UpdateController.State.installFailed(nil, missingManifestError))
        let failedWithoutManifest = try requireUpdateItem("安装更新失败，重新检查", toolTip: missingManifestError)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: failedWithoutManifest))
        try require(checks == 3)

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
        let installTitle = "更新并重新启动（aaaaaaaaaaaa）"
        let availableItem = try requireUpdateItem(installTitle)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: availableItem))
        try require(installs == 1 && checks == 3)

        let installError = "The downloaded update could not be installed"
        statusItem.update(UpdateController.State.installFailed(manifest, installError))
        let retryTitle = "重试更新并重新启动（aaaaaaaaaaaa）"
        let retryItem = try requireUpdateItem(retryTitle, toolTip: installError)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: retryItem))
        try require(installs == 2 && checks == 3)

        statusItem.update(UpdateController.State.available(stableManifest))
        let versionedInstallTitle = "更新并重新启动（1.0.0）"
        let versionedItem = try requireUpdateItem(versionedInstallTitle)
        statusItem.menu.performActionForItem(at: statusItem.menu.index(of: versionedItem))
        try require(installs == 3 && checks == 3)

        statusItem.update(UpdateController.State.downloading(manifest))
        _ = try requireUpdateItem("正在下载更新…", enabled: false)
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == false)
        }
        statusItem.update(UpdateController.State.available(manifest))
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == true)
        }
        statusItem.update(UpdateController.State.installing)
        _ = try requireUpdateItem("正在安装更新…", enabled: false)
        if !isStableChannel {
            try require(statusItem.menu.item(withTitle: stableTitle)?.isEnabled == false)
        }

        let checkStates: [(UpdateController.State, String, Bool, String?)] = [
            (.idle, "检查更新", true, nil),
            (.checking, "正在检查更新…", false, nil),
            (.upToDate, "已是最新版本", false, nil),
            (.checkFailed(checkError), "检查更新失败，重试", true, checkError),
            (.installFailed(nil, missingManifestError), "安装更新失败，重新检查", true, missingManifestError),
        ]
        for (state, title, enabled, toolTip) in checkStates {
            statusItem.update(UpdateController.State.installFailed(manifest, installError))
            statusItem.update(state)
            let item = try requireUpdateItem(title, enabled: enabled, toolTip: toolTip)
            if enabled {
                let previousChecks = checks
                statusItem.menu.performActionForItem(at: statusItem.menu.index(of: item))
                try require(checks == previousChecks + 1 && installs == 3)
            }
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
