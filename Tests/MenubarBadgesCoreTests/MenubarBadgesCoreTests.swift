import AppKit
import XCTest
@testable import MenubarBadgesCore

final class MenubarBadgesCoreTests: XCTestCase {
    // MARK: - BadgeParser Tests

    func testBadgeParserHandlesEmptyAndZero() {
        XCTAssertEqual(BadgeParser.parse(nil), .none)
        XCTAssertEqual(BadgeParser.parse(""), .none)
        XCTAssertEqual(BadgeParser.parse("   "), .none)
        XCTAssertEqual(BadgeParser.parse("0"), .none)
        XCTAssertFalse(BadgeParser.parse(nil).hasUnread)
    }

    func testBadgeParserHandlesCountsAndDotsAndText() {
        XCTAssertEqual(BadgeParser.parse("1"), .count(1, raw: "1"))
        XCTAssertEqual(BadgeParser.parse("42"), .count(42, raw: "42"))
        XCTAssertEqual(BadgeParser.parse("1,234"), .count(1234, raw: "1,234"))
        XCTAssertEqual(BadgeParser.parse("•"), .dot)
        XCTAssertEqual(BadgeParser.parse("●"), .dot)
        XCTAssertEqual(BadgeParser.parse("*"), .dot)
        XCTAssertEqual(BadgeParser.parse("99+"), .text("99+"))
        XCTAssertEqual(BadgeParser.parse("!"), .text("!"))
    }

    func testBadgeFormattingAndCompactOverlay() {
        let one = BadgeValue.count(1, raw: "1")
        XCTAssertEqual(one.formattedInlineLabel(format: .parenthesized), "(1)")
        XCTAssertEqual(one.formattedInlineLabel(format: .plain), "1")
        XCTAssertEqual(one.compactOverlayLabel, "1")

        let big = BadgeValue.count(150, raw: "150")
        XCTAssertEqual(big.compactOverlayLabel, "99+")

        let dot = BadgeValue.dot
        XCTAssertNil(dot.compactOverlayLabel)
        XCTAssertEqual(dot.formattedInlineLabel(format: .parenthesized), "•")
        XCTAssertTrue(dot.hasUnread)
    }

    func testAlertTriggerLogic() {
        XCTAssertTrue(BadgeParser.shouldTriggerAlert(from: .none, to: .count(1, raw: "1")))
        XCTAssertTrue(BadgeParser.shouldTriggerAlert(from: .none, to: .dot))
        XCTAssertTrue(BadgeParser.shouldTriggerAlert(from: .count(1, raw: "1"), to: .count(2, raw: "2")))
        XCTAssertFalse(BadgeParser.shouldTriggerAlert(from: .count(2, raw: "2"), to: .count(1, raw: "1")))
        XCTAssertFalse(BadgeParser.shouldTriggerAlert(from: .count(2, raw: "2"), to: .count(2, raw: "2")))
        XCTAssertFalse(BadgeParser.shouldTriggerAlert(from: .count(1, raw: "1"), to: .none))
    }

    // MARK: - DockElementMatcher Tests

    func testDockMatcherPrefersBundleIdOverTitle() {
        let app = MonitoredApp(
            bundleId: "com.microsoft.Outlook",
            appName: "Microsoft Outlook",
            bundlePath: "/Applications/Microsoft Outlook.app"
        )
        let items = [
            DockItemSnapshot(title: "Mail", bundleId: "com.apple.mail", bundlePath: "/System/Applications/Mail.app", statusLabel: "5", isRunning: true),
            // Dock title differs from CFBundleName, just like Outlook/Teams!
            DockItemSnapshot(title: "Outlook", bundleId: "com.microsoft.Outlook", bundlePath: "/Applications/Microsoft Outlook.app", statusLabel: "3", isRunning: true)
        ]

        let matched = DockElementMatcher.findMatch(for: app, in: items)
        XCTAssertEqual(matched?.statusLabel, "3")
        XCTAssertEqual(matched?.bundleId, "com.microsoft.Outlook")
    }

    func testDockMatcherFallsBackToTitleAndPath() {
        let app = MonitoredApp(
            bundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            bundlePath: "/Applications/Slack.app"
        )
        let items = [
            DockItemSnapshot(title: "Slack", bundleId: nil, bundlePath: nil, statusLabel: "•", isRunning: true)
        ]

        let matched = DockElementMatcher.findMatch(for: app, in: items)
        XCTAssertEqual(matched?.statusLabel, "•")
    }

    // MARK: - BadgeIconRenderer Tests

    func testRendererProducesValidImagesForAllStyles() {
        let baseIcon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            return true
        }

