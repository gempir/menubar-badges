import AppKit
import Foundation
import MenubarBadgesCore

/// Checks GitHub Releases for newer builds, asks the user before upgrading (clearly showing
/// current -> target version), verifies the downloaded DMG, and replaces + relaunches the app.
///
/// Background checks are 100% passive and NEVER steal window focus or activate the app.
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case updateAvailable(UpdateAvailability)
        case downloading(UpdateAvailability)
        case installing(UpdateAvailability)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var availableUpdate: UpdateAvailability?
    @Published private(set) var lastCheckedAt: Date?

    let currentVersion: AppVersion
    private var periodicTimer: Timer?
    private var isAutoCheckEnabled = false
    private var hasScheduledInitialCheck = false
    private var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        case .idle, .upToDate, .updateAvailable, .failed:
            return false
        }
    }

    init(currentVersion: AppVersion? = nil) {
        if let currentVersion {
            self.currentVersion = currentVersion
        } else {
            let versionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0"
            self.currentVersion = AppVersion(parsing: versionString) ?? AppVersion(major: 0, minor: 3, patch: 0)
        }
    }

    /// Starts passive background checks (initial check after 8s, then every 24h) when enabled.
    func configureAutomaticChecks(enabled: Bool) {
        guard enabled != isAutoCheckEnabled else { return }
        isAutoCheckEnabled = enabled

        periodicTimer?.invalidate()
        periodicTimer = nil
        guard enabled else { return }

        if !hasScheduledInitialCheck {
            hasScheduledInitialCheck = true
            // Initial passive check shortly after launch (never shows alerts or steals focus).
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isAutoCheckEnabled else { return }
                    await self.checkForUpdates(userInitiated: false)
                }
            }
        }

        let timer = Timer(timeInterval: 60 * 60 * 24, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkForUpdates(userInitiated: false)
            }
        }
        timer.tolerance = 60 * 15
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    func stop() {
        isAutoCheckEnabled = false
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Checks the latest GitHub release.
    /// - Parameter userInitiated: When `true`, prompts the user with a confirmation dialog if an
    ///   upgrade is available (or informs them if already up to date). When `false`, updates state
    ///   silently without ever activating the app or stealing focus.
    func checkForUpdates(userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .checking

        do {
            let result = try await fetchLatestReleaseCheck()
            lastCheckedAt = Date()

            switch result {
            case .upToDate(_, let latest):
                availableUpdate = nil
                state = .upToDate(latest)
                if userInitiated {
                    presentUpToDateAlert(latestVersion: latest)
                }

            case .updateAvailable(let update):
                availableUpdate = update
                state = .updateAvailable(update)
                if userInitiated {
                    promptAndInstall(update: update)
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            if userInitiated {
                presentErrorAlert(title: "Update Check Failed", message: message)
            }
        }
    }

    /// Displays the explicit confirmation dialog showing "current -> target" version before upgrading.
    func promptAndInstall(update: UpdateAvailability) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Upgrade Menubar Badges from v\(update.currentVersion) to v\(update.latestVersion)?"

        var details = "A newer GitHub release is ready to install.\n\n"
        details += "Current version:  v\(update.currentVersion)\n"
        details += "New version:      v\(update.latestVersion)"
        if let size = update.formattedSize {
            details += " (\(size))"
        }
        if !update.releaseNotes.isEmpty {
            let trimmedNotes = summarizeReleaseNotes(update.releaseNotes)
            details += "\n\nWhat's new:\n\(trimmedNotes)"
        }
        alert.informativeText = details
        alert.addButton(withTitle: "Upgrade & Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await performDownloadAndInstall(update: update)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releasePageURL)
        default:
            break
        }
    }

    /// Fetches and evaluates the latest release directly from GitHub Releases API.
    func fetchLatestReleaseCheck() async throws -> UpdateCheckResult {
        var request = URLRequest(url: GitHubUpdateEvaluator.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenubarBadges/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.httpError(http.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return try GitHubUpdateEvaluator.evaluate(release: release, currentVersion: currentVersion)
    }

    // MARK: - Download, Verify, Stage, Replace & Relaunch

    private func performDownloadAndInstall(update: UpdateAvailability) async {
        guard !isBusy else { return }

        // Ensure we are running from an actual .app bundle before attempting self-replacement.
        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension.lowercased() == "app" else {
            let err = UpdateError.notRunningFromAppBundle
            state = .failed(err.localizedDescription)
            presentErrorAlert(
                title: "Cannot Auto-Replace Development Build",
                message: err.localizedDescription,
                openURLOnAction: update.releasePageURL,
                actionTitle: "Open Release Page"
            )
            return
        }

        let parentDir = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            let err = UpdateError.installDestinationNotWritable(currentAppURL.path)
            state = .failed(err.localizedDescription)
            presentErrorAlert(
                title: "Permission Required",
                message: err.localizedDescription,
                openURLOnAction: update.releasePageURL,
                actionTitle: "Open Release Page"
            )
            return
        }

        state = .downloading(update)
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenubarBadges-Update-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let localDMGURL = workDir.appendingPathComponent(update.dmgAssetName)

            var downloadRequest = URLRequest(url: update.dmgDownloadURL)
            downloadRequest.setValue("MenubarBadges/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (tempFileURL, response) = try await URLSession.shared.download(for: downloadRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UpdateError.httpError(http.statusCode)
            }
            try FileManager.default.moveItem(at: tempFileURL, to: localDMGURL)

            state = .installing(update)

            // Verify SHA-256 checksum if GitHub supplied one on the release asset.
            if let expectedSHA256 = update.expectedSHA256 {
                try GitHubUpdateEvaluator.verifyFileSHA256(at: localDMGURL, expectedHex: expectedSHA256)
            }

            // Stage the extracted .app bundle from the mounted DMG off the main thread.
            let stagedAppURL = try await Task.detached(priority: .userInitiated) {
                try Self.extractAndVerifyApp(fromDMG: localDMGURL, stagingParent: workDir)
            }.value

            // Spawn detached helper script that waits for us to quit, swaps the .app atomically,
            // clears quarantine, and relaunches the new version.
            try launchReplacementScript(
                stagedAppURL: stagedAppURL,
                targetAppURL: currentAppURL,
                cleanupDir: workDir
            )

            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            presentErrorAlert(
                title: "Update Failed",
                message: message,
                openURLOnAction: update.releasePageURL,
                actionTitle: "Open Release Page"
            )
        }
    }

    nonisolated static func extractAndVerifyApp(fromDMG dmgURL: URL, stagingParent: URL) throws -> URL {
        let mountPoint = try attachDMG(at: dmgURL)
        defer { detachDMG(at: mountPoint) }

        let expectedAppURL = mountPoint.appendingPathComponent("MenubarBadges.app")
        let appInDMG: URL
        if FileManager.default.fileExists(atPath: expectedAppURL.path) {
            appInDMG = expectedAppURL
        } else if let found = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension.lowercased() == "app" }) {
            appInDMG = found
        } else {
            throw UpdateError.appBundleNotFoundInDMG
        }

        // Verify bundle identifier matches our app.
        let bundleId = Bundle(url: appInDMG)?.bundleIdentifier
        guard bundleId == "com.gempir.menubar-badges" else {
            throw UpdateError.invalidBundleIdentifier(bundleId)
        }

        // Verify code signature integrity.
        let verifyResult = runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appInDMG.path])
        if verifyResult.exitCode != 0 {
            throw UpdateError.codeSignatureInvalid(verifyResult.stderr.isEmpty ? "exit \(verifyResult.exitCode)" : verifyResult.stderr)
        }

        // Copy out of the read-only DMG into staging directory before unmounting.
        let stagedAppURL = stagingParent.appendingPathComponent("MenubarBadges.app")
        try FileManager.default.copyItem(at: appInDMG, to: stagedAppURL)
        return stagedAppURL
    }

    nonisolated private static func attachDMG(at dmgURL: URL) throws -> URL {
        let result = runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard result.exitCode == 0 else {
            throw UpdateError.mountFailed(result.stderr.isEmpty ? "hdiutil exited \(result.exitCode)" : result.stderr)
        }

        guard let plistData = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.mountFailed("Unable to parse mount point from hdiutil output.")
        }

        for entity in entities {
            if let mountPath = entity["mount-point"] as? String, !mountPath.isEmpty {
                return URL(fileURLWithPath: mountPath, isDirectory: true)
            }
        }
        throw UpdateError.mountFailed("No mount point returned by hdiutil.")
    }

    nonisolated private static func detachDMG(at mountPoint: URL) {
        _ = runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
    }

    nonisolated private static func runProcess(_ executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func launchReplacementScript(
        stagedAppURL: URL,
        targetAppURL: URL,
        cleanupDir: URL
    ) throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let backupURL = targetAppURL.deletingLastPathComponent()
            .appendingPathComponent(".\(targetAppURL.lastPathComponent).backup-\(UUID().uuidString)")

        let script = """
        #!/bin/sh
        PID="$1"
        STAGED="$2"
        TARGET="$3"
        BACKUP="$4"
        CLEANUP="$5"

        # Wait up to 10 seconds for the old app process to exit cleanly.
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 100 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        # Atomic swap with rollback on failure.
        if mv "$TARGET" "$BACKUP"; then
            if mv "$STAGED" "$TARGET"; then
                /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
                rm -rf "$BACKUP" "$CLEANUP"
                /usr/bin/open -n "$TARGET"
                exit 0
            else
                mv "$BACKUP" "$TARGET" 2>/dev/null || true
            fi
        fi

        rm -rf "$CLEANUP"
        exit 1
        """

        let scriptURL = cleanupDir.appendingPathComponent("apply-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(currentPID),
            stagedAppURL.path,
            targetAppURL.path,
            backupURL.path,
            cleanupDir.path
        ]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        try process.run()
    }

    // MARK: - Alerts

    private func presentUpToDateAlert(latestVersion: AppVersion) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Menubar Badges v\(currentVersion) is currently the latest available release (latest on GitHub: v\(latestVersion))."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(
        title: String,
        message: String,
        openURLOnAction: URL? = nil,
        actionTitle: String? = nil
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let actionTitle, openURLOnAction != nil {
            alert.addButton(withTitle: actionTitle)
            alert.addButton(withTitle: "Close")
        } else {
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()
        if let url = openURLOnAction, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func summarizeReleaseNotes(_ notes: String) -> String {
        let lines = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("## ") && !$0.hasPrefix("### Download") }
            .prefix(8)
        let joined = lines.joined(separator: "\n")
        if joined.count > 420 {
            return String(joined.prefix(420)) + "…"
        }
        return joined
    }
}
