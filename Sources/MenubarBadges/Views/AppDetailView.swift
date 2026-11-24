import AppKit
import MenubarBadgesCore
import SwiftUI
import UniformTypeIdentifiers

struct AppDetailView: View {
    @ObservedObject var coordinator: MenubarCoordinator
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: DockBadgeMonitor

    let app: MonitoredApp
    let onRemoved: () -> Void

    init(coordinator: MenubarCoordinator, app: MonitoredApp, onRemoved: @escaping () -> Void) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        self.monitor = coordinator.monitor
        self.app = app
        self.onRemoved = onRemoved
    }

    private var currentApp: MonitoredApp {
        settings.monitoredApps.first(where: { $0.bundleId == app.bundleId }) ?? app
    }

    var body: some View {
        let status = monitor.statusesByBundleId[currentApp.bundleId] ?? MonitoredAppStatus()
        let baseIcon = settings.icon(for: currentApp)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 14) {
                    Image(nsImage: baseIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentApp.appName)
                            .font(.title2.bold())
                        Text(currentApp.bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Label(status.isRunning ? "Running" : "Not running", systemImage: status.isRunning ? "circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(status.isRunning ? .green : .secondary)
                            if status.badge.hasUnread {
                                Text("Current badge: \(status.badge.rawLabel)")
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                            } else {
                                Text("No unread badge")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button("Open App") {
                        monitor.activateOrToggleApp(currentApp, hideIfFrontmost: false)
                    }
                }

                // Live Preview
                GroupBox("Menu Bar Preview") {
                    let samples: [(String, BadgeValue)] = [
                        ("Unread (1)", .count(1, raw: "1")),
                        ("Unread (42)", .count(42, raw: "42")),
                        ("Dot", .dot),
                        ("No unread", .none)
                    ]

                    HStack(spacing: 16) {
                        ForEach(samples, id: \.0) { label, badge in
                            let rendered = BadgeIconRenderer.renderStatusItem(
                                baseIcon: baseIcon,
                                badge: badge,
                                options: .init(
                                    style: settings.preferences.displayStyle,
                                    countFormat: settings.preferences.countTextFormat,
                                    iconSize: CGFloat(settings.preferences.iconSize),
                                    badgeSize: CGFloat(settings.preferences.badgeSize),
                                    dotSize: CGFloat(settings.preferences.dotSize),
                                    grayOutWhenNoUnread: settings.preferences.grayOutWhenNoUnread,
                                    invertInDarkMode: currentApp.invertIconInDarkMode,
                                    monochrome: currentApp.monochromeIcon,
                                    isDarkAppearance: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                }

                // Per-App Appearance & Notifications
                GroupBox("App Appearance & Alerts") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Invert icon colors in Dark Mode",
                            isOn: binding(\.invertIconInDarkMode)
                        )

                        Toggle(
                            "Use monochrome icon style",
                            isOn: binding(\.monochromeIcon)
                        )

                        Toggle(
                            "Show pulsing red attention arrow on new notifications",
                            isOn: binding(\.showAttentionArrow)
                        )

                        Divider()

                        HStack(spacing: 10) {
                            Button("Choose Custom Icon…") {
                                pickCustomIcon()
                            }

                            if settings.hasCustomIcon(for: currentApp.bundleId) {
                                Button("Reset to Default Icon") {
                                    settings.removeCustomIcon(for: currentApp.bundleId)
                                }
                            }

                            Spacer()

                            Button("Preview Alert Banner") {
                                coordinator.controller(for: currentApp.bundleId)?.showFloatingAlertPreview(
                                    icon: baseIcon,
                                    badge: .count(1, raw: "1"),
                                    countFormat: settings.preferences.countTextFormat
                                )
                            }
                            .help("Displays the non-activating full-screen alert banner without stealing focus")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                // Remove action
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        coordinator.removeMonitoredApp(bundleId: currentApp.bundleId)
                        onRemoved()
                    } label: {
                        Label("Stop Monitoring \(currentApp.appName)", systemImage: "trash")
                    }
                }
            }
            .padding(24)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MonitoredApp, T>) -> Binding<T> {
        Binding(
            get: { currentApp[keyPath: keyPath] },
            set: { newValue in
                var copy = currentApp
                copy[keyPath: keyPath] = newValue
                settings.updateApp(copy)
            }
        )
    }

    private func pickCustomIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .icns, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let image = NSImage(contentsOf: url) {
            settings.setCustomIcon(image, for: currentApp.bundleId)
        }
    }
}
