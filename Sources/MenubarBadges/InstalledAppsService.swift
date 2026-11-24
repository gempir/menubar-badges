import AppKit
import Foundation

struct DiscoveredApp: Identifiable, Hashable, Sendable {
    var id: String { bundleId }
    let bundleId: String
    let appName: String
    let bundlePath: String
}

/// Discovers installed macOS applications rapidly from standard application directories,
/// running apps, and a background Spotlight `NSMetadataQuery`.
@MainActor
final class InstalledAppsService: ObservableObject {
    @Published private(set) var apps: [DiscoveredApp] = []

    private var metadataQuery: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var hasLoaded = false

    func stop() {
        metadataQuery?.stop()
        metadataQuery = nil
        if let observer = queryObserver {
            NotificationCenter.default.removeObserver(observer)
            queryObserver = nil
        }
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        refreshNow()
    }

    func refreshNow() {
        var found: [String: DiscoveredApp] = [:]

        // 1. Standard application directories (instant, no Spotlight dependency).
        let searchDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
        for dir in searchDirs {
            scanDirectory(dir, maxDepth: 2, into: &found)
        }

        // 2. Currently running GUI applications.
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let bundleId = running.bundleIdentifier,
                  let url = running.bundleURL else { continue }
            if found[bundleId] == nil {
                let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
                found[bundleId] = DiscoveredApp(bundleId: bundleId, appName: name, bundlePath: url.path)
            }
        }

        publish(found)
        startSpotlightQuery(existing: found)
    }

    private func scanDirectory(_ path: String, maxDepth: Int, into found: inout [String: DiscoveredApp]) {
        guard maxDepth > 0 else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }

        for entry in entries {
            if entry.hasPrefix(".") { continue }
            let fullPath = (path as NSString).appendingPathComponent(entry)
            if entry.hasSuffix(".app") {
                if let app = loadAppMetadata(atPath: fullPath) {
                    found[app.bundleId] = app
                }
            } else {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    scanDirectory(fullPath, maxDepth: maxDepth - 1, into: &found)
                }
            }
        }
    }

    private func loadAppMetadata(atPath path: String) -> DiscoveredApp? {
        guard let bundle = Bundle(path: path),
              let bundleId = bundle.bundleIdentifier,
              !bundleId.isEmpty else {
            return nil
        }
        let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return DiscoveredApp(bundleId: bundleId, appName: name, bundlePath: path)
    }

    private func startSpotlightQuery(existing: [String: DiscoveredApp]) {
        metadataQuery?.stop()
        if let observer = queryObserver {
            NotificationCenter.default.removeObserver(observer)
            queryObserver = nil
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]

        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let activeQuery = self.metadataQuery else { return }
                var merged = existing
                for case let item as NSMetadataItem in activeQuery.results {
                    guard let bundleId = item.value(forAttribute: kMDItemCFBundleIdentifier as String) as? String,
                          let path = item.value(forAttribute: kMDItemPath as String) as? String,
                          !bundleId.isEmpty,
                          !path.contains("/Trash/"),
                          !path.contains("/Xcode.app/Contents/") else {
                        continue
                    }
                    if merged[bundleId] == nil {
                        let rawName = (item.value(forAttribute: kMDItemDisplayName as String) as? String)
                            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                        let cleanName = rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
                        merged[bundleId] = DiscoveredApp(bundleId: bundleId, appName: cleanName, bundlePath: path)
                    }
                }
                activeQuery.stop()
                self.publish(merged)
            }
        }

        metadataQuery = query
        query.start()
    }

    private func publish(_ dict: [String: DiscoveredApp]) {
        let ownBundleId = Bundle.main.bundleIdentifier
        apps = dict.values
            .filter { $0.bundleId != ownBundleId }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }
}
