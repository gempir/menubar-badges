import AppKit
import ApplicationServices
import MenubarBadgesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: MenubarCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we behave strictly as a menu bar accessory app with no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--verify-focus-safety") {
            runLiveFocusSafetyVerification()
            return
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--render-screenshots"),
           idx + 1 < CommandLine.arguments.count {
            let outputDir = CommandLine.arguments[idx + 1]
            ScreenshotRenderer.renderAll(to: outputDir)
            exit(0)
        }

        let coordinator = MenubarCoordinator()
        self.coordinator = coordinator
        coordinator.start(openSettingsIfEmpty: true)

        // Prompt for Accessibility once on first launch if not yet granted.
        if !AXIsProcessTrusted() {
            coordinator.monitor.requestAccessibilityPermission()
        }
    }

    /// Re-opening the app from Spotlight / Applications brings up Settings cleanly.
    /// Deliberately NOT implemented in `applicationWillBecomeActive` to avoid accidental focus steals.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.tearDown()
    }

    // MARK: - Live macOS Focus-Safety Verification

    /// Exercises real `NSStatusItem` updates, visibility toggles, display styles, and
    /// `NonActivatingPanel` floating alerts on the running macOS system and verifies
    /// that `MenubarBadges` NEVER becomes active or steals frontmost focus.
    private func runLiveFocusSafetyVerification() {
        let suiteName = "com.gempir.menubar-badges.focus-test.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: testDefaults)
        let coordinator = MenubarCoordinator(settings: store)
        self.coordinator = coordinator

        let testApp = MonitoredApp(
            bundleId: "com.apple.mail",
            appName: "Mail",
            bundlePath: "/System/Applications/Mail.app",
            showAttentionArrow: true
        )
        store.addApp(testApp)
        coordinator.start(openSettingsIfEmpty: false)

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let initialFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        var focusStealEvents: [String] = []

        func checkFocus(step: String) {
            let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if NSApp.isActive {
                focusStealEvents.append("NSApp.isActive became true during: \(step)")
            }
            if currentFrontmostPID == ownPID {
                focusStealEvents.append("Frontmost app became MenubarBadges during: \(step)")
            }
            if NSApp.keyWindow != nil {
                focusStealEvents.append("NSApp.keyWindow became non-nil during: \(step)")
            }
        }

        let steps: [(TimeInterval, String, @MainActor () -> Void)] = [
            (0.15, "badge none -> 1 (redBadge)", {
                store.preferences.displayStyle = .redBadge
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .count(1, raw: "1"), isRunning: true)
                coordinator.monitor.pollNow()
            }),
            (0.35, "badge 1 -> 42 (redBadge)", {
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .count(42, raw: "42"), isRunning: true)
                coordinator.monitor.pollNow()
            }),
            (0.55, "show non-activating full-screen alert panel", {
                coordinator.controller(for: testApp.bundleId)?.showFloatingAlertPreview(
                    icon: store.icon(for: testApp),
                    badge: .count(42, raw: "42"),
                    countFormat: .parenthesized,
                    duration: 0.4
                )
            }),
            (0.75, "show non-activating attention arrow panel", {
                coordinator.controller(for: testApp.bundleId)?.showAttentionArrowPreview()
            }),
            (0.95, "switch to iconAndCount (1) & dot", {
                store.preferences.displayStyle = .iconAndCount
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .count(1, raw: "1"), isRunning: true)
                coordinator.monitor.pollNow()
            }),
            (1.15, "switch to simpleDot with dot badge", {
                store.preferences.displayStyle = .simpleDot
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .dot, isRunning: true)
                coordinator.monitor.pollNow()
            }),
            (1.35, "hide when no unread -> toggle visibility false", {
                store.preferences.hideWhenNoUnread = true
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .none, isRunning: true)
                coordinator.monitor.pollNow()
            }),
            (1.55, "re-appear when new unread arrives -> toggle visibility true", {
                coordinator.monitor.syntheticOverrides[testApp.bundleId] = MonitoredAppStatus(badge: .count(3, raw: "3"), isRunning: true)
                coordinator.monitor.pollNow()
            })
        ]

        for (delay, label, work) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                work()
                // Check immediately AND 80ms later after WindowServer processes the update.
                checkFocus(step: "\(label) [immediate]")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    checkFocus(step: "\(label) [settled]")
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            coordinator.tearDown()
            testDefaults.removePersistentDomain(forName: suiteName)
            let finalFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            print("FOCUS_VERIFY initialFrontmost=\(initialFrontmost) finalFrontmost=\(finalFrontmost)")
            if focusStealEvents.isEmpty {
                print("FOCUS_VERIFY PASS: Zero focus steals across \(steps.count) live menu bar & panel updates.")
                exit(0)
            } else {
                for failure in focusStealEvents {
                    fputs("FOCUS_VERIFY FAIL: \(failure)\n", stderr)
                }
                exit(1)
            }
        }
    }
}
