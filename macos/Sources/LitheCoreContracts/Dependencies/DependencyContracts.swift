import Foundation

/// User-owned paths that should be visible for one registered dependency source.
/// Paths may be workspace-relative or absolute local paths supplied by the user.
package struct DependencyPathConfiguration: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var sourcePaths: [String]
    package var binaryPaths: [String]
    package var dependencyPaths: [String]
    package var additionalSearchPaths: [String]
    /// Paths hidden from this service's dependency tree. Entries may be workspace-relative
    /// or absolute and match the entry itself and every descendant.
    package var excludedPaths: [String]

    package init(
        version: Int = currentVersion,
        sourcePaths: [String] = [],
        binaryPaths: [String] = [],
        dependencyPaths: [String] = [],
        additionalSearchPaths: [String] = [],
        excludedPaths: [String] = []
    ) {
        self.version = version
        self.sourcePaths = sourcePaths
        self.binaryPaths = binaryPaths
        self.dependencyPaths = dependencyPaths
        self.additionalSearchPaths = additionalSearchPaths
        self.excludedPaths = excludedPaths
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourcePaths
        case binaryPaths
        case dependencyPaths
        case additionalSearchPaths
        case excludedPaths
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        sourcePaths = try values.decodeIfPresent([String].self, forKey: .sourcePaths) ?? []
        binaryPaths = try values.decodeIfPresent([String].self, forKey: .binaryPaths) ?? []
        dependencyPaths = try values.decodeIfPresent([String].self, forKey: .dependencyPaths) ?? []
        additionalSearchPaths = try values.decodeIfPresent(
            [String].self,
            forKey: .additionalSearchPaths
        ) ?? []
        excludedPaths = try values.decodeIfPresent([String].self, forKey: .excludedPaths) ?? []
    }

    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(sourcePaths, forKey: .sourcePaths)
        try values.encode(binaryPaths, forKey: .binaryPaths)
        try values.encode(dependencyPaths, forKey: .dependencyPaths)
        try values.encode(additionalSearchPaths, forKey: .additionalSearchPaths)
        try values.encode(excludedPaths, forKey: .excludedPaths)
    }
}

/// Workspace JSON keyed by registered dependency-source ID.
package struct WorkspaceDependencyConfiguration: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var services: [String: DependencyPathConfiguration]

    package init(
        version: Int = currentVersion,
        services: [String: DependencyPathConfiguration] = [:]
    ) {
        self.version = version
        self.services = services
    }
}

/// A language source explicitly registered in the dependency sidebar.
package struct DependencyServiceDescriptor: Identifiable, Equatable, Sendable {
    package let id: String
    package let displayName: String
    package let providerID: String
    package let providerDisplayName: String
    package let systemImage: String

    package init(
        id: String,
        displayName: String,
        providerID: String,
        providerDisplayName: String,
        systemImage: String
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.systemImage = systemImage
    }
}

/// Identifies the project-scoped paths a dependency provider is allowed to use.
/// Providers must consume paths resolved by the owning runtime instead of
/// rediscovering dependencies from a machine-wide cache.
package struct DependencyResolutionContext: Equatable, Sendable {
    package let serviceID: String
    package let serviceDisplayName: String
    package let providerID: String
    package let providerDisplayName: String
    package let workspaceURL: URL
    package let sourceRoots: [URL]
    package let resourceRoots: [URL]
    package let classpath: [URL]
    package let dependencyRoots: [URL]
    package let binaryRoots: [URL]
    package let virtualDocuments: [LanguageDependencyVirtualDocument]
    package let dependencyPaths: DependencyPathConfiguration

    package init(
        serviceID: String = "workspace",
        serviceDisplayName: String? = nil,
        providerID: String = "workspace",
        providerDisplayName: String? = nil,
        workspaceURL: URL,
        sourceRoots: [URL] = [],
        resourceRoots: [URL] = [],
        classpath: [URL] = [],
        dependencyRoots: [URL] = [],
        binaryRoots: [URL] = [],
        virtualDocuments: [LanguageDependencyVirtualDocument] = [],
        dependencyPaths: DependencyPathConfiguration = .init()
    ) {
        self.serviceID = serviceID
        self.serviceDisplayName = serviceDisplayName ?? serviceID
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName ?? providerID
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.sourceRoots = sourceRoots.map { $0.standardizedFileURL }
        self.resourceRoots = resourceRoots.map { $0.standardizedFileURL }
        self.classpath = classpath.map { $0.standardizedFileURL }
        self.dependencyRoots = dependencyRoots.map { $0.standardizedFileURL }
        self.binaryRoots = binaryRoots.map { $0.standardizedFileURL }
        self.virtualDocuments = virtualDocuments
        self.dependencyPaths = dependencyPaths
    }
}

