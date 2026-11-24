import AppKit
import Combine
import MenubarBadgesCore
import ServiceManagement
import SwiftUI

/// Central coordinator connecting `SettingsStore`, `DockBadgeMonitor`,
/// per-app `StatusItemController`s, the control menu bar item, and the Settings window.
@MainActor
final class MenubarCoordinator: NSObject, ObservableObject {
    let settings: SettingsStore
    let monitor: DockBadgeMonitor
    let installedApps: InstalledAppsService

    @Published var selectedBundleId: String?

    private var statusControllers: [String: StatusItemController] = [:]
    private var controlStatusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    init(
        settings: SettingsStore = SettingsStore(),
        monitor: DockBadgeMonitor = DockBadgeMonitor(),
        installedApps: InstalledAppsService = InstalledAppsService()
    ) {
        self.settings = settings
        self.monitor = monitor
        self.installedApps = installedApps
        super.init()
    }

    func start(openSettingsIfEmpty: Bool = true) {
        bindState()
        syncStatusItems()
        syncControlStatusItem()

        monitor.start(
            monitoredApps: settings.monitoredApps,
            pollInterval: settings.preferences.pollIntervalSeconds
        )

        if openSettingsIfEmpty && settings.monitoredApps.isEmpty {
            showSettingsWindow()
        }
    }

    func showSettingsWindow(selecting bundleId: String? = nil) {
        if let bundleId {
            selectedBundleId = bundleId
        } else if selectedBundleId == nil {
            selectedBundleId = settings.monitoredApps.first?.bundleId
        }

        installedApps.loadIfNeeded()

        if settingsWindow == nil {
            let rootView = SettingsView(coordinator: self)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Menubar Badges"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 820, height: 560))
            window.minSize = NSSize(width: 700, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func addMonitoredApp(_ app: MonitoredApp) {
        if settings.addApp(app) {
            selectedBundleId = app.bundleId
        }
    }

    func removeMonitoredApp(bundleId: String) {
        settings.removeApp(bundleId: bundleId)
        if selectedBundleId == bundleId {
            selectedBundleId = settings.monitoredApps.first?.bundleId
        }
    }

    func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MenubarBadges: Failed to update Launch at Login: \(error.localizedDescription)")
        }
    }

    /// Exposes a controller for automated live verification tests.
    func controller(for bundleId: String) -> StatusItemController? {
        statusControllers[bundleId]
    }

    func tearDown() {
        monitor.stop()
        installedApps.stop()
        for controller in statusControllers.values {
            controller.destroy()
        }
        statusControllers.removeAll()
        if let control = controlStatusItem {
            NSStatusBar.system.removeStatusItem(control)
            controlStatusItem = nil
        }
    }

    // MARK: - Reactive Bindings

    private func bindState() {
        settings.$monitoredApps
            .receive(on: RunLoop.main)
            .sink { [weak self] apps in
                guard let self else { return }
                self.syncStatusItems()
                self.syncControlStatusItem()
                self.monitor.updateMonitoredApps(apps)
                self.renderAllStatusItems()
            }
            .store(in: &cancellables)

        settings.$preferences
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.syncControlStatusItem()
                self.monitor.updatePollInterval(prefs.pollIntervalSeconds)
                self.renderAllStatusItems()
            }
            .store(in: &cancellables)

        settings.$iconRevision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderAllStatusItems()
            }
            .store(in: &cancellables)

        monitor.$statusesByBundleId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.renderAllStatusItems()
            }
            .store(in: &cancellables)
    }

    private func syncStatusItems() {
        let desiredIds = Set(settings.monitoredApps.map(\.bundleId))

        // Remove controllers for apps no longer monitored.
        for (bundleId, controller) in statusControllers where !desiredIds.contains(bundleId) {
            controller.destroy()
            statusControllers.removeValue(forKey: bundleId)
        }

        // Add controllers for newly monitored apps.
        for app in settings.monitoredApps where statusControllers[app.bundleId] == nil {
            let controller = StatusItemController(app: app)
            controller.onActivateApp = { [weak self] targetApp in
                guard let self else { return }
                self.monitor.activateOrToggleApp(
                    targetApp,
                    hideIfFrontmost: self.settings.preferences.hideFrontmostAppOnClick
                )
            }
            controller.onOpenSettings = { [weak self] targetApp in
                self?.showSettingsWindow(selecting: targetApp.bundleId)
            }
            controller.onRefreshNow = { [weak self] in
                self?.monitor.pollNow()
            }
            controller.onRemoveApp = { [weak self] targetApp in
                self?.removeMonitoredApp(bundleId: targetApp.bundleId)
            }
            controller.onQuit = {
                NSApp.terminate(nil)
            }
            statusControllers[app.bundleId] = controller
        }
    }

    private func renderAllStatusItems() {
        for app in settings.monitoredApps {
            guard let controller = statusControllers[app.bundleId] else { continue }
            let status = monitor.statusesByBundleId[app.bundleId] ?? MonitoredAppStatus()
            let baseIcon = settings.icon(for: app)
            controller.update(
                app: app,
                status: status,
                preferences: settings.preferences,
                baseIcon: baseIcon,
                iconRevision: settings.iconRevision
            )
        }
    }

    private func syncControlStatusItem() {
        let shouldShowControl = settings.monitoredApps.isEmpty || settings.preferences.alwaysShowControlIcon
        if shouldShowControl {
            if controlStatusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.autosaveName = "MenubarBadges_ControlItem"
                if let button = item.button {
                    button.image = BadgeIconRenderer.controlStatusIcon()
                    button.toolTip = "Menubar Badges — Click to open Settings"
                    button.target = self
                    button.action = #selector(handleControlItemClick)
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                controlStatusItem = item
            }
            if controlStatusItem?.isVisible != true {
                controlStatusItem?.isVisible = true
            }
        } else if let existing = controlStatusItem {
            NSStatusBar.system.removeStatusItem(existing)
            controlStatusItem = nil
        }
    }

    @objc private func handleControlItemClick() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isRightClick, let item = controlStatusItem {
            let menu = NSMenu()
            let openItem = NSMenuItem(title: "Open Settings…", action: #selector(menuOpenSettingsFromControl), keyEquivalent: ",")
            openItem.target = self
            menu.addItem(openItem)

            let refreshItem = NSMenuItem(title: "Refresh Badges", action: #selector(menuRefreshFromControl), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            menu.addItem(.separator())

            let quitItem = NSMenuItem(title: "Quit Menubar Badges", action: #selector(menuQuitFromControl), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            showSettingsWindow()
        }
    }

    @objc private func menuOpenSettingsFromControl() {
        showSettingsWindow()
    }

    @objc private func menuRefreshFromControl() {
        monitor.pollNow()
    }

    @objc private func menuQuitFromControl() {
        NSApp.terminate(nil)
    }
}