        let badges: [BadgeValue] = [.none, .dot, .count(1, raw: "1"), .count(42, raw: "42"), .count(120, raw: "120")]

        for style in BadgeDisplayStyle.allCases {
            for badge in badges {
                let result = BadgeIconRenderer.renderStatusItem(
                    baseIcon: baseIcon,
                    badge: badge,
                    options: .init(
                        style: style,
                        countFormat: .parenthesized,
                        grayOutWhenNoUnread: true,
                        invertInDarkMode: true,
                        monochrome: false,
                        isDarkAppearance: true
                    )
                )
                XCTAssertGreaterThan(result.image.size.width, 0)
                XCTAssertGreaterThan(result.image.size.height, 0)

                if style == .iconAndCount && badge == .count(1, raw: "1") {
                    XCTAssertEqual(result.title, " (1)")
                } else if style == .redBadge || style == .simpleDot || style == .iconOnly {
                    XCTAssertEqual(result.title, "")
                }
            }
        }

        // Verify double-digit red badge widens canvas slightly so it never clips.
        let singleDigit = BadgeIconRenderer.drawRedBadgeOverlay(on: baseIcon, badge: .count(1, raw: "1"))
        let tripleDigit = BadgeIconRenderer.drawRedBadgeOverlay(on: baseIcon, badge: .count(120, raw: "120"))
        XCTAssertGreaterThanOrEqual(tripleDigit.size.width, singleDigit.size.width)