/// Paths already resolved by a language plugin or its upstream project model.
/// Producing this snapshot must not start a discovery scan from the sidebar.
public struct LanguageDependencySnapshot: Codable, Equatable, Sendable {
    public let sourceRoots: [URL]
    public let binaryRoots: [URL]
    public let dependencyRoots: [URL]
    public let virtualDocuments: [LanguageDependencyVirtualDocument]

    public init(
        sourceRoots: [URL] = [],
        binaryRoots: [URL] = [],
        dependencyRoots: [URL] = [],
        virtualDocuments: [LanguageDependencyVirtualDocument] = []
    ) {
        self.sourceRoots = sourceRoots
        self.binaryRoots = binaryRoots
        self.dependencyRoots = dependencyRoots
        self.virtualDocuments = virtualDocuments
    }
}

public struct LanguageDependencyVirtualDocument: Codable, Equatable, Sendable {
    public let title: String
    public let uri: URL

    public init(title: String, uri: URL) {
        self.title = title
        self.uri = uri
    }
}

/// Optional capability of an active language plugin. The host asks for its
/// current snapshot only; plugin activation and discovery are separate work.
@MainActor
public protocol LanguageDependencyProviding: AnyObject {
    func dependencySnapshot(workspaceURL: URL, serviceID: String) -> LanguageDependencySnapshot?
    func setDependencySnapshotChangeHandler(_ handler: (@MainActor () -> Void)?)
}

public extension LanguageDependencyProviding {
    func setDependencySnapshotChangeHandler(_ handler: (@MainActor () -> Void)?) {}
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
    case virtualDocument(URL)
    case generated
    case unavailable

    private enum CodingKeys: String, CodingKey {
        case kind
        case url
    }

    private enum Kind: String, Codable {
        case directory
        case archive
        case virtualDocument
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
        case .virtualDocument(let url):
            try container.encode(Kind.virtualDocument, forKey: .kind)
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
        case .virtualDocument:
            self = .virtualDocument(try container.decode(URL.self, forKey: .url))
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
    /// Shared source roots and artifacts therefore appear once in an aggregated view.
    package static func aggregate(_ graphs: [DependencyGraph]) -> [DependencyNode] {
        var seen: Set<String> = []
        return graphs
            .flatMap(\.roots)
            .filter { seen.insert(Self.identity(for: $0)).inserted }
    }

    private static func identity(for node: DependencyNode) -> String {
        switch node.source {
        case .directory(let url), .archive(let url): return url.standardizedFileURL.path
        case .virtualDocument(let url): return url.absoluteString
        case .generated: return "generated:\(node.id)"
        case .unavailable: return "unavailable:\(node.id)"
        }
    }
}

/// A persisted projection of a dependency provider. The input signature is
/// owned by the service and must change whenever configuration or an input file
/// changes. Providers can therefore reuse this graph without rediscovering the
/// workspace on every IDE launch.
package struct DependencyIndex: Codable, Equatable, Sendable {
    package static let currentVersion = 2

    package let version: Int
    package let inputSignature: String
    package let graph: DependencyGraph
    package let languageSnapshot: LanguageDependencySnapshot?

    package init(
        version: Int = currentVersion,
        inputSignature: String,
        graph: DependencyGraph,
        languageSnapshot: LanguageDependencySnapshot? = nil
    ) {
        self.version = version
        self.inputSignature = inputSignature
        self.graph = graph
        self.languageSnapshot = languageSnapshot
    }
}

package struct WorkspaceDependencyIndexes: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package let version: Int
    package var services: [String: DependencyIndex]

    package init(
        version: Int = currentVersion,
        services: [String: DependencyIndex] = [:]
    ) {
        self.version = version
        self.services = services
    }
}

package protocol WorkspaceDependencyStoring: Sendable {
    func loadDependencyConfiguration(workspaceURL: URL) throws -> WorkspaceDependencyConfiguration?
    func saveDependencyConfiguration(
        _ configuration: WorkspaceDependencyConfiguration,
        workspaceURL: URL
    ) throws
    func loadDependencyIndexes(workspaceURL: URL) throws -> WorkspaceDependencyIndexes?
    func saveDependencyIndexes(
        _ indexes: WorkspaceDependencyIndexes,
        workspaceURL: URL
    ) throws
}

// Note: 工作区依赖浏览器的路径 ownership 见
// .agents/notes/implemented/architecture/2026-09-18-workspace-dependency-browser.md
/// Language-specific dependency discovery entry point.
package protocol WorkspaceDependencyProvider: Sendable {
    var providerID: String { get }
    func resolve(context: DependencyResolutionContext) async throws -> DependencyGraph
}
