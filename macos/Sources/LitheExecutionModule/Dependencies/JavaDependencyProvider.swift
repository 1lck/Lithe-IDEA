import Foundation
import LitheCoreContracts

/// Projects resolved Java paths into a stable, grouped dependency browser tree.
package struct JavaDependencyProvider: WorkspaceDependencyProvider {
    package let providerID = "java"

    package init() {}

    /// Returns the conventional JDK source archive for a registered JDK home.
    /// The runtime locator remains responsible for validating that the archive
    /// exists; this provider only preserves the resolved service configuration.
    package static func sourceArchive(for javaHome: URL) -> URL {
        javaHome.standardizedFileURL.appendingPathComponent("lib/src.zip")
    }

    package func resolve(
        context: DependencyResolutionContext
    ) async throws -> DependencyGraph {
        let configured = context.javaDependencyPaths
        let sourcePaths = Self.configuredURLs(
            configured.sourcePaths,
            workspaceURL: context.workspaceURL
        )
        let binaryPaths = Self.configuredURLs(
            configured.binaryPaths,
            workspaceURL: context.workspaceURL
        )
        let mavenPaths = Self.configuredURLs(
            configured.mavenPaths,
            workspaceURL: context.workspaceURL
        )
        let additionalPaths = Self.configuredURLs(
            configured.additionalSearchPaths,
            workspaceURL: context.workspaceURL
        )
        let excludedPaths = Self.configuredURLs(
            configured.excludedPaths,
            workspaceURL: context.workspaceURL
        )

        let sourceEntries = Self.uniqueNodes(
            context.sourceRoots.map { Self.makeNode(for: $0, preferDirectory: true) }
                + sourcePaths.map { Self.makeNode(for: $0, preferDirectory: true) }
                + (context.jdkSourceArchive.map {
                    [Self.makeNode(for: $0, preferDirectory: false)]
                } ?? [])
        ).filter { !Self.isExcluded($0, by: excludedPaths) }
        let binaryEntries = Self.uniqueNodes(
            context.classpath
                .filter { $0.hasDirectoryPath }
                .map { Self.makeNode(for: $0, preferDirectory: true) }
                + binaryPaths.map { Self.makeNode(for: $0, preferDirectory: true) }
        ).filter { !Self.isExcluded($0, by: excludedPaths) }
        let mavenEntries = Self.uniqueNodes(
            context.classpath
                .filter { !$0.hasDirectoryPath }
                .map { Self.makeNode(for: $0, preferDirectory: false) }
                + mavenPaths.map { Self.makeNode(for: $0, preferDirectory: false) }
        ).filter { !Self.isExcluded($0, by: excludedPaths) }
        let additionalEntries = Self.uniqueNodes(
            additionalPaths.map { Self.makeNode(for: $0, preferDirectory: false) }
        ).filter { !Self.isExcluded($0, by: excludedPaths) }
        let groups = [
            Self.groupNode(id: "source", title: "Source Code", children: sourceEntries),
            Self.groupNode(id: "bin", title: "bin", children: binaryEntries),
            Self.groupNode(id: "maven", title: "Maven", children: mavenEntries),
            Self.groupNode(
                id: "additional-search-paths",
                title: "Additional Search Paths",
                children: additionalEntries
            )
        ]

        return DependencyGraph(
            providerID: providerID,
            serviceID: context.serviceID,
            roots: [
                DependencyNode(
                    id: "java:\(context.serviceID)",
                    title: "Java",
                    subtitle: context.serviceDisplayName,
                    kind: .group,
                    source: .generated,
                    children: groups
                )
            ]
        )
    }

    private static func groupNode(
        id: String,
        title: String,
        children: [DependencyNode]
    ) -> DependencyNode {
        DependencyNode(
            id: "java-group:\(id)",
            title: title,
            kind: .group,
            source: .generated,
            children: children
        )
    }

    private static func configuredURLs(
        _ paths: [String],
        workspaceURL: URL
    ) -> [URL] {
        paths.compactMap { value in
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
            return URL(fileURLWithPath: expanded, relativeTo: workspaceURL)
                .standardizedFileURL
        }
    }

    private static func isExcluded(_ node: DependencyNode, by excludedPaths: [URL]) -> Bool {
        let path: String
        switch node.source {
        case .directory(let url), .archive(let url):
            path = url.standardizedFileURL.path
        case .generated, .unavailable:
            return false
        }
        return excludedPaths.contains { excluded in
            let excludedPath = excluded.standardizedFileURL.path
            return path == excludedPath || path.hasPrefix(excludedPath + "/")
        }
    }

    private static func uniqueNodes(_ nodes: [DependencyNode]) -> [DependencyNode] {
        var seen: Set<String> = []
        return nodes
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                guard titleOrder == .orderedSame else {
                    return titleOrder == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    private static func makeNode(
        for url: URL,
        preferDirectory: Bool
    ) -> DependencyNode {
        let normalized = url.standardizedFileURL
        let name = normalized.lastPathComponent.isEmpty
            ? normalized.path
            : normalized.lastPathComponent
        let extensionName = normalized.pathExtension.lowercased()
        let isArchive = extensionName == "jar" || extensionName == "zip"
        let isDirectory = preferDirectory
            || normalized.hasDirectoryPath
            || (!isArchive && extensionName.isEmpty)
        let kind: DependencyNodeKind
        let source: DependencySource
        if isDirectory {
            kind = .directory
            source = .directory(normalized)
        } else if isArchive {
            kind = .packageNode
            source = .archive(normalized)
        } else {
            kind = .file
            source = .unavailable
        }

        return DependencyNode(
            id: normalized.path,
            title: name,
            subtitle: normalized.path,
            kind: kind,
            source: source
        )
    }
}
