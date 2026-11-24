import AppKit
import MenubarBadgesCore
import SwiftUI

enum SidebarSelection: Hashable {
    case general
    case app(String)
}

struct SettingsView: View {
    @ObservedObject var coordinator: MenubarCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: DockBadgeMonitor

    @State private var selection: SidebarSelection? = .general
    @State private var showingAddAppSheet = false

    init(coordinator: MenubarCoordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        self.monitor = coordinator.monitor
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 255, max: 320)
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showingAddAppSheet) {
            AddAppSheet(
                coordinator: coordinator,
                installedApps: coordinator.installedApps,
                isPresented: $showingAddAppSheet
            )
        }
        .onChange(of: coordinator.selectedBundleId) { newBundleId in
            if let newBundleId {
                selection = .app(newBundleId)
            }
        }
        .onAppear {
            if let bundleId = coordinator.selectedBundleId {
                selection = .app(bundleId)
            } else {
                selection = .general
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !monitor.isAccessibilityTrusted {
                accessibilityBanner
            }

            List(selection: $selection) {
                Section("Configuration") {
                    Label("General Settings", systemImage: "slider.horizontal.3")
                        .tag(SidebarSelection.general)
                }

                Section("Monitored Apps (\(settings.monitoredApps.count))") {
                    if settings.monitoredApps.isEmpty {
                        Text("No apps monitored yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(settings.monitoredApps) { app in
                            sidebarAppRow(for: app)
                                .tag(SidebarSelection.app(app.bundleId))
                                .contextMenu {
                                    Button("Open \(app.appName)") {
                                        monitor.activateOrToggleApp(app, hideIfFrontmost: false)
                                    }
                                    Divider()
                                    Button("Stop Monitoring", role: .destructive) {
                                        coordinator.removeMonitoredApp(bundleId: app.bundleId)
                                        if selection == .app(app.bundleId) {
                                            selection = .general
                                        }
                                    }
                                }
                        }
                        .onMove { source, destination in
                            settings.moveApps(from: source, to: destination)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Button {
                    showingAddAppSheet = true
                } label: {
                    Label("Add App", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button {
                    monitor.pollNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh badges now")
                .buttonStyle(.borderless)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
        }
    }

    private var accessibilityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Accessibility Needed")
                    .font(.caption.bold())
            }
            Text("Required to read unread badges from the macOS Dock.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Grant Access") {
                    monitor.requestAccessibilityPermission()
                    monitor.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)

                Button("Recheck") {
                    monitor.pollNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func sidebarAppRow(for app: MonitoredApp) -> some View {
        let status = monitor.statusesByBundleId[app.bundleId] ?? MonitoredAppStatus()
        return HStack(spacing: 8) {
            Image(nsImage: settings.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.appName)
                    .lineLimit(1)
                Text(status.isRunning ? "Running" : "Not running")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status.badge.hasUnread {
                if status.badge == .dot {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                } else {
                    Text(status.badge.rawLabel)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .app(let bundleId):
            if let app = settings.monitoredApps.first(where: { $0.bundleId == bundleId }) {
                AppDetailView(coordinator: coordinator, app: app) {
                    selection = .general
                }
            } else {
                GeneralSettingsDetailView(coordinator: coordinator)
            }
        case .general, .none:
            GeneralSettingsDetailView(coordinator: coordinator)
        }
    }
}

private struct GeneralSettingsDetailView: View {
    @ObservedObject var coordinator: MenubarCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: DockBadgeMonitor

    @State private var launchAtLogin: Bool = false

    init(coordinator: MenubarCoordinator) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        self.monitor = coordinator.monitor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                displayStyleSection
                visibilitySection
                behaviorSection
                footerSection
            }
            .padding(24)
        }
        .onAppear {
            launchAtLogin = coordinator.isLaunchAtLoginEnabled()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Menubar Badges")
                    .font(.title2.bold())
                Text("Mirror Dock unread badges and dots into your menu bar without stealing window focus.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(monitor.isAccessibilityTrusted ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(monitor.isAccessibilityTrusted ? "Accessibility Connected" : "Accessibility Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayStyleSection: some View {
        GroupBox("Menu Bar Badge Style") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Style", selection: $settings.preferences.displayStyle) {
                    ForEach(BadgeDisplayStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.preferences.displayStyle.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.preferences.displayStyle == .iconAndCount {
                    Picker("Count format", selection: $settings.preferences.countTextFormat) {
                        ForEach(CountTextFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Icon size:")
                            .frame(width: 118, alignment: .leading)
                        Slider(
                            value: $settings.preferences.iconSize,
                            in: AppPreferences.iconSizeRange,
                            step: 1.0
                        )
                        .frame(width: 190)
                        Text("\(Int(settings.preferences.iconSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)

                        Spacer()

                        if settings.preferences.iconSize != AppPreferences.defaultIconSize
                            || settings.preferences.badgeSize != AppPreferences.defaultBadgeSize
                            || settings.preferences.dotSize != AppPreferences.defaultDotSize {
                            Button("Reset Sizes") {
                                settings.preferences.iconSize = AppPreferences.defaultIconSize
                                settings.preferences.badgeSize = AppPreferences.defaultBadgeSize
                                settings.preferences.dotSize = AppPreferences.defaultDotSize
                            }
                            .controlSize(.small)
                        }
                    }

                    HStack {
                        Text("Count badge size:")
                            .frame(width: 118, alignment: .leading)
                        Slider(
                            value: $settings.preferences.badgeSize,
                            in: AppPreferences.badgeSizeRange,
                            step: 1.0
                        )
                        .frame(width: 190)
                        .disabled(settings.preferences.displayStyle == .iconOnly || settings.preferences.displayStyle == .simpleDot)
                        Text("\(Int(settings.preferences.badgeSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }

                    HStack {
                        Text("Dot size:")
                            .frame(width: 118, alignment: .leading)
                        Slider(
                            value: $settings.preferences.dotSize,
                            in: AppPreferences.dotSizeRange,
                            step: 1.0
                        )
                        .frame(width: 190)
                        .disabled(settings.preferences.displayStyle == .iconOnly)
                        Text("\(Int(settings.preferences.dotSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }

                Divider()

                liveStylePreviewRow
            }
            .padding(8)
        }
    }

    private var liveStylePreviewRow: some View {
        let sampleIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Mail.app")
        let samples: [(String, BadgeValue)] = [
            ("Single", .count(1, raw: "1")),
            ("Double", .count(24, raw: "24")),
            ("Dot", .dot),
            ("Idle", .none)
        ]

        return HStack(spacing: 18) {
            Text("Preview:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(samples, id: \.0) { label, badge in
                let rendered = BadgeIconRenderer.renderStatusItem(
                    baseIcon: sampleIcon,
                    badge: badge,
                    options: .init(
                        style: settings.preferences.displayStyle,
                        countFormat: settings.preferences.countTextFormat,
                        iconSize: CGFloat(settings.preferences.iconSize),
                        badgeSize: CGFloat(settings.preferences.badgeSize),
                        dotSize: CGFloat(settings.preferences.dotSize),
                        grayOutWhenNoUnread: settings.preferences.grayOutWhenNoUnread
                    )
                )
                VStack(spacing: 4) {
                    HStack(spacing: 2) {
                        Image(nsImage: rendered.image)
                        if !rendered.title.isEmpty {
                            Text(rendered.title)
                                .font(.system(size: rendered.titleFontSize, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                    .frame(minHeight: 24)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var visibilitySection: some View {
        GroupBox("Visibility & Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Hide icon when monitored app isn't running", isOn: $settings.preferences.hideWhenAppNotRunning)
                Toggle("Hide icon when there are no unread notifications", isOn: $settings.preferences.hideWhenNoUnread)
                Toggle("Gray out icon when there are no unread notifications", isOn: $settings.preferences.grayOutWhenNoUnread)
                Toggle("Always show Menubar Badges control icon in menu bar", isOn: $settings.preferences.alwaysShowControlIcon)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var behaviorSection: some View {
        GroupBox("Behavior & Alerts") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        coordinator.setLaunchAtLogin(newValue)
                    }

                Toggle("Show floating alert when a new badge arrives in full-screen mode", isOn: $settings.preferences.showAlertInFullScreen)
                Text("Uses a non-activating borderless panel that never steals keyboard focus or defocuses your active window on macOS 27.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)

                Toggle("Click an active app's menu bar icon to hide it", isOn: $settings.preferences.hideFrontmostAppOnClick)

                HStack {
                    Text("Check interval:")
                    Slider(value: $settings.preferences.pollIntervalSeconds, in: 0.5...3.0, step: 0.5)
                        .frame(width: 160)
                    Text(String(format: "%.1fs", settings.preferences.pollIntervalSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Text("Tip: Option-click (⌥ + click) or right-click any monitored icon in the menu bar to open Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var footerSection: some View {
        HStack {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.1"
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let url = URL(string: "https://github.com/gempir/menubar-badges") {
                Link("GitHub Repository", destination: url)
                    .font(.caption)
            }
        }
    }
}
