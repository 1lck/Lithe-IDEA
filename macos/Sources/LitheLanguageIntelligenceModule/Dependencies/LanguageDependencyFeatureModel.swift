import Foundation
import LitheCoreContracts

// Note: 依赖事实的语言服务器 ownership 见
// .agents/notes/implemented/architecture/2026-09-18-workspace-dependency-browser.md
/// A language-owned dependency projection. Implementations must ask their
/// language server for project facts instead of scanning the workspace or run
/// configurations.
@MainActor
package protocol LanguageDependencyProviding: AnyObject {
    var providerID: String { get }
    var systemImage: String { get }

    func resolve(
        workspaceURL: URL,
        files: [URL],
        sessions: LanguageToolingSessionManager
    ) async throws -> DependencyGraph

    func resolveChildren(
        for node: DependencyNode,
        workspaceURL: URL,
        sessions: LanguageToolingSessionManager
    ) async throws -> [DependencyNode]
}

@MainActor
package final class LanguageDependencyFeatureModel: ObservableObject {
    @Published package private(set) var languages: [LanguageDependencyDescriptor] = []
    @Published package private(set) var revision = 0

    private let sessions: LanguageToolingSessionManager
    private let providers: [any LanguageDependencyProviding]
    private var workspaceURL: URL?
    private var workspaceFiles: [URL] = []
    private var workspaceGeneration = UUID()

    package init(
        sessions: LanguageToolingSessionManager,
        providers: [any LanguageDependencyProviding] = [JavaLanguageDependencyProvider()]
    ) {
        self.sessions = sessions
        self.providers = providers
    }

    /// Selects dependency contributors from the workspace file inventory. This
    /// starts no server; resolving an expanded language remains lazy.
    package func prepare(workspaceURL: URL, files: [URL], forceRefresh: Bool = false) {
        let normalizedWorkspace = workspaceURL.standardizedFileURL
        let normalizedFiles = Self.normalizedFiles(files)
        let available = providers.compactMap { provider -> LanguageDependencyDescriptor? in
            guard let language = sessions.catalogSnapshot.descriptors.first(where: {
                $0.id == provider.providerID
            }), language.capabilities.contains(.languageServer),
               files.contains(where: language.handles(fileURL:)) else { return nil }
            return LanguageDependencyDescriptor(
                id: language.id,
                displayName: language.displayName,
                providerID: language.id,
                systemImage: provider.systemImage
            )
        }
        .sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }

        guard self.workspaceURL != normalizedWorkspace
                || languages != available
                || workspaceFiles != normalizedFiles
                || forceRefresh else { return }
        self.workspaceURL = normalizedWorkspace
        workspaceFiles = normalizedFiles
        languages = available
        workspaceGeneration = UUID()
        revision &+= 1
    }

    package func resolve(providerID: String) async throws -> DependencyGraph? {
        guard let workspaceURL,
              languages.contains(where: { $0.providerID == providerID }),
              let provider = providers.first(where: { $0.providerID == providerID }) else {
            return nil
        }
        let generation = workspaceGeneration
        let graph = try await provider.resolve(
            workspaceURL: workspaceURL,
            files: workspaceFiles,
            sessions: sessions
        )
        try Task.checkCancellation()
        guard generation == workspaceGeneration else { throw CancellationError() }
        return graph
    }

    package func resolveChildren(
        providerID: String,
        node: DependencyNode
    ) async throws -> [DependencyNode]? {
        guard let workspaceURL,
              languages.contains(where: { $0.providerID == providerID }),
              let provider = providers.first(where: { $0.providerID == providerID }) else {
            return nil
        }
        let generation = workspaceGeneration
        let children = try await provider.resolveChildren(
            for: node,
            workspaceURL: workspaceURL,
            sessions: sessions
        )
        try Task.checkCancellation()
        guard generation == workspaceGeneration else { throw CancellationError() }
        return children
    }

    package func invalidate() {
        workspaceGeneration = UUID()
        revision &+= 1
    }

    package func reset() {
        workspaceURL = nil
        workspaceFiles = []
        languages = []
        workspaceGeneration = UUID()
        revision &+= 1
    }

    private static func normalizedFiles(_ files: [URL]) -> [URL] {
        var seen: Set<String> = []
        return files
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

@MainActor
private final class JavaLanguageDependencyProvider: LanguageDependencyProviding {
    let providerID = "java"
    let systemImage = "cup.and.heat.waves"

    private let sourcePathsKey = "org.eclipse.jdt.ls.core.sourcePaths"
    private let outputPathKey = "org.eclipse.jdt.ls.core.outputPath"
    private let referencedLibrariesKey = "org.eclipse.jdt.ls.core.referencedLibraries"
    private let classpathEntriesKey = "org.eclipse.jdt.ls.core.classpathEntries"

    func resolve(
        workspaceURL: URL,
        files: [URL],
        sessions: LanguageToolingSessionManager
    ) async throws -> DependencyGraph {
        let projectsValue = try await sessions.executeDependencyCommand(
            providerID: providerID,
            commandID: "java.project.getAll",
            arguments: [],
            rootURL: workspaceURL
        )
        guard case .array(let rawProjects) = projectsValue else {
            throw LanguageToolingSessionError.toolingUnavailable(
                "The Java language service returned an invalid project list."
            )
        }

        let projectURIs = rawProjects.compactMap { value -> String? in
            guard case .string(let uri) = value, !uri.isEmpty else { return nil }
            return uri
        }.sorted()
        var sources: [URL] = []
        var outputs: [URL] = []
        var libraries: [URL] = []
        let keys = [
            sourcePathsKey,
            outputPathKey,
            referencedLibrariesKey,
            classpathEntriesKey,
        ]

        for projectURI in projectURIs {
            try Task.checkCancellation()
            let settings = try await sessions.executeDependencyCommand(
                providerID: providerID,
                commandID: "java.project.getSettings",
                arguments: [
                    .string(projectURI),
                    .array(keys.map(ToolingJSONValue.string)),
                ],
                rootURL: workspaceURL
            )
            guard case .object(let values) = settings else {
                throw LanguageToolingSessionError.toolingUnavailable(
                    "The Java language service returned invalid project settings."
                )
            }
            let projectSources = urls(values[sourcePathsKey])
            let projectOutputs = urls(values[outputPathKey])
            sources.append(contentsOf: projectSources)
            outputs.append(contentsOf: projectOutputs)
            libraries.append(contentsOf: urls(values[referencedLibrariesKey]))
            libraries.append(contentsOf: classpathURLs(values[classpathEntriesKey]))
        }

        let nonDependencyPaths = Set((sources + outputs).map { $0.standardizedFileURL.path })
        libraries.removeAll { nonDependencyPaths.contains($0.standardizedFileURL.path) }

        let root = DependencyNode(
            id: "language:java",
            title: "Java",
            kind: .group,
            source: .generated,
            children: [
                group(
                    id: "sources",
                    title: "Source Code",
                    urls: sources,
                    kind: .directory,
                    workspaceFiles: files
                ),
                group(id: "outputs", title: "Build Outputs", urls: outputs, kind: .directory),
                group(id: "dependencies", title: "Dependencies", urls: libraries, kind: .packageNode),
            ]
        )
        return DependencyGraph(providerID: providerID, roots: [root])
    }

    func resolveChildren(
        for node: DependencyNode,
        workspaceURL: URL,
        sessions: LanguageToolingSessionManager
    ) async throws -> [DependencyNode] {
        guard case .archive(let archiveURL) = node.source else { return [] }
        let symbols = try await sessions.workspaceSymbols(
            providerID: providerID,
            query: "*",
            rootURL: workspaceURL
        )
        let matchingSymbols = symbols
            .filter { $0.url.scheme?.lowercased() == "jdt" }
            .filter { Self.symbolBelongsToArchive($0.url, archiveURL: archiveURL) }
            .sorted {
                let lhs = (($0.containerName ?? "") + "." + $0.name)
                let rhs = (($1.containerName ?? "") + "." + $1.name)
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        // `workspace/symbol` has no standard max-results parameter. Keep the
        // dependency browser responsive after the user explicitly expands a
        // library, while leaving the language server's index authoritative.
        return Self.classNodes(
            from: Array(matchingSymbols.prefix(500)),
            archiveURL: archiveURL
        )
    }

    private static func symbolBelongsToArchive(_ uri: URL, archiveURL: URL) -> Bool {
        let decoded = uri.absoluteString.removingPercentEncoding ?? uri.absoluteString
        let archiveName = archiveURL.lastPathComponent
        return decoded.localizedCaseInsensitiveContains(archiveName)
    }

    private static func classNodes(
        from symbols: [LanguageServerWorkspaceSymbol],
        archiveURL: URL
    ) -> [DependencyNode] {
        struct Entry {
            let symbol: LanguageServerWorkspaceSymbol
            let components: [String]
        }
        let entries = symbols.compactMap { symbol -> Entry? in
            let package = symbol.containerName?.split(separator: ".").map(String.init) ?? []
            guard !symbol.name.isEmpty else { return nil }
            return Entry(symbol: symbol, components: package + [symbol.name])
        }
        var children: [String: Set<String>] = [:]
        var symbolsByPath: [String: LanguageServerWorkspaceSymbol] = [:]
        for entry in entries {
            var parent = ""
            for component in entry.components {
                let path = parent.isEmpty ? component : parent + "/" + component
                children[parent, default: []].insert(path)
                parent = path
            }
            symbolsByPath[entry.components.joined(separator: "/")] = entry.symbol
        }

        func makeNode(_ path: String) -> DependencyNode {
            let childPaths = (children[path] ?? []).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            if let symbol = symbolsByPath[path] {
                return DependencyNode(
                    id: "dependency-symbol:\(archiveURL.path):\(symbol.url.absoluteString)",
                    title: symbol.name,
                    subtitle: symbol.url.absoluteString,
                    kind: .file,
                    source: .virtualDocument(symbol.url)
                )
            }
            return DependencyNode(
                id: "dependency-package:\(archiveURL.path):\(path)",
                title: path.split(separator: "/").last.map(String.init) ?? path,
                kind: .directory,
                source: .generated,
                children: childPaths.map(makeNode)
            )
        }

        return (children[""] ?? []).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map(makeNode)
    }

    private func urls(_ value: ToolingJSONValue?) -> [URL] {
        switch value {
        case .string(let path):
            return path.isEmpty ? [] : [fileURL(path)]
        case .array(let values):
            return values.compactMap { value in
                guard case .string(let path) = value, !path.isEmpty else { return nil }
                return fileURL(path)
            }
        default:
            return []
        }
    }

    private func classpathURLs(_ value: ToolingJSONValue?) -> [URL] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { value in
            guard case .object(let entry) = value,
                  case .string(let path)? = entry["path"],
                  !path.isEmpty else { return nil }
            return fileURL(path)
        }
    }

    private func fileURL(_ value: String) -> URL {
        if let url = URL(string: value), url.isFileURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func group(
        id: String,
        title: String,
        urls: [URL],
        kind: DependencyNodeKind,
        workspaceFiles: [URL] = []
    ) -> DependencyNode {
        var seen: Set<String> = []
        let nodes = urls
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { url in
                if kind == .directory {
                    return directoryNode(url, files: workspaceFiles)
                }
                return DependencyNode(
                    id: "dependency-path:\(url.path)",
                    title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                    subtitle: url.path,
                    kind: kind,
                    source: .archive(url)
                )
            }
        return DependencyNode(
            id: "language:java:\(id)",
            title: title,
            kind: .group,
            source: .generated,
            children: nodes
        )
    }

    private func directoryNode(_ root: URL, files: [URL]) -> DependencyNode {
        let normalizedRoot = root.standardizedFileURL
        let rootPath = normalizedRoot.path
        var childrenByParent: [String: Set<String>] = [:]
        var urlsByPath: [String: URL] = [:]

        for file in files.map(\.standardizedFileURL) {
            let path = file.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            var parentPath = rootPath
            for component in relativePath.split(separator: "/") {
                let childPath = parentPath + "/" + component
                childrenByParent[parentPath, default: []].insert(childPath)
                urlsByPath[childPath] = URL(fileURLWithPath: childPath)
                parentPath = childPath
            }
        }

        func makeNode(_ path: String) -> DependencyNode {
            let childPaths = (childrenByParent[path] ?? []).sorted { lhs, rhs in
                let lhsIsDirectory = childrenByParent[lhs] != nil
                let rhsIsDirectory = childrenByParent[rhs] != nil
                if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            let url = urlsByPath[path] ?? URL(fileURLWithPath: path)
            let isDirectory = !childPaths.isEmpty
            return DependencyNode(
                id: "source-path:\(path)",
                title: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                subtitle: url.path,
                kind: isDirectory ? .directory : .file,
                source: isDirectory ? .directory(url) : .file(url),
                children: childPaths.map(makeNode)
            )
        }

        return DependencyNode(
            id: "source-root:\(rootPath)",
            title: normalizedRoot.lastPathComponent.isEmpty ? rootPath : normalizedRoot.lastPathComponent,
            subtitle: rootPath,
            kind: .directory,
            source: .directory(normalizedRoot),
            children: (childrenByParent[rootPath] ?? [])
                .sorted { lhs, rhs in
                    let lhsIsDirectory = childrenByParent[lhs] != nil
                    let rhsIsDirectory = childrenByParent[rhs] != nil
                    if lhsIsDirectory != rhsIsDirectory { return lhsIsDirectory }
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                .map(makeNode)
        )
    }
}
