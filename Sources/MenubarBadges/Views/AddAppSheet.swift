import AppKit
import MenubarBadgesCore
import SwiftUI
import UniformTypeIdentifiers

struct AddAppSheet: View {
    @ObservedObject var coordinator: MenubarCoordinator
    @ObservedObject var installedApps: InstalledAppsService
    @Binding var isPresented: Bool

    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool

    private var monitoredBundleIds: Set<String> {
        Set(coordinator.settings.monitoredApps.map { $0.bundleId.lowercased() })
    }

    private var dockDiscoveredApps: [DiscoveredApp] {
        var seen = Set<String>()
        var result: [DiscoveredApp] = []
        for item in coordinator.monitor.dockItems {
            guard let bundleId = item.bundleId,
                  let path = item.bundlePath,
                  !seen.contains(bundleId.lowercased()) else {
                continue
            }
            seen.insert(bundleId.lowercased())
            let name = item.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            result.append(DiscoveredApp(bundleId: bundleId, appName: name, bundlePath: path))
        }
        return filterApps(result)
    }

    private var filteredAllApps: [DiscoveredApp] {
        filterApps(installedApps.apps)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search applications…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isSearchFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button("Choose App…") {
                    pickAppFromFinder()
                }
            }
            .padding(14)

            Divider()

            List {
                if !dockDiscoveredApps.isEmpty {
                    Section("Currently in Your Dock") {
                        ForEach(dockDiscoveredApps) { app in
                            appRow(app)
                        }
                    }
                }

                Section("Installed Applications (\(filteredAllApps.count))") {
                    ForEach(filteredAllApps) { app in
                        appRow(app)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text("Select any application to mirror its Dock unread badge in your menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            installedApps.loadIfNeeded()
            isSearchFocused = true
        }
    }

    private func appRow(_ app: DiscoveredApp) -> some View {
        let alreadyAdded = monitoredBundleIds.contains(app.bundleId.lowercased())
        let icon = NSWorkspace.shared.icon(forFile: app.bundlePath)

        return HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.appName)
                    .font(.body)
                Text(app.bundleId)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if alreadyAdded {
                Label("Monitored", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Add") {
                    coordinator.addMonitoredApp(
                        MonitoredApp(
                            bundleId: app.bundleId,
                            appName: app.appName,
                            bundlePath: app.bundlePath
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !alreadyAdded {
                coordinator.addMonitoredApp(
                    MonitoredApp(
                        bundleId: app.bundleId,
                        appName: app.appName,
                        bundlePath: app.bundlePath
                    )
                )
            }
        }
    }

    private func filterApps(_ source: [DiscoveredApp]) -> [DiscoveredApp] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return source }
        return source.filter {
            $0.appName.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleId.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func pickAppFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK, let appURL = panel.url {
            guard let bundle = Bundle(url: appURL),
                  let bundleId = bundle.bundleIdentifier else {
                return
            }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? appURL.deletingPathExtension().lastPathComponent

            coordinator.addMonitoredApp(
                MonitoredApp(
                    bundleId: bundleId,
                    appName: name,
                    bundlePath: appURL.path
                )
            )
            isPresented = false
        }
    }
}
