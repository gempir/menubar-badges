import AppKit
import Combine
import Foundation

/// Persists monitored applications, global preferences, and optional custom app icons.
@MainActor
public final class SettingsStore: ObservableObject {
    private enum Keys {
        static let monitoredApps = "MenubarBadges.monitoredApps.v1"
        static let preferences = "MenubarBadges.preferences.v1"
    }

    @Published public var monitoredApps: [MonitoredApp] {
        didSet { saveMonitoredApps() }
    }

    @Published public var preferences: AppPreferences {
        didSet { savePreferences() }
    }

    /// Incremented whenever a custom icon is changed or reset, forcing status items to re-render.
    @Published public private(set) var iconRevision: Int = 0

    private let defaults: UserDefaults
    private let customIconsDirectory: URL

    public init(
        defaults: UserDefaults = .standard,
        customIconsDirectory: URL? = nil
    ) {
        self.defaults = defaults

        if let dir = customIconsDirectory {
            self.customIconsDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.customIconsDirectory = appSupport
                .appendingPathComponent("com.gempir.menubar-badges", isDirectory: true)
                .appendingPathComponent("custom-icons", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: self.customIconsDirectory, withIntermediateDirectories: true)

        if let data = defaults.data(forKey: Keys.monitoredApps),
           let decoded = try? JSONDecoder().decode([MonitoredApp].self, from: data) {
            self.monitoredApps = decoded
        } else {
            self.monitoredApps = []
        }

        if let data = defaults.data(forKey: Keys.preferences),
           let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = AppPreferences()
        }
    }

    // MARK: - Monitored Apps CRUD

    @discardableResult
    public func addApp(_ app: MonitoredApp) -> Bool {
        guard !monitoredApps.contains(where: { $0.bundleId.caseInsensitiveCompare(app.bundleId) == .orderedSame }) else {
            return false
        }
        monitoredApps.append(app)
        return true
    }

    public func removeApp(bundleId: String) {
        monitoredApps.removeAll { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame }
    }

    public func updateApp(_ updated: MonitoredApp) {
        guard let index = monitoredApps.firstIndex(where: { $0.bundleId == updated.bundleId }) else {
            return
        }
        monitoredApps[index] = updated
    }

    public func moveApps(from source: IndexSet, to destination: Int) {
        var copy = monitoredApps
        let moving = source.map { copy[$0] }
        for index in source.sorted(by: >) {
            copy.remove(at: index)
        }
        let adjustedDest = destination - source.filter { $0 < destination }.count
        copy.insert(contentsOf: moving, at: max(0, min(adjustedDest, copy.count)))
        monitoredApps = copy
    }

    // MARK: - App Icons

    public func icon(for app: MonitoredApp) -> NSImage {
        let customURL = customIconURL(for: app.bundleId)
        if let customImage = NSImage(contentsOf: customURL) {
            return customImage
        }
        if let path = app.bundlePath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return BadgeIconRenderer.controlStatusIcon()
    }

    public func hasCustomIcon(for bundleId: String) -> Bool {
        FileManager.default.fileExists(atPath: customIconURL(for: bundleId).path)
    }

    @discardableResult
    public func setCustomIcon(_ image: NSImage, for bundleId: String) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: customIconsDirectory, withIntermediateDirectories: true)
            try png.write(to: customIconURL(for: bundleId), options: .atomic)
            iconRevision += 1
            return true
        } catch {
            return false
        }
    }

    public func removeCustomIcon(for bundleId: String) {
        try? FileManager.default.removeItem(at: customIconURL(for: bundleId))
        iconRevision += 1
    }

    private func customIconURL(for bundleId: String) -> URL {
        let safeName = bundleId.replacingOccurrences(of: "/", with: "_")
        return customIconsDirectory.appendingPathComponent("\(safeName).png")
    }

    // MARK: - Persistence

    private func saveMonitoredApps() {
        if let data = try? JSONEncoder().encode(monitoredApps) {
            defaults.set(data, forKey: Keys.monitoredApps)
        }
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Keys.preferences)
        }
    }
}
