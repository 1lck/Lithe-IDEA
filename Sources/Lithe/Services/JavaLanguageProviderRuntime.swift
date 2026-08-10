import Foundation

/// Bridges the existing JDT LS client into the language-neutral lifecycle.
/// Java navigation keeps its mature protocol implementation while workspace
/// ownership and shutdown move to the shared provider manager.
@MainActor
final class JavaLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private let service: JavaLanguageService
    private let debugAdapterFactory: (@MainActor (URL) -> (any DebugAdapterSession)?)?
    private let debugAdapterAvailability: @MainActor () -> Bool
    private let debugAdapterUnavailableMessage: @MainActor () -> String?
    var supportsEditingSession: Bool { true }
    var supportsDebugAdapterSession: Bool {
        debugAdapterFactory != nil && debugAdapterAvailability()
    }
    var unavailableToolingMessage: String? { debugAdapterUnavailableMessage() }
    var declaredLanguageServerFeatures: LanguageServerFeatureSet { .standardEditing }

    init(
        service: JavaLanguageService,
        catalog: LanguageProviderCatalog = .standard,
        debugAdapterAvailability: @escaping @MainActor () -> Bool = { false },
        debugAdapterUnavailableMessage: @escaping @MainActor () -> String? = { nil },
        debugAdapterFactory: (@MainActor (URL) -> (any DebugAdapterSession)?)? = nil
    ) {
        precondition(
            catalog.descriptors.contains(where: { $0.id == "java" }),
            "The language provider catalog must contain Java"
        )
        descriptor = catalog.descriptors.first { $0.id == "java" }!
        self.service = service
        self.debugAdapterFactory = debugAdapterFactory
        self.debugAdapterAvailability = debugAdapterAvailability
        self.debugAdapterUnavailableMessage = debugAdapterUnavailableMessage
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? {
        JavaLanguageServerLifecycleSession(service: service)
    }

    func makeDebugAdapterSession() -> (any DebugAdapterSession)? {
        debugAdapterFactory?(URL(fileURLWithPath: "."))
    }

    func makeDebugAdapterSession(rootURL: URL) -> (any DebugAdapterSession)? {
        debugAdapterFactory?(rootURL.standardizedFileURL)
    }
}

