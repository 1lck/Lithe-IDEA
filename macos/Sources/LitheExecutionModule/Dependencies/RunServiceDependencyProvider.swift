import Foundation
import LitheCoreContracts

/// Projects registered language sources and explicit JSON paths into the tree.
/// Discovery and LSP activation stay with the owning language plugin.
package struct RunServiceDependencyProvider: WorkspaceDependencyProvider {
    package let providerID = "run-service"

    package init() {}

    /// Returns only dependency-management files already present in the workspace
    /// inventory. Watching these paths never performs a directory walk.
    package func managementFiles(
        providerID: String,
        files: [URL],
        declaredFileNames: [String]? = nil
    ) -> [URL] {
        files
            .map(\.standardizedFileURL)
            .filter { manages($0, providerID: providerID, declaredFileNames: declaredFileNames) }
            .sorted { $0.path < $1.path }
    }

    package func manages(
        _ fileURL: URL,
        providerID: String,
        declaredFileNames: [String]? = nil
    ) -> Bool {
        if let declaredFileNames {
            let path = fileURL.standardizedFileURL.path.lowercased()
            return declaredFileNames.contains {
                $0.contains("/") ? path.hasSuffix("/" + $0) : fileURL.lastPathComponent.lowercased() == $0
            }
        }
        let provider = providerID.split(separator: ".").first.map(String.init) ?? providerID
        return Self.managementFileNames[provider, default: []]
            .contains(fileURL.lastPathComponent.lowercased())
    }

    package func resolve(
        context: DependencyResolutionContext
    ) async throws -> DependencyGraph {
        let configured = context.dependencyPaths
        let excluded = Self.urls(configured.excludedPaths, relativeTo: context.workspaceURL)
        let sourceRoots = Self.nodes(
            context.sourceRoots + Self.urls(configured.sourcePaths, relativeTo: context.workspaceURL),
            preferDirectory: true,
            excluding: excluded
        )
        let binaryRoots = Self.nodes(
            context.binaryRoots + context.classpath.filter(Self.isDirectoryLike)
                + Self.urls(configured.binaryPaths, relativeTo: context.workspaceURL),
            preferDirectory: true,
            excluding: excluded
        )
        let dependencyRoots = Self.nodes(
            context.dependencyRoots + context.classpath.filter { !Self.isDirectoryLike($0) }
                + Self.urls(configured.dependencyPaths, relativeTo: context.workspaceURL),
            preferDirectory: false,
            excluding: excluded
        )
        let virtualRoots = context.virtualDocuments
            .filter { !$0.uri.isFileURL }
            .sorted { $0.uri.absoluteString < $1.uri.absoluteString }
            .map { document in
                DependencyNode(
                    id: document.uri.absoluteString,
                    title: document.title,
                    subtitle: document.uri.absoluteString,
                    kind: .file,
                    source: .virtualDocument(document.uri)
                )
            }
        let additionalRoots = Self.nodes(
            Self.urls(configured.additionalSearchPaths, relativeTo: context.workspaceURL),
            preferDirectory: false,
            excluding: excluded
        )

        let root = DependencyNode(
            id: "service:\(context.serviceID)",
            title: context.serviceDisplayName,
            subtitle: context.providerDisplayName,
            kind: .group,
            source: .generated,
            children: [
                Self.group("sources", title: "Source Code", serviceID: context.serviceID, children: sourceRoots),
                Self.group("outputs", title: "Build Outputs", serviceID: context.serviceID, children: binaryRoots),
                Self.group("dependencies", title: "Dependencies", serviceID: context.serviceID, children: dependencyRoots + virtualRoots),
                Self.group(
                    "additional",
                    title: "Additional Search Paths",
                    serviceID: context.serviceID,
                    children: additionalRoots
                )
            ]
        )
        return DependencyGraph(
            providerID: context.providerID,
            serviceID: context.serviceID,
            roots: [root]
        )
    }

    private static func group(
        _ id: String,
        title: String,
        serviceID: String,
        children: [DependencyNode]
    ) -> DependencyNode {
        DependencyNode(
            id: "service:\(serviceID):\(id)",
            title: title,
            kind: .group,
            source: .generated,
            children: children
        )
    }

    private static func urls(_ paths: [String], relativeTo workspaceURL: URL) -> [URL] {
        paths.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let expanded = (trimmed as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL
            }
            return URL(fileURLWithPath: expanded, relativeTo: workspaceURL).standardizedFileURL
        }
    }

    private static func nodes(
        _ urls: [URL],
        preferDirectory: Bool,
        excluding excluded: [URL]
    ) -> [DependencyNode] {
        var seen: Set<String> = []
        return urls
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted && !isExcluded($0, by: excluded) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { makeNode(for: $0, preferDirectory: preferDirectory) }
    }

    private static func makeNode(for url: URL, preferDirectory: Bool) -> DependencyNode {
        let extensionName = url.pathExtension.lowercased()
        let isArchive = ["jar", "zip", "aar", "whl"].contains(extensionName)
        let isDirectory = preferDirectory || isDirectoryLike(url)
        return DependencyNode(
            id: url.path,
            title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            subtitle: url.path,
            kind: isDirectory ? .directory : (isArchive ? .packageNode : .file),
            source: isDirectory ? .directory(url) : (isArchive ? .archive(url) : .unavailable)
        )
    }

    private static func isDirectoryLike(_ url: URL) -> Bool {
        url.hasDirectoryPath || url.pathExtension.isEmpty
    }

    private static func isExcluded(_ url: URL, by excluded: [URL]) -> Bool {
        excluded.contains { item in
            let prefix = item.standardizedFileURL.path
            return url.path == prefix || url.path.hasPrefix(prefix + "/")
        }
    }

    /// Compatibility fallback for providers without a language plugin manifest.
    /// A declared file list always takes precedence, including an empty list.
    private static let managementFileNames: [String: Set<String>] = [
        "java": [
            "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle",
            "settings.gradle.kts", "gradle.properties", "libs.versions.toml",
            "extensions.xml"
        ],
        "maven": ["pom.xml", "extensions.xml"],
        "gradle": [
            "build.gradle", "build.gradle.kts", "settings.gradle",
            "settings.gradle.kts", "gradle.properties", "libs.versions.toml"
        ],
        "npm": [
            "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
            "bun.lock", "bun.lockb"
        ],
        "node": [
            "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
            "bun.lock", "bun.lockb"
        ],
        "cargo": ["cargo.toml", "cargo.lock"],
        "rust": ["cargo.toml", "cargo.lock"],
        "python": [
            "pyproject.toml", "requirements.txt", "poetry.lock", "uv.lock",
            "pipfile", "pipfile.lock"
        ],
        "go": ["go.mod", "go.sum", "go.work", "go.work.sum"],
        "compose": ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    ]
}
