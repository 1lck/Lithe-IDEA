import Foundation

enum MavenHomeSelection: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case wrapper
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .wrapper: "Maven Wrapper"
        case .custom: "Custom Maven Home"
        }
    }
}

struct ProjectRuntimeSettings: Codable, Hashable, Sendable {
    /// Empty means use the detected system JDK.
    var javaHomePath = ""
    var mavenHomeSelection: MavenHomeSelection = .automatic
    var mavenHomePath = ""
    /// Empty means use the project JDK, then the detected system JDK.
    var mavenJavaHomePath = ""
}

struct JavaRuntimeCandidate: Identifiable, Hashable, Sendable {
    let homePath: String
    let version: String
    let vendor: String

    var id: String { homePath }

    var displayName: String {
        let vendor = vendor.isEmpty ? "JDK" : vendor
        return "\(vendor) \(version)"
    }
}

struct MavenRuntimeCandidate: Identifiable, Hashable, Sendable {
    let homePath: String
    let executablePath: String
    let version: String

    var id: String { executablePath }

    var displayName: String {
        version.isEmpty ? "Maven" : "Maven \(version)"
    }
}

struct RuntimeDiscoveryResult: Sendable {
    let javaRuntimes: [JavaRuntimeCandidate]
    let mavenRuntimes: [MavenRuntimeCandidate]
}