@MainActor
private final class JavaLanguageServerLifecycleSession: LanguageServerEditingSession, LanguageServerFeatureReportingSession {
    private let service: JavaLanguageService
    private var documents: [URL: EditorDocument] = [:]
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)? {
        didSet { configureDiagnostics() }
    }
    private(set) var supportedFeatures: LanguageServerFeatureSet = .standardEditing
    var onSupportedFeaturesChange: ((LanguageServerFeatureSet) -> Void)?

    init(service: JavaLanguageService) {
        self.service = service
        service.onLanguageServerFeatures = { [weak self] features in
            self?.supportedFeatures = features
            self?.onSupportedFeaturesChange?(features)
        }
    }

    var isRunning: Bool { service.isStarting || service.isReady }
    var isReady: Bool { service.isReady }

    func start(rootURL: URL) throws {
        service.configureProjectRoot(rootURL)
        service.prepare(for: rootURL)
    }

    func stop() {
        documents = [:]
        service.onLanguageServerDiagnostics = nil
        service.onLanguageServerFeatures = nil
        service.stop()
    }

    func synchronizeDocument(url: URL, languageIdentifier: String, text: String) {
        let normalizedURL = url.standardizedFileURL
        let document: EditorDocument
        if let existing = documents[normalizedURL] {
            existing.text = text
            document = existing
        } else {
            document = EditorDocument(url: normalizedURL, text: text, modificationDate: nil)
            documents[normalizedURL] = document
        }
        service.update(document)
    }

    func closeDocument(url: URL) {
        let normalizedURL = url.standardizedFileURL
        guard let document = documents.removeValue(forKey: normalizedURL) else { return }
        service.close(document)
    }

    func locations(
        method: String,
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) {
        guard let document = documents[documentURL.standardizedFileURL] else {
            completion(.failure(JavaLanguageService.ServiceError.invalidResponse))
            return
        }
        service.locations(
            method: method,
            document: document,
            line: position.line,
            utf16Column: position.utf16Column
        ) { result in
            completion(result.map { locations in
                locations.map { location in
                    let point = LanguageServerPosition(
                        line: location.line,
                        utf16Column: location.utf16Column
                    )
                    return LanguageServerLocation(
                        url: location.url,
                        range: LanguageServerRange(start: point, end: point),
                        isReadOnly: location.isReadOnly,
                        displayPath: location.displayPath
                    )
                }
            })
        }
    }

    func hover(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) {
        request(
            method: "textDocument/hover",
            documentURL: documentURL,
            parameters: positionParameters(documentURL, position)
        ) { completion($0.map(LanguageServerResponseParser.hover)) }
    }

    func completions(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) {
        var parameters = positionParameters(documentURL, position)
        parameters["context"] = ["triggerKind": 1]
        request(method: "textDocument/completion", documentURL: documentURL, parameters: parameters) {
            completion($0.map(LanguageServerResponseParser.completionItems))
        }
    }

    func rename(
        documentURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) {
        var parameters = positionParameters(documentURL, position)
        parameters["newName"] = newName
        request(method: "textDocument/rename", documentURL: documentURL, parameters: parameters) {
            completion($0.map(LanguageServerResponseParser.workspaceEdit))
        }
    }

    func formatting(
        documentURL: URL,
        options: [String: Any],
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) {
        request(
            method: "textDocument/formatting",
            documentURL: documentURL,
            parameters: ["textDocument": ["uri": documentURL.standardizedFileURL.absoluteString], "options": options]
        ) { completion($0.map(LanguageServerResponseParser.textEdits)) }
    }

    func codeActions(
        documentURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) {
        let parameters: [String: Any] = [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "range": Self.foundationRange(range),
            "context": [
                "diagnostics": diagnostics.map(Self.foundationDiagnostic),
                "only": ["quickfix", "refactor"]
            ]
        ]
        request(method: "textDocument/codeAction", documentURL: documentURL, parameters: parameters) {
            completion($0.map(LanguageServerResponseParser.codeActions))
        }
    }

    func execute(
        command: LanguageServerCommand,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        service.executeLanguageServerCommand(command, completion: completion)
    }

    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) {
        service.languageServerRequest(
            method: "completionItem/resolve",
            parameters: LanguageServerResponseParser.foundationCompletionItem(item)
        ) { result in
            completion(result.flatMap { value in
                guard let item = LanguageServerResponseParser.completionItem(value) else {
                    return .failure(JavaLanguageService.ServiceError.invalidResponse)
                }
                return .success(item)
            })
        }
    }

    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) {
        service.languageServerRequest(
            method: "codeAction/resolve",
            parameters: LanguageServerResponseParser.foundationCodeAction(action)
        ) { result in
            completion(result.flatMap { value in
                guard let action = LanguageServerResponseParser.codeAction(value) else {
                    return .failure(JavaLanguageService.ServiceError.invalidResponse)
                }
                return .success(action)
            })
        }
    }

    private func request(
        method: String,
        documentURL: URL,
        parameters: [String: Any],
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        guard let document = documents[documentURL.standardizedFileURL] else {
            completion(.failure(JavaLanguageService.ServiceError.invalidResponse))
            return
        }
        service.languageServerRequest(
            method: method,
            document: document,
            parameters: parameters,
            completion: completion
        )
    }

    private func positionParameters(
        _ documentURL: URL,
        _ position: LanguageServerPosition
    ) -> [String: Any] {
        [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.utf16Column]
        ]
    }

    private func configureDiagnostics() {
        service.onLanguageServerDiagnostics = { [weak self] url, diagnostics in
            self?.onDiagnostics?(url, diagnostics.map {
                LanguageServerDiagnostic(
                    range: LanguageServerRange(
                        start: LanguageServerPosition(line: $0.line, utf16Column: $0.utf16Column),
                        end: LanguageServerPosition(line: $0.endLine, utf16Column: $0.endUTF16Column)
                    ),
                    severity: $0.severity.rawValue,
                    message: $0.message,
                    source: $0.source,
                    code: $0.code
                )
            })
        }
    }

    private static func foundationRange(_ range: LanguageServerRange) -> [String: Any] {
        [
            "start": ["line": range.start.line, "character": range.start.utf16Column],
            "end": ["line": range.end.line, "character": range.end.utf16Column]
        ]
    }

    private static func foundationDiagnostic(_ diagnostic: LanguageServerDiagnostic) -> [String: Any] {
        var value: [String: Any] = ["range": foundationRange(diagnostic.range), "message": diagnostic.message]
        if let severity = diagnostic.severity { value["severity"] = severity }
        if let source = diagnostic.source { value["source"] = source }
        if let code = diagnostic.code { value["code"] = code }
        return value
    }
}
