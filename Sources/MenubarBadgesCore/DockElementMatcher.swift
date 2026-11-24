import Foundation

/// Pure matching logic between a `MonitoredApp` and `DockItemSnapshot`s.
/// Prefers bundle identifier matching (via Dock item's `AXURL`), then path/app filename,
/// and finally localized display title, avoiding Doll's fragile title-only lookup.
public enum DockElementMatcher {
    public static func findMatch(
        for app: MonitoredApp,
        in items: [DockItemSnapshot]
    ) -> DockItemSnapshot? {
        let targetBundleId = app.bundleId.lowercased()
        let targetName = app.appName.lowercased()
        let targetAppFileName = app.bundlePath
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() }

        // 1. Exact bundle identifier match (most reliable — handles localized & renamed apps).
        if let match = items.first(where: { $0.bundleId?.lowercased() == targetBundleId }) {
            return match
        }

        // 2. Bundle path match.
        if let targetPath = app.bundlePath?.lowercased(), !targetPath.isEmpty {
            let normalizedTarget = normalizePath(targetPath)
            if let match = items.first(where: { item in
                guard let itemPath = item.bundlePath else { return false }
                return normalizePath(itemPath.lowercased()) == normalizedTarget
            }) {
                return match
            }
        }

        // 3. Exact case-insensitive title match.
        if let match = items.first(where: { $0.title?.lowercased() == targetName }) {
            return match
        }

        // 4. App bundle filename vs Dock title (e.g. "Microsoft Outlook.app" vs "Outlook").
        if let fileName = targetAppFileName, !fileName.isEmpty {
            if let match = items.first(where: { $0.title?.lowercased() == fileName }) {
                return match
            }
            if let match = items.first(where: { item in
                guard let path = item.bundlePath else { return false }
                let itemFileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
                return itemFileName == fileName
            }) {
                return match
            }
        }

        return nil
    }

    private static func normalizePath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
