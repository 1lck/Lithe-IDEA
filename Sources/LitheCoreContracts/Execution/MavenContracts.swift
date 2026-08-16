import Foundation

package struct MavenProject: Identifiable, Hashable, Sendable {
    package let rootURL: URL
    package let pomURL: URL
    package let groupID: String?
    package let artifactID: String
    package let version: String?
    package let packaging: String
    package let modules: [MavenModule]
    package let profiles: [MavenProfile]
    package let hasWrapper: Bool

    package init(
        rootURL: URL,
        pomURL: URL,
        groupID: String?,
        artifactID: String,
        version: String?,
        packaging: String,
        modules: [MavenModule],
        profiles: [MavenProfile],
        hasWrapper: Bool
    ) {
        self.rootURL = rootURL
        self.pomURL = pomURL
        self.groupID = groupID
        self.artifactID = artifactID
        self.version = version
        self.packaging = packaging
        self.modules = modules
        self.profiles = profiles
        self.hasWrapper = hasWrapper
    }

    package var id: String { rootURL.path }
    package var displayName: String { artifactID.isEmpty ? rootURL.lastPathComponent : artifactID }
    package var isMultiModule: Bool { !modules.isEmpty }
    package var allModules: [MavenModule] { modules + modules.flatMap { $0.allModules } }
}

package struct MavenModule: Identifiable, Hashable, Sendable {
    package let relativePath: String
    package let url: URL
    package let groupID: String?
    package let artifactID: String
    package let version: String?
    package let packaging: String
    package let modules: [MavenModule]

    package init(
        relativePath: String,
        url: URL,
        groupID: String?,
        artifactID: String,
        version: String?,
        packaging: String,
        modules: [MavenModule]
    ) {
        self.relativePath = relativePath
        self.url = url
        self.groupID = groupID
        self.artifactID = artifactID
        self.version = version
        self.packaging = packaging
        self.modules = modules
    }

    package var id: String { relativePath }
    package var displayName: String { artifactID.isEmpty ? relativePath : artifactID }
    package var allModules: [MavenModule] { modules + modules.flatMap { $0.allModules } }
}

package struct MavenProfile: Identifiable, Hashable, Sendable {
    package let id: String
    package let isActiveByDefault: Bool

    package init(id: String, isActiveByDefault: Bool) {
        self.id = id
        self.isActiveByDefault = isActiveByDefault
    }
}

package enum MavenLifecyclePhase: String, CaseIterable, Identifiable, Sendable {
    case clean, validate, compile, test
    case packagePhase = "package"
    case verify, install, site, deploy

    package var id: String { rawValue }
    package var title: String { rawValue }
    package var systemImage: String {
        switch self {
        case .clean: "trash"
        case .validate: "checkmark.seal"
        case .compile: "hammer"
        case .test: "checkmark.circle"
        case .packagePhase: "shippingbox"
        case .verify: "checkmark.shield"
        case .install: "arrow.down.to.line"
        case .site: "globe"
        case .deploy: "arrow.up.to.line"
        }
    }
}

package enum MavenIssueSeverity: String, Sendable {
    case error, warning, info

    package var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

package struct MavenBuildIssue: Identifiable, Hashable, Sendable {
    package let id: String
    package let fileURL: URL?
    package let line: Int?
    package let column: Int?
    package let severity: MavenIssueSeverity
    package let message: String

    package init(id: String, fileURL: URL?, line: Int?, column: Int?, severity: MavenIssueSeverity, message: String) {
        self.id = id
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }

    package var locationTitle: String {
        guard let fileURL else { return "Build output" }
        let location = [line, column].compactMap { $0.map(String.init) }.joined(separator: ":")
        return location.isEmpty ? fileURL.lastPathComponent : fileURL.lastPathComponent + ":" + location
    }
}

package protocol MavenProjectOperations: Sendable {
    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject?
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue]
}

@MainActor
package protocol MavenRuntimePort: AnyObject {
    func mavenExecutable(for project: MavenProject) -> URL?
    func mavenProcessEnvironment() -> [String: String]
}