        // Verify configurable iconSize and badgeSize affect rendered output dimensions.
        let compact = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .count(5, raw: "5"),
            options: .init(style: .redBadge, iconSize: 13, badgeSize: 8)
        )
        let large = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .count(5, raw: "5"),
            options: .init(style: .redBadge, iconSize: 21, badgeSize: 14)
        )
        XCTAssertGreaterThan(large.image.size.width, compact.image.size.width)
        XCTAssertGreaterThan(large.image.size.height, compact.image.size.height)

        let smallCount = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .count(1, raw: "1"),
            options: .init(style: .iconAndCount, iconSize: 14, badgeSize: 8)
        )
        let largeCount = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .count(1, raw: "1"),
            options: .init(style: .iconAndCount, iconSize: 20, badgeSize: 14)
        )
        XCTAssertGreaterThan(largeCount.titleFontSize, smallCount.titleFontSize)
        XCTAssertEqual(smallCount.image.size.width, 14)
        XCTAssertEqual(largeCount.image.size.width, 20)

        // Verify dotSize scales dot rendering independently from badgeSize.
        let smallDot = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .dot,
            options: .init(style: .redBadge, iconSize: 18, badgeSize: 14, dotSize: 4)
        )
        let largeDot = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .dot,
            options: .init(style: .redBadge, iconSize: 18, badgeSize: 8, dotSize: 12)
        )
        XCTAssertGreaterThan(largeDot.image.size.width, smallDot.image.size.width)

        let sideDotSmall = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .dot,
            options: .init(style: .iconAndCount, iconSize: 18, badgeSize: 14, dotSize: 4)
        )
        let sideDotLarge = BadgeIconRenderer.renderStatusItem(
            baseIcon: baseIcon,
            badge: .dot,
            options: .init(style: .iconAndCount, iconSize: 18, badgeSize: 8, dotSize: 12)
        )
        XCTAssertGreaterThan(sideDotLarge.image.size.width, sideDotSmall.image.size.width)
    }

    // MARK: - SettingsStore Persistence Tests

    @MainActor
    func testSettingsStorePersistenceAndDeduplication() {
        let suiteName = "com.gempir.menubar-badges.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let tempIcons = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempIcons)
        }

        let store = SettingsStore(defaults: defaults, customIconsDirectory: tempIcons)
        let mail = MonitoredApp(bundleId: "com.apple.mail", appName: "Mail")
        XCTAssertTrue(store.addApp(mail))
        XCTAssertFalse(store.addApp(mail)) // Duplicate rejected

        store.preferences.displayStyle = .simpleDot
        store.preferences.iconSize = 20
        store.preferences.badgeSize = 13
        store.preferences.dotSize = 10
        store.preferences.hideWhenNoUnread = true

        // Reload from same UserDefaults
        let reloaded = SettingsStore(defaults: defaults, customIconsDirectory: tempIcons)
        XCTAssertEqual(reloaded.monitoredApps.count, 1)
        XCTAssertEqual(reloaded.monitoredApps.first?.bundleId, "com.apple.mail")
        XCTAssertEqual(reloaded.preferences.displayStyle, .simpleDot)
        XCTAssertEqual(reloaded.preferences.iconSize, 20)
        XCTAssertEqual(reloaded.preferences.badgeSize, 13)
        XCTAssertEqual(reloaded.preferences.dotSize, 10)
        XCTAssertTrue(reloaded.preferences.hideWhenNoUnread)

        reloaded.removeApp(bundleId: "com.apple.mail")
        XCTAssertTrue(reloaded.monitoredApps.isEmpty)
    }

    func testPreferencesDecodesGracefullyWithoutSizeFields() throws {
        let legacyJSON = #"{"displayStyle":"iconAndCount","hideWhenNoUnread":true}"#
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.displayStyle, .iconAndCount)
        XCTAssertTrue(decoded.hideWhenNoUnread)
        XCTAssertEqual(decoded.iconSize, AppPreferences.defaultIconSize)
        XCTAssertEqual(decoded.badgeSize, AppPreferences.defaultBadgeSize)
        XCTAssertEqual(decoded.dotSize, AppPreferences.defaultDotSize)
        XCTAssertTrue(decoded.automaticallyCheckForUpdates)
    }

    // MARK: - Updater Version & GitHub Release Evaluation Tests

    func testAppVersionParsingAndComparison() {
        XCTAssertEqual(AppVersion(parsing: "v0.2.1"), AppVersion(major: 0, minor: 2, patch: 1))
        XCTAssertEqual(AppVersion(parsing: "0.2.1"), AppVersion(major: 0, minor: 2, patch: 1))
        XCTAssertEqual(AppVersion(parsing: "1.2"), AppVersion(major: 1, minor: 2, patch: 0))
        XCTAssertNil(AppVersion(parsing: ""))
        XCTAssertNil(AppVersion(parsing: "not-a-version"))

        XCTAssertLessThan(AppVersion(parsing: "0.2.1")!, AppVersion(parsing: "0.3.0")!)
        XCTAssertLessThan(AppVersion(parsing: "0.3.0-beta.1")!, AppVersion(parsing: "0.3.0")!)
        XCTAssertLessThan(AppVersion(parsing: "0.9.9")!, AppVersion(parsing: "1.0.0")!)
        XCTAssertFalse(AppVersion(parsing: "0.3.0")! < AppVersion(parsing: "v0.3.0")!)
    }

    func testGitHubUpdateEvaluatorDetectsUpgradeAndUpToDate() throws {
        let release = GitHubRelease(
            tagName: "v0.3.0",
            name: "0.3.0",
            body: "Added built-in GitHub updater.",
            htmlURL: URL(string: "https://github.com/gempir/menubar-badges/releases/tag/v0.3.0")!,
            assets: [
                GitHubRelease.Asset(
                    name: "MenubarBadges-0.3.0.dmg",
                    browserDownloadURL: URL(string: "https://github.com/gempir/menubar-badges/releases/download/v0.3.0/MenubarBadges-0.3.0.dmg")!,
                    size: 1_500_000,
                    digest: "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                )
            ]
        )

        let upgradeResult = try GitHubUpdateEvaluator.evaluate(
            release: release,
            currentVersion: AppVersion(major: 0, minor: 2, patch: 1)
        )
        guard case .updateAvailable(let availability) = upgradeResult else {
            return XCTFail("Expected .updateAvailable")
        }
        XCTAssertEqual(availability.currentVersion, AppVersion(major: 0, minor: 2, patch: 1))
        XCTAssertEqual(availability.latestVersion, AppVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(availability.dmgAssetName, "MenubarBadges-0.3.0.dmg")
        XCTAssertEqual(availability.expectedSHA256, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

        let upToDateResult = try GitHubUpdateEvaluator.evaluate(
            release: release,
            currentVersion: AppVersion(major: 0, minor: 3, patch: 0)
        )
        XCTAssertEqual(
            upToDateResult,
            .upToDate(current: AppVersion(major: 0, minor: 3, patch: 0), latest: AppVersion(major: 0, minor: 3, patch: 0))
        )
    }

    func testSHA256VerificationPassAndFail() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("sha-test-\(UUID().uuidString).bin")
        try Data("menubar-badges".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let hash = try GitHubUpdateEvaluator.sha256Hex(forFileAt: tempFile)
        XCTAssertEqual(hash.count, 64)
        XCTAssertNoThrow(try GitHubUpdateEvaluator.verifyFileSHA256(at: tempFile, expectedHex: hash))
        XCTAssertThrowsError(try GitHubUpdateEvaluator.verifyFileSHA256(at: tempFile, expectedHex: String(repeating: "0", count: 64)))
    }
}
