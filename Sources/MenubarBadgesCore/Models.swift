import Foundation

/// How an unread badge is rendered in the macOS menu bar.
public enum BadgeDisplayStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// App icon with a macOS Dock-style red pill/circle badge (or red dot) overlaid in the top-right corner.
    case redBadge
    /// App icon with unread count or dot shown right beside it (e.g. `(1)` or `1` or `•`).
    case iconAndCount
    /// App icon with a clean red dot whenever any unread indicator is present.
    case simpleDot
    /// App icon only (no count or dot drawn; pairs well with hide/gray-out when idle).
    case iconOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .redBadge: return "Red Badge on Icon"
        case .iconAndCount: return "Icon + Count"
        case .simpleDot: return "Simple Dot"
        case .iconOnly: return "Icon Only"
        }
    }

    public var subtitle: String {
        switch self {
        case .redBadge: return "Dock-style red badge pill or red dot overlaid on the app icon."
        case .iconAndCount: return "App icon followed by the unread count (e.g. (1) or 1) or dot."
        case .simpleDot: return "App icon with a subtle unread dot whenever a badge is present."
        case .iconOnly: return "Show only the app icon without a badge label."
        }
    }
}

/// Format for count text when using `BadgeDisplayStyle.iconAndCount`.
public enum CountTextFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Shows `(1)`, `(12)`, `(99+)`
    case parenthesized
    /// Shows `1`, `12`, `99+`
    case plain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .parenthesized: return "Parentheses (1)"
        case .plain: return "Plain 1"
        }
    }
}

/// Parsed representation of a macOS Dock `AXStatusLabel` value.
public enum BadgeValue: Equatable, Hashable, Sendable {
    /// No unread badge.
    case none
    /// Unread dot/bullet indicator (e.g., `"•"`, `"●"`, `"·"`).
    case dot
    /// Numeric unread count (e.g., `1`, `42`).
    case count(Int, raw: String)
    /// Non-numeric short badge label (e.g., `"99+"`, `"!"`, `"New"`).
    case text(String)

    public var hasUnread: Bool {
        switch self {
        case .none: return false
        case .dot, .count, .text: return true
        }
    }

    /// Raw display string (e.g. `"1"`, `"99+"`, `"•"`, or `""` for `.none`).
    public var rawLabel: String {
        switch self {
        case .none: return ""
        case .dot: return "•"
        case .count(_, let raw): return raw
        case .text(let value): return value
        }
    }

    /// Numeric magnitude when available, used to detect increasing badge counts.
    public var numericValue: Int? {
        switch self {
        case .count(let n, _): return n
        case .text(let s):
            let digits = s.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        case .dot, .none:
            return nil
        }
    }

    /// Compact text suitable for drawing inside a small red badge pill on a menu bar icon.
    public var compactOverlayLabel: String? {
        switch self {
        case .none, .dot:
            return nil
        case .count(let n, _):
            if n > 99 { return "99+" }
            return "\(n)"
        case .text(let s):
            if s.count <= 3 { return s }
            return String(s.prefix(2)) + "+"
        }
    }

    /// Formatted text for the `iconAndCount` display style.
    public func formattedInlineLabel(format: CountTextFormat) -> String {
        switch self {
        case .none:
            return ""
        case .dot:
            return "•"
        case .count(_, let raw):
            return format == .parenthesized ? "(\(raw))" : raw
        case .text(let value):
            return format == .parenthesized ? "(\(value))" : value
        }
    }
}

/// A monitored application configuration.
public struct MonitoredApp: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { bundleId }
    public var bundleId: String
    public var appName: String
    public var bundlePath: String?
    public var invertIconInDarkMode: Bool
    public var monochromeIcon: Bool
    public var showAttentionArrow: Bool

    public init(
        bundleId: String,
        appName: String,
        bundlePath: String? = nil,
        invertIconInDarkMode: Bool = false,
        monochromeIcon: Bool = false,
        showAttentionArrow: Bool = false
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.bundlePath = bundlePath
        self.invertIconInDarkMode = invertIconInDarkMode
        self.monochromeIcon = monochromeIcon
        self.showAttentionArrow = showAttentionArrow
    }
}

