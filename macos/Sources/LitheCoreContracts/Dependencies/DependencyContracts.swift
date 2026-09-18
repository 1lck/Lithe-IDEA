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
    /// Paths hidden from the Java dependency tree. Entries may be workspace-relative
    /// or absolute and match the entry itself and every descendant.
    package var excludedPaths: [String]

    package init(
        version: Int = currentVersion,
        sourcePaths: [String] = [],
        binaryPaths: [String] = [],
        mavenPaths: [String] = [],
        additionalSearchPaths: [String] = [],
        excludedPaths: [String] = []
    ) {
        self.version = version
        self.sourcePaths = sourcePaths
        self.binaryPaths = binaryPaths
        self.mavenPaths = mavenPaths
        self.additionalSearchPaths = additionalSearchPaths
        self.excludedPaths = excludedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourcePaths
        case binaryPaths
        case mavenPaths
        case additionalSearchPaths
        case excludedPaths
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
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
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

package enum DependencyNodeKind: String, Codable, Equatable, Sendable {
    case group
    case packageNode
    case directory
    case file
    case unavailable
}

package enum DependencySource: Codable, Equatable, Sendable {
    case directory(URL)
    case archive(URL)
    case generated
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
    }

    private enum Kind: String, Codable {
        case directory
        case archive
        case generated
        case unavailable
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .directory(let url):
            try container.encode(Kind.directory, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .archive(let url):
            try container.encode(Kind.archive, forKey: .kind)
            try container.encode(url, forKey: .url)
        case .generated:
            try container.encode(Kind.generated, forKey: .kind)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .directory:
            self = .directory(try container.decode(URL.self, forKey: .url))
        case .archive:
            self = .archive(try container.decode(URL.self, forKey: .url))
        case .generated:
            self = .generated
        case .unavailable:
            self = .unavailable
        }
    }
}

/// A node in the language-neutral dependency browser tree.
package struct DependencyNode: Codable, Identifiable, Equatable, Sendable {
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

package struct DependencyGraph: Codable, Equatable, Sendable {
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

/// A persisted projection of a dependency provider. The input signature is
/// owned by the service and must change whenever configuration or an input file
/// changes. Providers can therefore reuse this graph without rediscovering the
/// workspace on every IDE launch.
package struct JavaDependencyIndex: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package let version: Int
    package let inputSignature: String
    package let graph: DependencyGraph

    package init(
        version: Int = currentVersion,
        inputSignature: String,
        graph: DependencyGraph
    ) {
        self.version = version
        self.inputSignature = inputSignature
        self.graph = graph
    }
}

// Note: Java 依赖浏览器的路径 ownership 见
// .agents/notes/implemented/architecture/2026-09-18-workspace-dependency-browser.md
/// Language-specific dependency discovery entry point.
package protocol WorkspaceDependencyProvider: Sendable {
    var providerID: String { get }
    func resolve(context: DependencyResolutionContext) async throws -> DependencyGraph
}
