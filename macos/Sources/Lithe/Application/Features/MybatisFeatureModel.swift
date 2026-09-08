import Combine
import Foundation
import LitheCoreContracts

/// Owns the workspace-level MyBatis mapper/XML projection produced by Rust Core.
@MainActor
final class MybatisFeatureModel: ObservableObject {
    @Published private(set) var statements: [MybatisStatement] = []
    @Published private(set) var isIndexing = false

    private let operations: any JavaMavenOperations
    private var generation = UUID()
    private var reloadTask: Task<Void, Never>?

    init(operations: any JavaMavenOperations) {
        self.operations = operations
    }

    func load(
        workspaceURL: URL,
        files: [URL],
        textOverrides: [URL: String] = [:]
    ) async {
        generation = UUID()
        let currentGeneration = generation
        isIndexing = true
        let operations = self.operations
        let result = await Task.detached(priority: .utility) {
            operations.mybatisIndex(
                at: workspaceURL,
                files: files,
                textOverrides: textOverrides
            )
        }.value ?? .empty
        guard generation == currentGeneration else { return }
        statements = result.statements
        isIndexing = false
    }

    /// Starts a workspace index without making the caller wait for it. Opening a
    /// project must not block run state behind mapper indexing.
    func scheduleLoad(
        workspaceURL: URL,
        files: [URL],
        textOverrides: [URL: String] = [:]
    ) {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.load(
                workspaceURL: workspaceURL,
                files: files,
                textOverrides: textOverrides
            )
        }
    }

    func reset() {
        reloadTask?.cancel()
        reloadTask = nil
        generation = UUID()
        statements = []
        isIndexing = false
    }

    func scheduleReload(
        changedDocument: EditorDocument,
        workspaceURL: URL,
        files: [URL],
        openDocuments: [EditorDocument]
    ) {
        let ext = changedDocument.url.pathExtension.lowercased()
        guard ext == "java" || ext == "xml" else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let overrides = Dictionary(uniqueKeysWithValues: openDocuments.map {
                ($0.url.standardizedFileURL, $0.text)
            })
            await self.load(
                workspaceURL: workspaceURL,
                files: files,
                textOverrides: overrides
            )
        }
    }

    func handles(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        return statements.contains {
            $0.javaURL.standardizedFileURL == normalized
                || $0.xmlURL.standardizedFileURL == normalized
        }
    }

    func navigationLocations(for url: URL, line: Int) -> [LanguageServerLocation] {
        let normalized = url.standardizedFileURL
        let caretLine = line + 1
        let fromJava = statements.compactMap { statement -> LanguageServerLocation? in
            guard statement.javaURL.standardizedFileURL == normalized,
                  caretLine >= statement.javaLine,
                  caretLine <= statement.javaEndLine else { return nil }
            return location(statement.xmlURL, line: statement.xmlLine, column: statement.xmlColumn)
        }
        if !fromJava.isEmpty { return unique(fromJava) }
        return unique(statements.compactMap { statement in
            guard statement.xmlURL.standardizedFileURL == normalized,
                  statement.xmlLine == caretLine else { return nil }
            return location(statement.javaURL, line: statement.javaLine, column: statement.javaColumn)
        })
    }

    private func location(_ url: URL, line: Int, column: Int) -> LanguageServerLocation {
        let position = LanguageServerPosition(
            line: max(0, line - 1),
            utf16Column: max(0, column - 1)
        )
        return LanguageServerLocation(
            url: url,
            range: LanguageServerRange(start: position, end: position)
        )
    }

    private func unique(_ locations: [LanguageServerLocation]) -> [LanguageServerLocation] {
        var seen = Set<String>()
        return locations.filter { location in
            let key = "\(location.url.standardizedFileURL.path):\(location.range.start.line):\(location.range.start.utf16Column)"
            return seen.insert(key).inserted
        }
    }
}