/// Snapshot of a single Dock item read from Accessibility (pure data for testing).
public struct DockItemSnapshot: Equatable, Hashable, Sendable {
    public var title: String?
    public var bundleId: String?
    public var bundlePath: String?
    public var statusLabel: String?
    public var isRunning: Bool

    public init(
        title: String? = nil,
        bundleId: String? = nil,
        bundlePath: String? = nil,
        statusLabel: String? = nil,
        isRunning: Bool = false
    ) {
        self.title = title
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        self.statusLabel = statusLabel
        self.isRunning = isRunning
    }
}

/// Live badge & running status for a monitored app.
public struct MonitoredAppStatus: Equatable, Sendable {
    public var badge: BadgeValue
    public var isRunning: Bool

    public init(badge: BadgeValue = .none, isRunning: Bool = false) {
        self.badge = badge
        self.isRunning = isRunning
    }
}

/// Persisted global user preferences.
public struct AppPreferences: Codable, Equatable, Sendable {
    public static let defaultIconSize: Double = 18.0
    public static let iconSizeRange: ClosedRange<Double> = 12.0...22.0

    public static let defaultBadgeSize: Double = 11.0
    public static let badgeSizeRange: ClosedRange<Double> = 7.0...15.0

    public static let defaultDotSize: Double = 8.0
    public static let dotSizeRange: ClosedRange<Double> = 4.0...12.0

    public var displayStyle: BadgeDisplayStyle = .redBadge
    public var countTextFormat: CountTextFormat = .parenthesized
    public var iconSize: Double = AppPreferences.defaultIconSize
    public var badgeSize: Double = AppPreferences.defaultBadgeSize
    public var dotSize: Double = AppPreferences.defaultDotSize
    public var hideWhenAppNotRunning: Bool = false
    public var hideWhenNoUnread: Bool = false
    public var grayOutWhenNoUnread: Bool = false
    public var showAlertInFullScreen: Bool = true
    public var hideFrontmostAppOnClick: Bool = true
    public var alwaysShowControlIcon: Bool = false
    public var automaticallyCheckForUpdates: Bool = true
    public var pollIntervalSeconds: Double = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayStyle = try container.decodeIfPresent(BadgeDisplayStyle.self, forKey: .displayStyle) ?? .redBadge
        countTextFormat = try container.decodeIfPresent(CountTextFormat.self, forKey: .countTextFormat) ?? .parenthesized
        iconSize = try container.decodeIfPresent(Double.self, forKey: .iconSize) ?? Self.defaultIconSize
        badgeSize = try container.decodeIfPresent(Double.self, forKey: .badgeSize) ?? Self.defaultBadgeSize
        dotSize = try container.decodeIfPresent(Double.self, forKey: .dotSize) ?? Self.defaultDotSize
        hideWhenAppNotRunning = try container.decodeIfPresent(Bool.self, forKey: .hideWhenAppNotRunning) ?? false
        hideWhenNoUnread = try container.decodeIfPresent(Bool.self, forKey: .hideWhenNoUnread) ?? false
        grayOutWhenNoUnread = try container.decodeIfPresent(Bool.self, forKey: .grayOutWhenNoUnread) ?? false
        showAlertInFullScreen = try container.decodeIfPresent(Bool.self, forKey: .showAlertInFullScreen) ?? true
        hideFrontmostAppOnClick = try container.decodeIfPresent(Bool.self, forKey: .hideFrontmostAppOnClick) ?? true
        alwaysShowControlIcon = try container.decodeIfPresent(Bool.self, forKey: .alwaysShowControlIcon) ?? false
        automaticallyCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .automaticallyCheckForUpdates) ?? true
        pollIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 1.0
    }
}
