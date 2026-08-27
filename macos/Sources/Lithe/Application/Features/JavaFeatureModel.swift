import Combine
import Foundation
import LitheGitModule

@MainActor
final class JavaLanguageServerPreparationOwner {
    let workspaceURL: URL
    var operationID: UUID
    var task: Task<Void, Never>?

    init(workspaceURL: URL, operationID: UUID) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.operationID = operationID
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

enum JavaLanguageServerActivationReadiness {
    case ready
    case preparing
}

enum JavaLanguageServerPreparationFailure {
    case failed(message: String?)
    case timedOut(message: String?)

    var message: String? {
        switch self {
        case .failed(let message), .timedOut(let message): message
        }
    }
}

@MainActor
enum JavaLanguageServerWorkspaceState {
    case idle
    case preparing(owner: JavaLanguageServerPreparationOwner)
    case ready(workspaceURL: URL, operationID: UUID)
    case failed(
        workspaceURL: URL,
        operationID: UUID,
        failure: JavaLanguageServerPreparationFailure
    )

    var operationID: UUID? {
        switch self {
        case .idle: nil
        case .preparing(let owner): owner.operationID
        case .ready(_, let operationID),
             .failed(_, let operationID, _): operationID
        }
    }

    func belongs(to workspaceURL: URL) -> Bool {
        switch self {
        case .idle: false
        case .preparing(let owner): owner.workspaceURL == workspaceURL.standardizedFileURL
        case .ready(let ownedURL, _),
             .failed(let ownedURL, _, _):
            ownedURL == workspaceURL.standardizedFileURL
        }
    }
}

/// Owns Java-only code vision, Maven integration, and legacy Java debug behavior.
/// Java LSP navigation and editing are delegated to the Rust host.
@MainActor
final class JavaFeatureModel: ObservableObject {
    @Published private(set) var javaCodeVisionHints: [URL: [JavaCodeVisionHint]] = [:]
    private(set) var languageServerWorkspaceState: JavaLanguageServerWorkspaceState = .idle

    private let operations: any JavaMavenOperations
    private var documentProvider: (@MainActor () -> EditorDocument?)?
    private var caretProvider: (@MainActor () -> EditorCaret?)?
    private var notify: (@MainActor (String) -> Void)?
    private var loadBlame: (@MainActor (URL) async -> [GitBlameLine])?
    private var mavenFeature: MavenFeatureModel?
    private var debugFeature: JavaDebugFeatureModel?

    init(operations: any JavaMavenOperations) {
        self.operations = operations
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
        mavenFeature: MavenFeatureModel?,
        debugFeature: JavaDebugFeatureModel?
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
        cancelLanguageServerPreparation()
        javaCodeVisionHints = [:]
    }

    func beginLanguageServerPreparation(
        workspaceURL: URL,
        operationID: UUID
    ) -> JavaLanguageServerPreparationOwner {
        let owner = JavaLanguageServerPreparationOwner(
            workspaceURL: workspaceURL,
            operationID: operationID
        )
        languageServerWorkspaceState = .preparing(owner: owner)
        return owner
    }

    @discardableResult
    func cancelLanguageServerPreparation() -> JavaLanguageServerPreparationOwner? {
        let owner: JavaLanguageServerPreparationOwner?
        if case .preparing(let currentOwner) = languageServerWorkspaceState {
            owner = currentOwner
        } else {
            owner = nil
        }
        languageServerWorkspaceState = .idle
        owner?.cancel()
        return owner
    }

    func ownsLanguageServerPreparation(
        workspaceURL: URL,
        operationID: UUID,
        activeWorkspaceURL: URL?
    ) -> Bool {
        guard case .preparing(let owner) = languageServerWorkspaceState else { return false }
        let normalizedURL = workspaceURL.standardizedFileURL
        return owner.operationID == operationID
            && owner.workspaceURL == normalizedURL
            && activeWorkspaceURL?.standardizedFileURL == normalizedURL
    }

    func markLanguageServerReady(workspaceURL: URL, operationID: UUID) {
        languageServerWorkspaceState = .ready(
            workspaceURL: workspaceURL.standardizedFileURL,
            operationID: operationID
        )
    }

    func markLanguageServerFailed(
        workspaceURL: URL,
        operationID: UUID,
        failure: JavaLanguageServerPreparationFailure
    ) {
        languageServerWorkspaceState = .failed(
            workspaceURL: workspaceURL.standardizedFileURL,
            operationID: operationID,
            failure: failure
        )
    }

    var languageServerOperationID: UUID? { languageServerWorkspaceState.operationID }

    func languageServerStateBelongs(to workspaceURL: URL) -> Bool {
        languageServerWorkspaceState.belongs(to: workspaceURL)
    }

    var isLanguageServerPreparing: Bool {
        if case .preparing = languageServerWorkspaceState { return true }
        return false
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
        guard documentProvider?()?.id == document.id else { return }
        javaCodeVisionHints[normalizedURL] = baseHints.map { hint in
            JavaCodeVisionHint(
                line: hint.line,
                utf16Column: hint.utf16Column,
                symbol: hint.symbol,
                usageCount: hint.usageCount,
                implementationCount: 0,
                authorName: hint.authorName
            )
        }
    }

    func structure(source: String, declarationSources: [String] = []) async -> JavaStructureResult? {
        let operations = self.operations
        return await Task.detached(priority: .utility) {
            operations.structure(source: source, declarationSources: declarationSources)
        }.value
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
