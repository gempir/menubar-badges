import AppKit
import MenubarBadgesCore

/// Manages a single monitored app's `NSStatusItem` in the macOS menu bar.
///
/// Design invariants for zero focus-stealing on macOS 27+:
/// - Never uses `NSPopover` (uses `FloatingAlertController`'s `NonActivatingPanel`).
/// - Tracks the last rendered state and avoids mutating `statusItem` properties when unchanged.
/// - Uses `NSStatusItem.variableLength` so multi-digit badge counts never truncate.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private struct RenderedState: Equatable {
        var isVisible: Bool
        var badge: BadgeValue
        var isRunning: Bool
        var style: BadgeDisplayStyle
        var countFormat: CountTextFormat
        var grayOutWhenNoUnread: Bool
        var invertInDarkMode: Bool
        var monochromeIcon: Bool
        var isDarkAppearance: Bool
        var iconRevision: Int
    }

    private(set) var app: MonitoredApp
    private let statusItem: NSStatusItem
    private let floatingAlert = FloatingAlertController()
    private var lastRenderedState: RenderedState?
    private var lastBadge: BadgeValue = .none
    private var hasReceivedInitialStatus = false
    private var activeContextMenu: NSMenu?

    var onActivateApp: ((MonitoredApp) -> Void)?
    var onOpenSettings: ((MonitoredApp) -> Void)?
    var onRefreshNow: (() -> Void)?
    var onRemoveApp: ((MonitoredApp) -> Void)?
    var onQuit: (() -> Void)?

    init(app: MonitoredApp) {
        self.app = app
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "MenubarBadges_\(app.bundleId)"
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleButtonClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "\(app.appName) — Click to open, Option-click or right-click for Settings"
        }

        floatingAlert.onTap = { [weak self] in
            guard let self else { return }
            self.onActivateApp?(self.app)
        }
    }

    func update(
        app: MonitoredApp,
        status: MonitoredAppStatus,
        preferences: AppPreferences,
        baseIcon: NSImage,
        iconRevision: Int,
        forceFullScreenAlert: Bool = false
    ) {
        self.app = app

        let hideForNotRunning = preferences.hideWhenAppNotRunning && !status.isRunning
        let hideForNoUnread = preferences.hideWhenNoUnread && !status.badge.hasUnread
        let shouldBeVisible = !(hideForNotRunning || hideForNoUnread)

        let isDark = statusItem.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let nextState = RenderedState(
            isVisible: shouldBeVisible,
            badge: status.badge,
            isRunning: status.isRunning,
            style: preferences.displayStyle,
            countFormat: preferences.countTextFormat,
            grayOutWhenNoUnread: preferences.grayOutWhenNoUnread,
            invertInDarkMode: app.invertIconInDarkMode,
            monochromeIcon: app.monochromeIcon,
            isDarkAppearance: isDark,
            iconRevision: iconRevision
        )

        let previousBadge = lastBadge
        let badgeChanged = hasReceivedInitialStatus && previousBadge != status.badge
        hasReceivedInitialStatus = true
        lastBadge = status.badge

        if !status.badge.hasUnread {
            floatingAlert.hideAttentionArrow()
            floatingAlert.hideBadgeAlert()
        }

        if nextState != lastRenderedState {
            applyRenderedState(nextState, baseIcon: baseIcon)
            lastRenderedState = nextState
        }

        // Only trigger non-activating floating alerts when a genuinely new/increasing badge arrives.
        if badgeChanged && BadgeParser.shouldTriggerAlert(from: previousBadge, to: status.badge) {
            let anchorFrame = statusItem.button?.window?.frame
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?
                .caseInsensitiveCompare(app.bundleId) == .orderedSame

            if preferences.showAlertInFullScreen && (forceFullScreenAlert || FullScreenDetector.isActiveWindowFullScreen()) {
                floatingAlert.showBadgeAlert(
                    icon: baseIcon,
                    badge: status.badge,
                    countFormat: preferences.countTextFormat,
                    anchorFrame: anchorFrame
                )
            }

            if app.showAttentionArrow && !isFrontmost {
                floatingAlert.showAttentionArrow(anchorFrame: anchorFrame)
            }
        } else if !status.badge.hasUnread {
            floatingAlert.hideAttentionArrow()
        } else {
            floatingAlert.repositionAttentionArrow(anchorFrame: statusItem.button?.window?.frame)
        }
    }

    /// Triggers a preview of the non-activating floating alert panel (used in testing & settings preview).
    func showFloatingAlertPreview(icon: NSImage, badge: BadgeValue, countFormat: CountTextFormat, duration: TimeInterval = 2.5) {
        floatingAlert.showBadgeAlert(
            icon: icon,
            badge: badge,
            countFormat: countFormat,
            anchorFrame: statusItem.button?.window?.frame,
            duration: duration
        )
    }

    func showAttentionArrowPreview() {
        floatingAlert.showAttentionArrow(anchorFrame: statusItem.button?.window?.frame)
    }

    func hideFloatingAlerts() {
        floatingAlert.tearDown()
    }

    func destroy() {
        floatingAlert.tearDown()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Private Rendering

    private func applyRenderedState(_ state: RenderedState, baseIcon: NSImage) {
        if statusItem.isVisible != state.isVisible {
            statusItem.isVisible = state.isVisible
        }

        guard state.isVisible, let button = statusItem.button else {
            return
        }

        let options = BadgeIconRenderer.RenderOptions(
            style: state.style,
            countFormat: state.countFormat,
            grayOutWhenNoUnread: state.grayOutWhenNoUnread,
            invertInDarkMode: state.invertInDarkMode,
            monochrome: state.monochromeIcon,
            isDarkAppearance: state.isDarkAppearance
        )

        let rendered = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: state.badge,
            options: options
        )

        button.image = rendered.image
        if button.title != rendered.title {
            button.title = rendered.title
        }

        // Update tooltip with live unread state.
        if state.badge.hasUnread {
            button.toolTip = "\(app.appName) (\(state.badge.rawLabel)) — Click to open, Option-click or right-click for Settings"
        } else {
            button.toolTip = "\(app.appName) — Click to open, Option-click or right-click for Settings"
        }
    }

    // MARK: - Click & Context Menu Handling

    @objc private func handleButtonClick(_ sender: Any?) {
        floatingAlert.hideAttentionArrow()
        floatingAlert.hideBadgeAlert()

        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        let isOptionClick = NSEvent.modifierFlags.contains(.option)

        if isOptionClick {
            onOpenSettings?(app)
        } else if isRightClick {
            showContextMenu()
        } else {
            onActivateApp?(app)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let headerTitle = lastBadge.hasUnread ? "\(app.appName) (\(lastBadge.rawLabel))" : app.appName
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(.separator())

        let openAppItem = NSMenuItem(title: "Open \(app.appName)", action: #selector(menuOpenApp), keyEquivalent: "")
        openAppItem.target = self
        menu.addItem(openAppItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let refreshItem = NSMenuItem(title: "Refresh Badges", action: #selector(menuRefreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let removeItem = NSMenuItem(title: "Stop Monitoring \(app.appName)", action: #selector(menuRemoveApp), keyEquivalent: "")
        removeItem.target = self
        menu.addItem(removeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Menubar Badges", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        activeContextMenu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        activeContextMenu = nil
    }

    @objc private func menuOpenApp() {
        onActivateApp?(app)
    }

    @objc private func menuOpenSettings() {
        onOpenSettings?(app)
    }

    @objc private func menuRefreshNow() {
        onRefreshNow?()
    }

    @objc private func menuRemoveApp() {
        onRemoveApp?(app)
    }

    @objc private func menuQuit() {
        onQuit?()
    }
}
