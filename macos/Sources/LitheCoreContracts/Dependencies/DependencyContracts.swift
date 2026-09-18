import Foundation

/// Project-owned Java paths that should be visible in the dependency browser.
/// Paths may be workspace-relative or absolute local paths supplied by the user.
package struct JavaDependencyPathConfiguration: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var sourcePaths: [String]
    package var binaryPaths: [String]
    package var mavenPaths: [String]
    package var additionalSearchPaths: [String]

    package init(
        version: Int = currentVersion,
        sourcePaths: [String] = [],
        binaryPaths: [String] = [],
        mavenPaths: [String] = [],
        additionalSearchPaths: [String] = []
    ) {
        self.version = version
        self.sourcePaths = sourcePaths
        self.binaryPaths = binaryPaths
        self.mavenPaths = mavenPaths
        self.additionalSearchPaths = additionalSearchPaths
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourcePaths
        case binaryPaths
        case mavenPaths
        case additionalSearchPaths
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        sourcePaths = try values.decodeIfPresent([String].self, forKey: .sourcePaths) ?? []
        binaryPaths = try values.decodeIfPresent([String].self, forKey: .binaryPaths) ?? []
        mavenPaths = try values.decodeIfPresent([String].self, forKey: .mavenPaths) ?? []
        additionalSearchPaths = try values.decodeIfPresent(
            [String].self,
            forKey: .additionalSearchPaths
        ) ?? []
    }
}

/// Identifies the project-scoped paths a dependency provider is allowed to use.
/// Providers must consume paths resolved by the owning runtime instead of
/// rediscovering dependencies from a machine-wide cache.
package struct DependencyResolutionContext: Equatable, Sendable {
    package let serviceID: String
    package let serviceDisplayName: String
    package let workspaceURL: URL
    package let sourceRoots: [URL]
    package let resourceRoots: [URL]
    package let classpath: [URL]
    package let jdkSourceArchive: URL?
    package let javaDependencyPaths: JavaDependencyPathConfiguration

    package init(
        serviceID: String = "workspace",
        serviceDisplayName: String? = nil,
        workspaceURL: URL,
        sourceRoots: [URL] = [],
        resourceRoots: [URL] = [],
        classpath: [URL] = [],
        jdkSourceArchive: URL? = nil,
        javaDependencyPaths: JavaDependencyPathConfiguration = .init()
    ) {
        self.serviceID = serviceID
        self.serviceDisplayName = serviceDisplayName ?? serviceID
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.sourceRoots = sourceRoots.map { $0.standardizedFileURL }
        self.resourceRoots = resourceRoots.map { $0.standardizedFileURL }
        self.classpath = classpath.map { $0.standardizedFileURL }
        self.jdkSourceArchive = jdkSourceArchive?.standardizedFileURL
        self.javaDependencyPaths = javaDependencyPaths
    }
}

package enum DependencyNodeKind: String, Equatable, Sendable {
    case group
    case packageNode
    case directory
    case file
    case unavailable
}

package enum DependencySource: Equatable, Sendable {
    case directory(URL)
    case archive(URL)
    case generated
    case unavailable
}

/// A node in the language-neutral dependency browser tree.
package struct DependencyNode: Identifiable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let subtitle: String?
    package let kind: DependencyNodeKind
    package let source: DependencySource
    package let children: [DependencyNode]

    package init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: DependencyNodeKind,
        source: DependencySource,
        children: [DependencyNode] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.source = source
        self.children = children
    }
}

package struct DependencyGraph: Equatable, Sendable {
    package let providerID: String
    package let serviceID: String
    package let roots: [DependencyNode]

    package init(providerID: String, serviceID: String = "workspace", roots: [DependencyNode]) {
        self.providerID = providerID
        self.serviceID = serviceID
        self.roots = roots
    }

    /// Merges service graphs while preserving the first-seen deterministic order.
    /// Shared JDKs and artifacts therefore appear once in an aggregated view.
    package static func aggregate(_ graphs: [DependencyGraph]) -> [DependencyNode] {
        var seen: Set<String> = []
        return graphs
            .flatMap(\.roots)
            .filter { seen.insert(Self.identity(for: $0)).inserted }
    }

    private static func identity(for node: DependencyNode) -> String {
        switch node.source {
        case .directory(let url), .archive(let url): return url.standardizedFileURL.path
        case .generated: return "generated:\(node.id)"
        case .unavailable: return "unavailable:\(node.id)"
        }
    }
}

// Note: Java 依赖浏览器的路径 ownership 见
// .agents/notes/implemented/architecture/2026-09-18-workspace-dependency-browser.md
/// Language-specific dependency discovery entry point.
package protocol WorkspaceDependencyProvider: Sendable {
    var providerID: String { get }
    func resolve(context: DependencyResolutionContext) async throws -> DependencyGraph
}
