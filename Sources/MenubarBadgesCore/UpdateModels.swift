import CryptoKit
import Foundation

/// Semantic version value (e.g. `0.2.1`, `v0.3.0`) supporting comparison.
public struct AppVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(parsing raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericPart = String(parts[0])
        let prereleasePart: String? = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

        let components = numericPart.split(separator: ".").map(String.init)
        guard !components.isEmpty, components.count <= 3 else { return nil }
        let ints = components.compactMap { Int($0) }
        guard ints.count == components.count, ints.allSatisfy({ $0 >= 0 }) else { return nil }

        self.major = ints[0]
        self.minor = ints.count > 1 ? ints[1] : 0
        self.patch = ints.count > 2 ? ints[2] : 0
        self.prerelease = prereleasePart
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        if let prerelease, !prerelease.isEmpty {
            return "\(base)-\(prerelease)"
        }
        return base
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A prerelease version is lower than the matching stable version (e.g. 0.3.0-rc1 < 0.3.0).
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let l?, let r?): return l.localizedStandardCompare(r) == .orderedAscending
        }
    }
}

/// Subset of the GitHub Releases API response needed for update checks.
public struct GitHubRelease: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int?
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
            case digest
        }

        public init(name: String, browserDownloadURL: URL, size: Int? = nil, digest: String? = nil) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.size = size
            self.digest = digest
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool?
    public let prerelease: Bool?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        htmlURL: URL,
        draft: Bool? = false,
        prerelease: Bool? = false,
        assets: [Asset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }
}

/// Details of an available upgrade fetched from GitHub Releases.
public struct UpdateAvailability: Equatable, Sendable {
    public let currentVersion: AppVersion
    public let latestVersion: AppVersion
    public let releaseTitle: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let dmgDownloadURL: URL
    public let dmgAssetName: String
    public let dmgSizeBytes: Int?
    public let expectedSHA256: String?

    public init(
        currentVersion: AppVersion,
        latestVersion: AppVersion,
        releaseTitle: String,
        releaseNotes: String,
        releasePageURL: URL,
        dmgDownloadURL: URL,
        dmgAssetName: String,
        dmgSizeBytes: Int?,
        expectedSHA256: String?
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseTitle = releaseTitle
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.dmgDownloadURL = dmgDownloadURL
        self.dmgAssetName = dmgAssetName
        self.dmgSizeBytes = dmgSizeBytes
        self.expectedSHA256 = expectedSHA256
    }

    public var formattedSize: String? {
        guard let bytes = dmgSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(current: AppVersion, latest: AppVersion)
    case updateAvailable(UpdateAvailability)
}

public enum UpdateError: LocalizedError, Equatable, Sendable {
    case invalidReleaseVersion(String)
    case missingDMGAsset(String)
    case httpError(Int)
    case checksumMismatch(expected: String, actual: String)
    case mountFailed(String)
    case appBundleNotFoundInDMG
    case invalidBundleIdentifier(String?)
    case codeSignatureInvalid(String)
    case notRunningFromAppBundle
    case installDestinationNotWritable(String)
    case installationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseVersion(let tag):
            return "Could not parse version number from release tag \"\(tag)\"."
        case .missingDMGAsset(let tag):
            return "Release \(tag) does not include a downloadable .dmg file."
        case .httpError(let code):
            return "GitHub returned HTTP \(code) while checking for updates."
        case .checksumMismatch(let expected, let actual):
            return "Downloaded DMG failed SHA-256 integrity check (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .mountFailed(let reason):
            return "Failed to mount the downloaded disk image: \(reason)"
        case .appBundleNotFoundInDMG:
            return "MenubarBadges.app was not found inside the downloaded disk image."
        case .invalidBundleIdentifier(let actual):
            return "Unexpected app bundle identifier in DMG: \(actual ?? "none")."
        case .codeSignatureInvalid(let reason):
            return "Downloaded app failed code signature verification: \(reason)"
        case .notRunningFromAppBundle:
            return "Automatic replacement requires running Menubar Badges from a .app bundle."
        case .installDestinationNotWritable(let path):
            return "No write permission to update \(path). Move MenubarBadges.app to a writable Applications folder or install manually from the DMG."
        case .installationFailed(let reason):
            return "Failed to install update: \(reason)"
        }
    }
}

/// Evaluates GitHub Releases API payloads and verifies SHA-256 digests.
public enum GitHubUpdateEvaluator {
    public static let defaultRepo = "gempir/menubar-badges"

    public static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(defaultRepo)/releases/latest")!
    }

    public static func evaluate(
        release: GitHubRelease,
        currentVersion: AppVersion
    ) throws -> UpdateCheckResult {
        guard let latestVersion = AppVersion(parsing: release.tagName) else {
            throw UpdateError.invalidReleaseVersion(release.tagName)
        }

        guard latestVersion > currentVersion else {
            return .upToDate(current: currentVersion, latest: latestVersion)
        }

        guard let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw UpdateError.missingDMGAsset(release.tagName)
        }

        let sha256 = extractSHA256(from: dmgAsset.digest)
        let title = (release.name?.isEmpty == false ? release.name! : release.tagName)
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let availability = UpdateAvailability(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseTitle: title,
            releaseNotes: notes,
            releasePageURL: release.htmlURL,
            dmgDownloadURL: dmgAsset.browserDownloadURL,
            dmgAssetName: dmgAsset.name,
            dmgSizeBytes: dmgAsset.size,
            expectedSHA256: sha256
        )
        return .updateAvailable(availability)
    }

    public static func extractSHA256(from digest: String?) -> String? {
        guard let digest else { return nil }
        let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sha256:") {
            let hex = String(trimmed.dropFirst("sha256:".count)).lowercased()
            return hex.count == 64 ? hex : nil
        }
        return nil
    }

    public static func sha256Hex(forFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyFileSHA256(at url: URL, expectedHex: String) throws {
        let actual = try sha256Hex(forFileAt: url)
        if actual.caseInsensitiveCompare(expectedHex) != .orderedSame {
            throw UpdateError.checksumMismatch(expected: expectedHex.lowercased(), actual: actual.lowercased())
        }
    }
}
