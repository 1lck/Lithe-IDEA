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
    static let minimumJDTLSMajorVersion = 17

    let homePath: String
    let version: String
    let vendor: String

    var id: String { homePath }

    var displayName: String {
        let vendor = vendor.isEmpty ? "JDK" : vendor
        return "\(vendor) \(version)"
    }

    var majorVersion: Int? {
        let components = version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        switch components.first {
        case 1:
            return components.count > 1 ? components[1] : nil
        case let major?:
            return major
        case nil:
            return nil
        }
    }

    var supportsJDTLS: Bool {
        majorVersion.map { $0 >= Self.minimumJDTLSMajorVersion } ?? false
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

enum JavaEnvironmentStatus: Equatable, Sendable {
    case checking
    case ready
    case jdkMissing
    case configuredJDKInvalid(path: String)

    var requiresAttention: Bool {
        self != .checking && self != .ready
    }

    var blocksJavaRun: Bool {
        switch self {
        case .jdkMissing, .configuredJDKInvalid: true
        case .checking, .ready: false
        }
    }
}

struct JavaEnvironmentReport: Equatable, Sendable {
    let status: JavaEnvironmentStatus
    let projectURL: URL
    let javaHomePath: String?
    let javaExecutablePath: String?

    static func checking(for projectURL: URL) -> Self {
        Self(
            status: .checking,
            projectURL: projectURL.standardizedFileURL,
            javaHomePath: nil,
            javaExecutablePath: nil
        )
    }

    var title: String {
        switch status {
        case .checking: "Checking Java environment…"
        case .ready: "Java environment ready"
        case .jdkMissing: "JDK not found"
        case .configuredJDKInvalid: "Configured JDK is invalid"
        }
    }

    var message: String {
        switch status {
        case .checking:
            "Lithe is checking the project JDK."
        case .ready:
            "A usable JDK is available for this project."
        case .jdkMissing:
            "This project contains Java sources, but no usable JDK was detected."
        case .configuredJDKInvalid(let path):
            "The configured JDK path is not a valid JDK: \(path)"
        }
    }

    var recovery: String {
        switch status {
        case .checking, .ready: ""
        case .jdkMissing:
            "Choose a JDK in the Java service settings or install a full JDK and set JAVA_HOME."
        case .configuredJDKInvalid:
            "Choose another JDK in the Java service settings or clear the invalid path."
        }
    }
}
