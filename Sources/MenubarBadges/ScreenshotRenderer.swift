import AppKit
import MenubarBadgesCore
import SwiftUI

/// Renders crisp 2x Retina screenshots of the real SwiftUI views and menu bar styles
/// for documentation without capturing personal desktop windows or data.
@MainActor
enum ScreenshotRenderer {
    static func renderAll(to outputDirectory: String) {
        let outURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        let suiteName = "com.gempir.menubar-badges.screenshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let monitor = DockBadgeMonitor()
        monitor.syntheticAccessibilityOverride = true

        let demoApps: [(MonitoredApp, MonitoredAppStatus)] = [
            (
                MonitoredApp(bundleId: "com.apple.mail", appName: "Mail", bundlePath: "/System/Applications/Mail.app"),
                MonitoredAppStatus(badge: .count(3, raw: "3"), isRunning: true)
            ),
            (
                MonitoredApp(bundleId: "com.apple.MobileSMS", appName: "Messages", bundlePath: "/System/Applications/Messages.app"),
                MonitoredAppStatus(badge: .count(1, raw: "1"), isRunning: true)
            ),
            (
                MonitoredApp(bundleId: "com.apple.iCal", appName: "Calendar", bundlePath: "/System/Applications/Calendar.app"),
                MonitoredAppStatus(badge: .dot, isRunning: true)
            ),
            (
                MonitoredApp(bundleId: "com.apple.reminders", appName: "Reminders", bundlePath: "/System/Applications/Reminders.app"),
                MonitoredAppStatus(badge: .none, isRunning: true)
            )
        ]

        for (app, status) in demoApps {
            store.addApp(app)
            monitor.syntheticOverrides[app.bundleId] = status
        }

        let coordinator = MenubarCoordinator(settings: store, monitor: monitor)
        monitor.updateMonitoredApps(store.monitoredApps)

        // 1. General Settings screenshot (Dark appearance)
        coordinator.selectedBundleId = nil
        renderWindowScreenshot(
            view: SettingsView(coordinator: coordinator),
            title: "Menubar Badges",
            size: NSSize(width: 860, height: 790),
            appearance: NSAppearance(named: .darkAqua),
            to: outURL.appendingPathComponent("settings-general.png")
        )

        // 2. Per-App Detail screenshot (Mail selected)
        coordinator.selectedBundleId = "com.apple.mail"
        renderWindowScreenshot(
            view: SettingsView(coordinator: coordinator),
            title: "Menubar Badges",
            size: NSSize(width: 860, height: 590),
            appearance: NSAppearance(named: .darkAqua),
            to: outURL.appendingPathComponent("settings-app-detail.png")
        )

        // 3. Menu Bar Styles Showcase (real BadgeIconRenderer output in a macOS menu bar strip)
        let showcaseView = MenubarStylesShowcaseView(apps: demoApps, store: store)
        renderViewScreenshot(
            view: showcaseView,
            size: NSSize(width: 760, height: 248),
            appearance: NSAppearance(named: .darkAqua),
            to: outURL.appendingPathComponent("menubar-styles.png")
        )

        coordinator.tearDown()
        print("Rendered screenshots to \(outURL.path)")
    }

    private static func renderWindowScreenshot<V: View>(
        view: V,
        title: String,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL
    ) {
        let wrapped = VStack(spacing: 0) {
            // Window titlebar chrome
            ZStack {
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 14)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 30)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            view
        }
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                    Color(red: 0.05, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )

        renderViewScreenshot(
            view: wrapped,
            size: NSSize(width: size.width + 32, height: size.height + 32),
            appearance: appearance,
            to: url
        )
    }

    private static func renderViewScreenshot<V: View>(
        view: V,
        size: NSSize,
        appearance: NSAppearance?,
        to url: URL
    ) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = appearance

        // Attach to an offscreen window so SwiftUI layout, NavigationSplitView, and animations settle properly.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = hostingView
        window.orderBack(nil)

        // Pump the run loop briefly so NavigationSplitView and SwiftUI bindings finish laying out.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        hostingView.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2.0
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            window.orderOut(nil)
            return
        }
        rep.size = size

        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        window.orderOut(nil)

        if let pngData = rep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url, options: .atomic)
        }
    }
}

private struct MenubarStylesShowcaseView: View {
    let apps: [(MonitoredApp, MonitoredAppStatus)]
    let store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Menu Bar Badge Styles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            styleRow(
                label: "Red Badge on Icon",
                style: .redBadge,
                iconSize: 18,
                badgeSize: 11
            )
            styleRow(
                label: "Icon + Count  (1)",
                style: .iconAndCount,
                iconSize: 18,
                badgeSize: 11
            )
            styleRow(
                label: "Simple Dot",
                style: .simpleDot,
                iconSize: 18,
                badgeSize: 11
            )
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.12, blue: 0.20),
                    Color(red: 0.05, green: 0.07, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func styleRow(
        label: String,
        style: BadgeDisplayStyle,
        iconSize: CGFloat,
        badgeSize: CGFloat
    ) -> some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 150, alignment: .leading)

            // Simulated macOS dark menu bar strip
            HStack(spacing: 14) {
                Spacer()

                ForEach(apps, id: \.0.bundleId) { app, status in
                    let rendered = BadgeIconRenderer.renderStatusItem(
                        baseIcon: store.icon(for: app),
                        badge: status.badge,
                        options: .init(
                            style: style,
                            countFormat: .parenthesized,
                            iconSize: iconSize,
                            badgeSize: badgeSize,
                            grayOutWhenNoUnread: true,
                            isDarkAppearance: true
                        )
                    )
                    HStack(spacing: 2) {
                        Image(nsImage: rendered.image)
                        if !rendered.title.isEmpty {
                            Text(rendered.title)
                                .font(.system(size: rendered.titleFontSize, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                    }
                }

                Divider()
                    .frame(height: 14)
                    .overlay(Color.white.opacity(0.22))

                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                    Text("Tue 10:27")
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
        }
    }
}
