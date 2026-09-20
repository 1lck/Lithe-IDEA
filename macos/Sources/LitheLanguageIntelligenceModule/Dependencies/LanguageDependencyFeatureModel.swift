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
        sessions: LanguageToolingSessionManager
    ) async throws -> DependencyGraph
}

@MainActor
package final class LanguageDependencyFeatureModel: ObservableObject {
    @Published package private(set) var languages: [LanguageDependencyDescriptor] = []
    @Published package private(set) var revision = 0

    private let sessions: LanguageToolingSessionManager
    private let providers: [any LanguageDependencyProviding]
    private var workspaceURL: URL?
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
                || forceRefresh else { return }
        self.workspaceURL = normalizedWorkspace
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
        let graph = try await provider.resolve(workspaceURL: workspaceURL, sessions: sessions)
        try Task.checkCancellation()
        guard generation == workspaceGeneration else { throw CancellationError() }
        return graph
    }

    package func invalidate() {
        workspaceGeneration = UUID()
        revision &+= 1
    }

    package func reset() {
        workspaceURL = nil
        languages = []
        workspaceGeneration = UUID()
        revision &+= 1
    }
}

@MainActor
private final class JavaLanguageDependencyProvider: LanguageDependencyProviding {
    let providerID = "java"
    let systemImage = "cup.and.heat.waves"

    private let sourcePathsKey = "org.eclipse.jdt.ls.core.sourcePaths"
    private let outputPathKey = "org.eclipse.jdt.ls.core.outputPath"
    private let referencedLibrariesKey = "org.eclipse.jdt.ls.core.referencedLibraries"

    func resolve(
        workspaceURL: URL,
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
        let keys = [sourcePathsKey, outputPathKey, referencedLibrariesKey]

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
            sources.append(contentsOf: urls(values[sourcePathsKey]))
            outputs.append(contentsOf: urls(values[outputPathKey]))
            libraries.append(contentsOf: urls(values[referencedLibrariesKey]))
        }

        let root = DependencyNode(
            id: "language:java",
            title: "Java",
            kind: .group,
            source: .generated,
            children: [
                group(id: "sources", title: "Source Code", urls: sources, kind: .directory),
                group(id: "outputs", title: "Build Outputs", urls: outputs, kind: .directory),
                group(id: "dependencies", title: "Dependencies", urls: libraries, kind: .packageNode),
            ]
        )
        return DependencyGraph(providerID: providerID, roots: [root])
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

    private func fileURL(_ value: String) -> URL {
        if let url = URL(string: value), url.isFileURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func group(
        id: String,
        title: String,
        urls: [URL],
        kind: DependencyNodeKind
    ) -> DependencyNode {
        var seen: Set<String> = []
        let nodes = urls
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { url in
                DependencyNode(
                    id: url.path,
                    title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                    subtitle: url.path,
                    kind: kind,
                    source: kind == .directory ? .directory(url) : .archive(url)
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
}
