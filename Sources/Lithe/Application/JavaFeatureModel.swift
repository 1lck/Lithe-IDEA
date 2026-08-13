import Combine
import Foundation

/// Owns Java-only code vision, fallback inlay hints, Maven integration, and
/// legacy Java debug behavior. Java LSP navigation and editing are delegated
/// to the Rust host.
@MainActor
final class JavaFeatureModel: ObservableObject {
    @Published private(set) var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] = [:]
    @Published private(set) var javaInlayHints: [URL: [JavaInlayHint]] = [:]

    private let operations: any JavaMavenOperations
    private let workspaceOperations: any WorkspaceOperations
    private var documentProvider: (@MainActor () -> EditorDocument?)?
    private var caretProvider: (@MainActor () -> EditorCaret?)?
    private var notify: (@MainActor (String) -> Void)?
    private var loadBlame: (@MainActor (URL) async -> [GitBlameLine])?
    private var inlayHintTasks: [UUID: Task<Void, Never>] = [:]
    private var mavenFeature: MavenFeatureModel?
    private var debugFeature: JavaDebugFeatureModel?

    init(
        operations: any JavaMavenOperations,
        workspaceOperations: any WorkspaceOperations
    ) {
        self.operations = operations
        self.workspaceOperations = workspaceOperations
    }

    func configure(
        documentProvider: @escaping @MainActor () -> EditorDocument?,
        caretProvider: @escaping @MainActor () -> EditorCaret?,
        notify: @escaping @MainActor (String) -> Void,
        loadBlame: @escaping @MainActor (URL) async -> [GitBlameLine]
    ) {
        self.documentProvider = documentProvider
        self.caretProvider = caretProvider
        self.notify = notify
        self.loadBlame = loadBlame
    }

    func configureRuntime(
        mavenFeature: MavenFeatureModel,
        debugFeature: JavaDebugFeatureModel
    ) {
        self.mavenFeature = mavenFeature
        self.debugFeature = debugFeature
    }

    /// Explicit boundary for Java-only editor adornments and legacy services.
    /// Callers can avoid scheduling Java work for every supported language.
    func handles(fileURL: URL) -> Bool {
        fileURL.pathExtension.lowercased() == "java"
    }

    func supportsLegacyDebugging(fileURL: URL) -> Bool {
        handles(fileURL: fileURL)
    }

    func stop() {
        inlayHintTasks.values.forEach { $0.cancel() }
        inlayHintTasks.removeAll()
        javaCodeVisionHints = [:]
        javaInlayHints = [:]
    }

    @discardableResult
    func startDebugging(
        currentDocument: EditorDocument?,
        workspaceURL: URL?,
        runFeature: RunFeatureModel,
        saveDocument: @escaping @MainActor (EditorDocument) throws -> Void,
        recordSave: @escaping @MainActor (EditorDocument, String) -> Void
    ) -> Bool {
        guard let debugFeature else { return false }
        if debugFeature.targetKind != .remote, let currentDocument, currentDocument.isDirty {
            do {
                let previousText = currentDocument.savedText
                try saveDocument(currentDocument)
                recordSave(currentDocument, previousText)
            } catch {
                notify?("Could not save \(currentDocument.url.lastPathComponent)")
                return false
            }
        }
        switch debugFeature.targetKind {
        case .currentFile:
            guard let currentDocument,
                  currentDocument.url.pathExtension.lowercased() == "java" else {
                notify?("Open a Java file before starting Debug")
                return false
            }
            debugFeature.start(
                fileURL: currentDocument.url,
                sourceText: currentDocument.text,
                projectURL: workspaceURL,
                options: runFeature.options(for: .currentFile)
            )
        case .runConfiguration:
            guard let configuration = runFeature.selectedConfiguration,
                  configuration.kind.isMavenBacked else {
                notify?("Select a Spring Boot or Maven Module configuration before starting Debug")
                return false
            }
            guard let workspaceURL, let mavenProject = mavenFeature?.project else {
                notify?("No Maven project is available for Debug")
                return false
            }
            debugFeature.startMaven(
                configuration: configuration,
                project: mavenProject,
                projectURL: workspaceURL,
                options: runFeature.options(for: configuration)
            )
        case .remote:
            debugFeature.attachRemote()
        }
        return true
    }

    func toggleDebugBreakpoint(
        at fileURL: URL,
        line: Int,
        documents: [EditorDocument]
    ) {
        guard let debugFeature,
              let document = documents.first(where: {
                  $0.url.standardizedFileURL == fileURL.standardizedFileURL
              }),
              document.url.pathExtension.lowercased() == "java",
              line > 0 else { return }
        let className = debugFeature.className(for: document.url, sourceText: document.text)
        debugFeature.toggleBreakpoint(fileURL: document.url, line: line, className: className)
    }

    func toggleDebugBreakpointAtCaret() {
        guard let document = documentProvider?(),
              let caret = caretProvider?(),
              document.url.standardizedFileURL == caret.url.standardizedFileURL,
              document.url.pathExtension.lowercased() == "java" else {
            notify?("Place the caret in a Java file to set a breakpoint")
            return
        }
        toggleDebugBreakpoint(at: document.url, line: caret.line + 1, documents: [document])
    }

    func close(_ document: EditorDocument) {
        javaCodeVisionHints[document.url.standardizedFileURL] = nil
        javaInlayHints[document.url.standardizedFileURL] = nil
    }

    func refreshCodeVision(
        for document: EditorDocument,
        projectFiles: [URL],
        workspaceRoot: URL
    ) async {
        let normalizedURL = document.url.standardizedFileURL
        guard normalizedURL.pathExtension.lowercased() == "java", !document.isReadOnly else { return }
        let blame = await loadBlame?(normalizedURL) ?? []
        let baseHints = await codeVision(
            for: normalizedURL,
            projectFiles: projectFiles,
            workspaceRoot: workspaceRoot,
            blameLines: blame
        )
        let candidates = structure(source: document.text)?.implementationMarkers ?? []
        let implementationCounts = candidates.reduce(into: [Int: Int]()) { counts, marker in
            counts[marker.line] = max(counts[marker.line] ?? 0, marker.implementationCount)
        }
        guard documentProvider?()?.id == document.id else { return }
        javaCodeVisionHints[normalizedURL] = baseHints.map { hint in
            JavaCodeVisionHint(
                line: hint.line,
                utf16Column: hint.utf16Column,
                symbol: hint.symbol,
                usageCount: hint.usageCount,
                implementationCount: implementationCounts[hint.line] ?? 0,
                authorName: hint.authorName
            )
        }
    }

    func refreshInlayHints(
        for document: EditorDocument,
        projectFiles: [URL],
        workspaceRoot: URL?
    ) {
        guard !document.isReadOnly,
              document.url.pathExtension.lowercased() == "java" else { return }
        inlayHintTasks[document.id]?.cancel()
        inlayHintTasks[document.id] = Task { @MainActor [weak self, weak document] in
            guard let self, let document else { return }
            await self.requestInlayHints(
                for: document,
                projectFiles: projectFiles,
                workspaceRoot: workspaceRoot
            )
            self.inlayHintTasks[document.id] = nil
        }
    }

    private func requestInlayHints(
        for document: EditorDocument,
        projectFiles: [URL],
        workspaceRoot: URL?
    ) async {
        guard !Task.isCancelled,
              documentProvider?()?.id == document.id else { return }
        await applyInlayFallback(
            for: document,
            projectFiles: projectFiles,
            workspaceRoot: workspaceRoot
        )
    }

    private func applyInlayFallback(
        for document: EditorDocument,
        projectFiles: [URL],
        workspaceRoot: URL?
    ) async {
        let currentText = document.text
        let sourcePaths = projectFiles.compactMap { file in
            workspaceRoot.flatMap { workspaceRelativePath(for: file, root: $0) }
        }
        let workspaceOperations = self.workspaceOperations
        let sources: [String]
        if let workspaceRoot {
            sources = await Task.detached(priority: .utility) {
                sourcePaths.compactMap { path in
                    workspaceOperations.readFile(at: workspaceRoot, relativePath: path)
                }
            }.value
        } else {
            sources = []
        }
        let fallback = structure(source: currentText, declarationSources: sources)?.inlayHints ?? []
        guard documentProvider?()?.id == document.id else { return }
        javaInlayHints[document.url.standardizedFileURL] = fallback
    }

    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func structure(source: String, declarationSources: [String] = []) -> JavaStructureResult? {
        operations.structure(source: source, declarationSources: declarationSources)
    }

    func codeVision(
        for fileURL: URL,
        projectFiles: [URL],
        workspaceRoot: URL,
        blameLines: [GitBlameLine]
    ) async -> [JavaCodeVisionHint] {
        await JavaCodeVisionService.hints(
            for: fileURL,
            projectFiles: projectFiles,
            workspaceRoot: workspaceRoot,
            blameLines: blameLines,
            operations: operations
        )
    }

}
