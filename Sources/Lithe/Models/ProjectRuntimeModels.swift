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

enum JavaEnvironmentStatus: Equatable, Sendable {
    case checking
    case ready
    case jdkMissing
    case configuredJDKInvalid(path: String)
    case jdbMissing
    case languageServerMissing

    var requiresAttention: Bool {
        self != .checking && self != .ready
    }

    var blocksJavaRun: Bool {
        switch self {
        case .jdkMissing, .configuredJDKInvalid, .jdbMissing: true
        case .checking, .ready, .languageServerMissing: false
        }
    }

    var blocksJavaEditing: Bool {
        switch self {
        case .checking, .ready: false
        case .jdkMissing, .configuredJDKInvalid, .languageServerMissing, .jdbMissing: true
        }
    }
}

struct JavaEnvironmentReport: Equatable, Sendable {
    let status: JavaEnvironmentStatus
    let projectURL: URL
    let javaHomePath: String?
    let javaExecutablePath: String?
    let jdbExecutablePath: String?
    let languageServerExecutablePath: String?

    static func checking(for projectURL: URL) -> Self {
        Self(
            status: .checking,
            projectURL: projectURL.standardizedFileURL,
            javaHomePath: nil,
            javaExecutablePath: nil,
            jdbExecutablePath: nil,
            languageServerExecutablePath: nil
        )
    }

    var title: String {
        switch status {
        case .checking: "Checking Java environment…"
        case .ready: "Java environment ready"
        case .jdkMissing: "JDK not found"
        case .configuredJDKInvalid: "Configured JDK is invalid"
        case .jdbMissing: "Java debugger is incomplete"
        case .languageServerMissing: "Java language server not found"
        }
    }

    var message: String {
        switch status {
        case .checking:
            "Lithe is checking the JDK, Java debugger, and Java language server."
        case .ready:
            "JDK, JDB, and the Java language server are available for this project."
        case .jdkMissing:
            "This project contains Java sources, but no usable JDK was detected."
        case .configuredJDKInvalid(let path):
            "The configured JDK path is not a valid JDK: \(path)"
        case .jdbMissing:
            "A JDK was found, but its bin/jdb debugger is unavailable."
        case .languageServerMissing:
            "The JDK is available, but JDT LS is not installed or configured."
        }
    }

    var recovery: String {
        switch status {
        case .checking, .ready: ""
        case .jdkMissing:
            "Choose a JDK in Project Settings or install a full JDK and set JAVA_HOME."
        case .configuredJDKInvalid:
            "Choose another JDK in Project Settings or clear the invalid path."
        case .jdbMissing:
            "Use a full JDK distribution instead of a JRE or minimal runtime."
        case .languageServerMissing:
            "Install/configure jdtls in Project Settings; Java run/debug remains available where the JDK supports it."
        }
    }
}
