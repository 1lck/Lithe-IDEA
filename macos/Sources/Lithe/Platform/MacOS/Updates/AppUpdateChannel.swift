import Foundation

// Note: .agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md
// User consent is independent of the installed distribution. A cross-channel
// installation must not compare stable semver with workflow build identities.
enum AppUpdateChannel: String, CaseIterable, Identifiable, Sendable, Decodable {
    case stable
    case autobuild

    static let preferenceKey = "appUpdateChannel"
    static let stableReleaseURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/latest")!
    static let autoBuildReleaseURL = URL(string: "https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild")!
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stable: "Stable (Recommended)"
        case .autobuild: "AutoBuild Rolling"
        }
    }

    static func installed(info: [String: Any]) -> Self {
        ["preview", "autobuild"].contains(info["LitheUpdateChannel"] as? String ?? "") ? .autobuild : .stable
    }

    func requiresFullInstallation(from installed: Self) -> Bool { self != installed }

    static func saved(in defaults: UserDefaults, defaultChannel: Self = .stable) -> Self {
        guard let value = defaults.object(forKey: preferenceKey) else { return defaultChannel }
        guard let value = value as? String else { return .stable }
        return Self(rawValue: value) ?? .stable
    }

    func releaseURL(info: [String: Any]) -> URL {
        let key = self == .autobuild ? "LitheAutoBuildReleaseURL" : "LitheStableReleaseURL"
        return (info[key] as? String).flatMap(URL.init(string:))
            ?? (self == .autobuild ? Self.autoBuildReleaseURL : Self.stableReleaseURL)
    }

    func feedURL(info: [String: Any], architecture: String) -> String? {
        if self == .stable {
            if let stableFeed = info["LitheStableFeedURL"] as? String { return stableFeed }
            return Self.installed(info: info) == .stable ? info["SUFeedURL"] as? String : nil
        }
        return info["LitheAutoBuildFeedURL"] as? String
            ?? "https://github.com/1lck/Lithe-IDEA/releases/download/AutoBuild/appcast-preview-\(architecture).xml"
    }
}
