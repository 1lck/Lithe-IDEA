import Foundation
import LitheCoreContracts

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

struct ProjectModuleRuntimeOverride: Codable, Hashable, Sendable, Identifiable {
    /// Workspace-relative subproject path, using `/` separators.
    var path: String
    /// Empty means inherit the project JDK.
    var javaHomePath = ""
    /// Empty means inherit the project Maven home or wrapper.
    var mavenExecutablePath = ""
    /// Empty means inherit the project Maven JDK, then the project JDK.
    var mavenJavaHomePath = ""

    var id: String { path }

    var hasOverride: Bool {
        !normalized(javaHomePath).isEmpty
            || !normalized(mavenExecutablePath).isEmpty
            || !normalized(mavenJavaHomePath).isEmpty
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProjectRuntimeSettings: Codable, Hashable, Sendable {
    /// Empty means use the detected system JDK.
    var javaHomePath = ""
    var mavenHomeSelection: MavenHomeSelection = .automatic
    var mavenHomePath = ""
    /// Empty means use the project JDK, then the detected system JDK.
    var mavenJavaHomePath = ""
    var mavenSettingsPath = ""
    var mavenLocalRepositoryPath = ""
    /// Per-subproject JDK and Maven overrides for monorepos.
    var moduleOverrides: [ProjectModuleRuntimeOverride] = []

    enum CodingKeys: String, CodingKey {
        case javaHomePath, mavenHomeSelection, mavenHomePath, mavenJavaHomePath
        case mavenSettingsPath, mavenLocalRepositoryPath, moduleOverrides
    }

    init(
        javaHomePath: String = "",
        mavenHomeSelection: MavenHomeSelection = .automatic,
        mavenHomePath: String = "",
        mavenJavaHomePath: String = "",
        mavenSettingsPath: String = "",
        mavenLocalRepositoryPath: String = "",
        moduleOverrides: [ProjectModuleRuntimeOverride] = []
    ) {
        self.javaHomePath = javaHomePath
        self.mavenHomeSelection = mavenHomeSelection
        self.mavenHomePath = mavenHomePath
        self.mavenJavaHomePath = mavenJavaHomePath
        self.mavenSettingsPath = mavenSettingsPath
        self.mavenLocalRepositoryPath = mavenLocalRepositoryPath
        self.moduleOverrides = moduleOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        javaHomePath = try container.decodeIfPresent(String.self, forKey: .javaHomePath) ?? ""
        mavenHomeSelection = try container.decodeIfPresent(
            MavenHomeSelection.self,
            forKey: .mavenHomeSelection
        ) ?? .automatic
        mavenHomePath = try container.decodeIfPresent(String.self, forKey: .mavenHomePath) ?? ""
        mavenJavaHomePath = try container.decodeIfPresent(String.self, forKey: .mavenJavaHomePath) ?? ""
        mavenSettingsPath = try container.decodeIfPresent(String.self, forKey: .mavenSettingsPath) ?? ""
        mavenLocalRepositoryPath = try container.decodeIfPresent(
            String.self,
            forKey: .mavenLocalRepositoryPath
        ) ?? ""
        moduleOverrides = try container.decodeIfPresent(
            [ProjectModuleRuntimeOverride].self,
            forKey: .moduleOverrides
        ) ?? []
    }

    /// Maven executable or home stored for the project-wide toolchain.
    var mavenExecutableOverride: String {
        switch mavenHomeSelection {
        case .automatic:
            ""
        case .wrapper:
            "mvnw"
        case .custom:
            mavenHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func override(matching workspaceRelativePath: String?) -> ProjectModuleRuntimeOverride? {
        let target = Self.normalizedRelativePath(workspaceRelativePath)
        guard !target.isEmpty, target != "." else { return nil }
        return moduleOverrides
            .filter { candidate in
                let path = Self.normalizedRelativePath(candidate.path)
                guard !path.isEmpty, path != "." else { return false }
                return target == path || target.hasPrefix(path + "/")
            }
            .max { lhs, rhs in
                Self.normalizedRelativePath(lhs.path).count < Self.normalizedRelativePath(rhs.path).count
            }
    }

    func exactOverride(for workspaceRelativePath: String) -> ProjectModuleRuntimeOverride? {
        let target = Self.normalizedRelativePath(workspaceRelativePath)
        guard !target.isEmpty else { return nil }
        return moduleOverrides.first { Self.normalizedRelativePath($0.path) == target }
    }

    func overlay(
        onto options: RunOptions,
        workspaceRelativePath: String?
    ) -> RunOptions {
        var result = options
        let module = override(matching: workspaceRelativePath)
        let projectJava = javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectMaven = mavenExecutableOverride
        let projectMavenJava = mavenJavaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        result.javaHomePath = Self.resolvedPath(
            configured: options.javaHomePath,
            inheritedDefault: projectJava,
            override: module?.javaHomePath
        )
        result.mavenExecutablePath = Self.resolvedPath(
            configured: options.mavenExecutablePath,
            inheritedDefault: projectMaven,
            override: module?.mavenExecutablePath
        )
        result.mavenJavaHomePath = Self.resolvedPath(
            configured: options.mavenJavaHomePath,
            inheritedDefault: projectMavenJava,
            override: module?.mavenJavaHomePath
        )
        return result
    }

    mutating func setOverride(
        path: String,
        javaHomePath: String? = nil,
        mavenExecutablePath: String? = nil,
        mavenJavaHomePath: String? = nil
    ) {
        let normalizedPath = Self.normalizedRelativePath(path)
        guard !normalizedPath.isEmpty, normalizedPath != "." else { return }
        var current = override(matching: normalizedPath) ?? ProjectModuleRuntimeOverride(path: normalizedPath)
        current.path = normalizedPath
        if let javaHomePath { current.javaHomePath = javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let mavenExecutablePath {
            current.mavenExecutablePath = mavenExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let mavenJavaHomePath {
            current.mavenJavaHomePath = mavenJavaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        moduleOverrides.removeAll { Self.normalizedRelativePath($0.path) == normalizedPath }
        if current.hasOverride {
            moduleOverrides.append(current)
            moduleOverrides.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    func projectToolchainSelection() -> ProjectToolchainSelection {
        ProjectToolchainSelection(
            javaHomePath: javaHomePath.trimmingCharacters(in: .whitespacesAndNewlines),
            mavenExecutablePath: mavenExecutableOverride,
            mavenJavaHomePath: mavenJavaHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func normalizedRelativePath(_ path: String?) -> String {
        guard let path else { return "" }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." { return "" }
        var normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasPrefix("./") {
            normalized.removeFirst(2)
        }
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// A run-configuration path that equals the project default is treated as
    /// inheritance so a more specific subproject override can still apply.
    static func resolvedPath(configured: String, inheritedDefault: String, override: String?) -> String {
        let configuredPath = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedPath = inheritedDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        let overridePath = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isExplicitConfiguration = !configuredPath.isEmpty && configuredPath != inheritedPath
        if isExplicitConfiguration { return configuredPath }
        if !overridePath.isEmpty { return overridePath }
        if !configuredPath.isEmpty { return configuredPath }
        return inheritedPath
    }
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
            "Choose a JDK in Settings → Project or install a full JDK and set JAVA_HOME."
        case .configuredJDKInvalid:
            "Choose another JDK in Settings → Project or clear the invalid path."
        }
    }
}
