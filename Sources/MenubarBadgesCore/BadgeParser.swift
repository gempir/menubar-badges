import Foundation

/// Parses raw macOS Dock `AXStatusLabel` strings into structured `BadgeValue`s.
public enum BadgeParser {
    private static let dotMarkers: Set<String> = [
        "•", "●", "·", "∙", "◦", "○", "*", "●", "🔴", "🔵"
    ]

    public static func parse(_ rawStatusLabel: String?) -> BadgeValue {
        guard let raw = rawStatusLabel else {
            return .none
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .none
        }

        if dotMarkers.contains(trimmed) {
            return .dot
        }

        // Handle plain integer counts (including localized/comma-separated like "1,234")
        let normalizedNumber = trimmed.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let intValue = Int(normalizedNumber) {
            if intValue <= 0 {
                return .none
            }
            return .count(intValue, raw: trimmed)
        }

        return .text(trimmed)
    }

    /// Returns true if transitioning from `previous` to `current` represents a new or increased notification.
    public static func shouldTriggerAlert(from previous: BadgeValue, to current: BadgeValue) -> Bool {
        guard current.hasUnread, previous != current else {
            return false
        }

        // Transitioning from no unread to any unread always alerts.
        if !previous.hasUnread {
            return true
        }

        // If both have numeric values, only alert when the count increases.
        if let prevNum = previous.numericValue, let currNum = current.numericValue {
            return currNum > prevNum
        }

        // E.g. dot -> count or text change.
        return true
    }
}
