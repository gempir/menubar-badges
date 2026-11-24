import AppKit
import ApplicationServices
import Combine
import Foundation
import MenubarBadgesCore

/// Reads macOS Dock badge labels via the Accessibility API (`com.apple.dock`).
///
/// Key improvements over legacy monitors:
/// - Matches apps primarily by bundle ID (via `AXURL`), avoiding broken title-only matching.
/// - Detects Dock process restarts (`killall Dock`) and re-arms `AXObserver`s automatically.
/// - Live-monitors Accessibility trust state so users don't need to restart after granting permission.
/// - Exposes the full current Dock snapshot for easy one-click onboarding in the app picker.
@MainActor
final class DockBadgeMonitor: ObservableObject {
    @Published private(set) var isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    @Published private(set) var dockItems: [DockItemSnapshot] = []
    @Published private(set) var statusesByBundleId: [String: MonitoredAppStatus] = [:]

    private var monitoredApps: [MonitoredApp] = []
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 1.0

    private var currentDockPID: pid_t?
    private var dockObserver: AXObserver?
    private var bundleIdCache: [String: String] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Optional hooks used in automated tests / screenshot mode to inject synthetic state.
    var syntheticOverrides: [String: MonitoredAppStatus] = [:]
    var syntheticAccessibilityOverride: Bool?

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        tearDownDockObserver()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }

    func start(monitoredApps: [MonitoredApp], pollInterval: TimeInterval = 1.0) {
        self.monitoredApps = monitoredApps
        self.pollInterval = max(0.3, pollInterval)
        setupWorkspaceObservers()
        restartTimer()
        pollNow()
    }

    func updateMonitoredApps(_ apps: [MonitoredApp]) {
        self.monitoredApps = apps
        pollNow()
    }

    func updatePollInterval(_ interval: TimeInterval) {
        let clamped = max(0.3, min(interval, 10.0))
        guard abs(clamped - pollInterval) > 0.05 else { return }
        pollInterval = clamped
        restartTimer()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        pollNow()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func pollNow() {
        let trusted = syntheticAccessibilityOverride ?? AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }

        var latestDockItems: [DockItemSnapshot] = []
        if syntheticAccessibilityOverride == nil && trusted {
            ensureDockObserverArmed()
            latestDockItems = readDockItems()
        } else {
            tearDownDockObserver()
        }

        if latestDockItems != dockItems {
            dockItems = latestDockItems
        }

        let runningBundleIds = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() }
        )

        var newStatuses: [String: MonitoredAppStatus] = [:]
        for app in monitoredApps {
            if let synthetic = syntheticOverrides[app.bundleId] {
                newStatuses[app.bundleId] = synthetic
                continue
            }

            let matchedDockItem = DockElementMatcher.findMatch(for: app, in: latestDockItems)
            let isRunning = runningBundleIds.contains(app.bundleId.lowercased()) || (matchedDockItem?.isRunning ?? false)
            let badge = BadgeParser.parse(matchedDockItem?.statusLabel)
            newStatuses[app.bundleId] = MonitoredAppStatus(badge: badge, isRunning: isRunning)
        }

        if newStatuses != statusesByBundleId {
            statusesByBundleId = newStatuses
        }
    }

    /// Brings the monitored app to the front (launching it if needed), or hides it if already frontmost.
    func activateOrToggleApp(_ app: MonitoredApp, hideIfFrontmost: Bool) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleId)

        if let runningApp = runningApps.first {
            if hideIfFrontmost,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.caseInsensitiveCompare(app.bundleId) == .orderedSame {
                runningApp.hide()
                return
            }

            // Try Dock AXPress first if trusted (this reliably unminimizes minimized windows too),
            // and also activate/reopen via NSWorkspace for guaranteed foregrounding.
            if let appURL = runningApp.bundleURL ?? app.bundlePath.map({ URL(fileURLWithPath: $0) }) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            } else {
                runningApp.activate()
            }
            return
        }

        // App is not running: launch it.
        if let appURL = app.bundlePath.map({ URL(fileURLWithPath: $0) }) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    // MARK: - Private: Timer & Workspace Observers

    private func restartTimer() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollNow()
            }
        }
        timer.tolerance = min(0.2, pollInterval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func setupWorkspaceObservers() {
        guard workspaceObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didWakeNotification
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pollNow()
                }
            }
            workspaceObservers.append(token)
        }
    }

    // MARK: - Private: Dock Accessibility Reading & Observer Re-arming

    private func ensureDockObserverArmed() {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").last?.processIdentifier else {
            tearDownDockObserver()
            return
        }

        if currentDockPID == dockPID, dockObserver != nil {
            return
        }

        // Dock launched or restarted with a new PID — tear down old observer and re-arm.
        tearDownDockObserver()
        currentDockPID = dockPID

        var observer: AXObserver?
        let createErr = AXObserverCreate(dockPID, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<DockBadgeMonitor>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                monitor.pollNow()
            }
        }, &observer)

        guard createErr == .success, let observer else {
            return
        }

        let dockApp = AXUIElementCreateApplication(dockPID)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, dockApp, kAXCreatedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, dockApp, kAXUIElementDestroyedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, dockApp, kAXTitleChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dockObserver = observer
    }

    private func tearDownDockObserver() {
        if let observer = dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            dockObserver = nil
        }
        currentDockPID = nil
    }

    private func readDockItems() -> [DockItemSnapshot] {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").last?.processIdentifier else {
            return []
        }

        let dockApp = AXUIElementCreateApplication(dockPID)
        var topChildrenObj: AnyObject?
        guard AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &topChildrenObj) == .success,
              let topChildren = topChildrenObj as? [AXUIElement] else {
            return []
        }

        var dockItemElements: [AXUIElement] = []
        for child in topChildren {
            var roleObj: AnyObject?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleObj)
            if (roleObj as? String) == kAXListRole {
                var listChildrenObj: AnyObject?
                if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenObj) == .success,
                   let listChildren = listChildrenObj as? [AXUIElement] {
                    dockItemElements.append(contentsOf: listChildren)
                }
            }
        }

        var snapshots: [DockItemSnapshot] = []
        snapshots.reserveCapacity(dockItemElements.count)

        for element in dockItemElements {
            var subroleObj: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObj)
            let subrole = subroleObj as? String
            if let subrole, subrole != "AXApplicationDockItem" {
                continue
            }

            var titleObj: AnyObject?
            var statusObj: AnyObject?
            var urlObj: AnyObject?
            var runningObj: AnyObject?

            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleObj)
            AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &statusObj)
            AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlObj)
            AXUIElementCopyAttributeValue(element, "AXIsApplicationRunning" as CFString, &runningObj)

            let title = titleObj as? String
            let statusLabel = statusObj as? String
            let url = urlObj as? URL
            let bundlePath = url?.path
            let bundleId = bundlePath.flatMap { resolveBundleId(forAppPath: $0) }
            let isRunning = (runningObj as? Bool) ?? ((runningObj as? NSNumber)?.boolValue ?? false)

            if title != nil || bundleId != nil || bundlePath != nil {
                snapshots.append(
                    DockItemSnapshot(
                        title: title,
                        bundleId: bundleId,
                        bundlePath: bundlePath,
                        statusLabel: statusLabel,
                        isRunning: isRunning
                    )
                )
            }
        }

        return snapshots
    }

    private func resolveBundleId(forAppPath path: String) -> String? {
        if let cached = bundleIdCache[path] {
            return cached.isEmpty ? nil : cached
        }
        let bundleId = Bundle(path: path)?.bundleIdentifier ?? ""
        bundleIdCache[path] = bundleId
        return bundleId.isEmpty ? nil : bundleId
    }
}
