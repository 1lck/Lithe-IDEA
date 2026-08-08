import Combine
import Foundation

/// Owns Java language-server lifecycle, diagnostics, and navigation protocol
/// state. Opening files and presenting the result panel remain UI callbacks.
@MainActor
final class JavaFeatureModel: ObservableObject {
    @Published private(set) var javaNavigationLocations: [JavaNavigationLocation] = []
    @Published private(set) var javaNavigationResultKind = JavaNavigationResultKind.references
    @Published private(set) var isLoadingJavaNavigation = false
    @Published private(set) var javaDiagnostics: [URL: [JavaDiagnostic]] = [:]
    @Published private(set) var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] = [:]
    @Published private(set) var javaInlayHints: [URL: [JavaInlayHint]] = [:]

    private let service: JavaLanguageService
    private let markerService: JavaImplementationMarkerService
    private let operations: any JavaMavenOperations
    private let workspaceOperations: any WorkspaceOperations
    private var documentProvider: (@MainActor () -> EditorDocument?)?
    private var caretProvider: (@MainActor () -> EditorCaret?)?
    private var notify: (@MainActor (String) -> Void)?
    private var navigateToLocation: (@MainActor (JavaNavigationLocation) -> Void)?
    private var presentResults: (@MainActor (JavaNavigationResultKind) -> Void)?
    private var loadBlame: (@MainActor (URL) async -> [GitBlameLine])?
    private var inlayHintTasks: [UUID: Task<Void, Never>] = [:]
    private var mavenFeature: MavenFeatureModel?
    private var runFeature: JavaRunFeatureModel?
    private var debugFeature: JavaDebugFeatureModel?

    init(
        service: JavaLanguageService,
        markerService: JavaImplementationMarkerService,
        operations: any JavaMavenOperations,
        workspaceOperations: any WorkspaceOperations
    ) {
        self.service = service
        self.markerService = markerService
        self.operations = operations
        self.workspaceOperations = workspaceOperations
        service.onDiagnostics = { [weak self] fileURL, diagnostics in
            self?.javaDiagnostics[fileURL.standardizedFileURL] = diagnostics
        }
    }

    func configure(
        documentProvider: @escaping @MainActor () -> EditorDocument?,
        caretProvider: @escaping @MainActor () -> EditorCaret?,
        notify: @escaping @MainActor (String) -> Void,
        navigateToLocation: @escaping @MainActor (JavaNavigationLocation) -> Void,
        presentResults: @escaping @MainActor (JavaNavigationResultKind) -> Void,
        loadBlame: @escaping @MainActor (URL) async -> [GitBlameLine]
    ) {
        self.documentProvider = documentProvider
        self.caretProvider = caretProvider
        self.notify = notify
        self.navigateToLocation = navigateToLocation
        self.presentResults = presentResults
        self.loadBlame = loadBlame
    }

    func configureRuntime(
        mavenFeature: MavenFeatureModel,
        runFeature: JavaRunFeatureModel,
        debugFeature: JavaDebugFeatureModel
    ) {
        self.mavenFeature = mavenFeature
        self.runFeature = runFeature
        self.debugFeature = debugFeature
    }

    func prepareProject(at workspaceURL: URL, files: [URL]) {
        guard files.contains(where: { $0.pathExtension.lowercased() == "java" }) else { return }
        service.prepare(for: workspaceURL)
    }

    func loadProject(at workspaceURL: URL, files: [URL]) async {
        guard let mavenFeature, let runFeature else { return }
        await mavenFeature.loadProject(at: workspaceURL)
        await runFeature.loadProject(
            at: workspaceURL,
            files: files,
            mavenProject: mavenFeature.project
        )
    }

    var statusMessage: String { service.statusMessage }

    func configureProjectRoot(_ url: URL) {
        service.configureProjectRoot(url)
    }

    func prepare(for rootURL: URL) {
        service.prepare(for: rootURL)
    }

    func stop() {
        inlayHintTasks.values.forEach { $0.cancel() }
        inlayHintTasks.removeAll()
        service.stop()
        javaNavigationLocations = []
        javaNavigationResultKind = .references
        isLoadingJavaNavigation = false
        javaDiagnostics = [:]
        javaCodeVisionHints = [:]
        javaInlayHints = [:]
    }

    @discardableResult
    func runSelectedConfiguration(
        currentDocument: EditorDocument?,
        saveDocument: @escaping @MainActor (EditorDocument) throws -> Void,
        recordSave: @escaping @MainActor (EditorDocument, String) -> Void
    ) -> Bool {
        guard let runFeature, let configuration = runFeature.selectedConfiguration else { return false }
        if configuration.kind == .currentFile,
           let currentDocument,
           currentDocument.isDirty {
            do {
                let previousText = currentDocument.savedText
                try saveDocument(currentDocument)
                recordSave(currentDocument, previousText)
            } catch {
                notify?("Could not save \(currentDocument.url.lastPathComponent)")
                return false
            }
        }
        runFeature.runSelected(currentFileURL: currentDocument?.url)
        return true
    }

    @discardableResult
    func startDebugging(
        currentDocument: EditorDocument?,
        workspaceURL: URL?,
        saveDocument: @escaping @MainActor (EditorDocument) throws -> Void,
        recordSave: @escaping @MainActor (EditorDocument, String) -> Void
    ) -> Bool {
        guard let debugFeature, let runFeature else { return false }
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

    func update(_ document: EditorDocument) {
        service.update(document)
    }

    func close(_ document: EditorDocument) {
        service.close(document)
        javaDiagnostics[document.url.standardizedFileURL] = nil
        javaCodeVisionHints[document.url.standardizedFileURL] = nil
        javaInlayHints[document.url.standardizedFileURL] = nil
        markerService.invalidate(document)
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
        let markers = await implementationMarkers(for: document, candidates: candidates)
        let implementationCounts = Dictionary(
            uniqueKeysWithValues: markers.map { ($0.line, $0.implementationCount) }
        )
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
                workspaceRoot: workspaceRoot,
                attempt: 0
            )
            self.inlayHintTasks[document.id] = nil
        }
    }

    private func requestInlayHints(
        for document: EditorDocument,
        projectFiles: [URL],
        workspaceRoot: URL?,
        attempt: Int
    ) async {
        guard !Task.isCancelled,
              documentProvider?()?.id == document.id else { return }
        await withCheckedContinuation { continuation in
            inlayHints(for: document) { [weak self] result in
                guard let self else {
                    continuation.resume()
                    return
                }
                if case .success(let hints) = result {
                    self.javaInlayHints[document.url.standardizedFileURL] = hints
                    Task { @MainActor [weak self, weak document] in
                        guard let self, let document else {
                            continuation.resume()
                            return
                        }
                        if hints.isEmpty, attempt < 3 {
                            try? await Task.sleep(for: .milliseconds(900 * (attempt + 1)))
                            guard !Task.isCancelled else {
                                continuation.resume()
                                return
                            }
                            await self.requestInlayHints(
                                for: document,
                                projectFiles: projectFiles,
                                workspaceRoot: workspaceRoot,
                                attempt: attempt + 1
                            )
                        } else if hints.isEmpty {
                            await self.applyInlayFallback(
                                for: document,
                                projectFiles: projectFiles,
                                workspaceRoot: workspaceRoot
                            )
                        }
                        continuation.resume()
                    }
                } else {
                    continuation.resume()
                }
            }
        }
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

    func implementationMarkers(
        for document: EditorDocument,
        candidates: [JavaImplementationMarker]
    ) async -> [JavaImplementationMarker] {
        await markerService.markers(for: document, candidates: candidates)
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

    func inlayHints(
        for document: EditorDocument,
        completion: @escaping (Result<[JavaInlayHint], Error>) -> Void
    ) {
        service.inlayHints(document: document, completion: completion)
    }

    func clearNavigation() {
        javaNavigationLocations = []
        isLoadingJavaNavigation = false
    }

    func goToDefinition() {
        performNavigation(method: "textDocument/definition", kind: .definitions)
    }

    func goToUsages() {
        performNavigation(
            method: "textDocument/references",
            kind: .references,
            navigateToSingleReference: true
        )
    }

    func goToImplementation() {
        performNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func findJavaReferences() {
        performNavigation(method: "textDocument/references", kind: .references)
    }

    func findJavaImplementations() {
        performNavigation(method: "textDocument/implementation", kind: .implementations)
    }

    func navigateToDefinition(fallbackToImplementationsIfSelf: Bool) {
        performNavigation(
            method: "textDocument/definition",
            kind: .definitions,
            fallbackToImplementationsIfSelf: fallbackToImplementationsIfSelf
        )
    }

    private func performNavigation(
        method: String,
        kind: JavaNavigationResultKind,
        fallbackToImplementationsIfSelf: Bool = false,
        navigateToSingleReference: Bool = false
    ) {
        guard !isLoadingJavaNavigation,
              let document = documentProvider?(),
              let caret = caretProvider?(),
              caret.url.standardizedFileURL == document.url.standardizedFileURL else {
            notify?("Place the caret on a Java symbol first")
            return
        }
        guard document.url.pathExtension.lowercased() == "java" else {
            notify?("Java navigation is available for .java files")
            return
        }

        isLoadingJavaNavigation = true
        notify?("Starting Java navigation...")
        service.locations(
            method: method,
            document: document,
            line: caret.line,
            utf16Column: caret.utf16Column
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingJavaNavigation = false
            switch result {
            case .failure(let error):
                self.notify?(error.localizedDescription)
            case .success(let locations):
                if fallbackToImplementationsIfSelf,
                   kind == .definitions,
                   locations.count == 1,
                   locations[0].url.standardizedFileURL == document.url.standardizedFileURL {
                    self.isLoadingJavaNavigation = true
                    self.service.locations(
                        method: "textDocument/implementation",
                        document: document,
                        line: caret.line,
                        utf16Column: caret.utf16Column
                    ) { [weak self] implementationResult in
                        guard let self else { return }
                        self.isLoadingJavaNavigation = false
                        if case .success(let implementations) = implementationResult,
                           !implementations.isEmpty {
                            self.present(implementations, kind: .implementations)
                        } else {
                            self.present(locations, kind: .definitions)
                        }
                    }
                    return
                }
                self.present(
                    locations,
                    kind: kind,
                    navigateToSingleReference: navigateToSingleReference
                )
            }
        }
    }

    private func present(
        _ locations: [JavaNavigationLocation],
        kind: JavaNavigationResultKind,
        navigateToSingleReference: Bool = false
    ) {
        guard !locations.isEmpty else {
            let message: String
            switch kind {
            case .definitions: message = "Definition not found"
            case .references: message = "No usages found"
            case .implementations: message = "No implementations found"
            }
            notify?(message)
            return
        }

        if (kind != .references || navigateToSingleReference),
           locations.count == 1,
           let location = locations.first {
            navigateToLocation?(location)
            let message: String
            switch kind {
            case .definitions: message = "Opened definition"
            case .references: message = "Opened call site"
            case .implementations: message = "Opened implementation"
            }
            notify?(message)
        } else {
            javaNavigationResultKind = kind
            javaNavigationLocations = locations
            presentResults?(kind)
        }
    }
}
