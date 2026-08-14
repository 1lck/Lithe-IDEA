import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A language-server session projected from the Rust runtime.
///
/// This type starts a session, publishes semantic requests, drains
/// `lsp.pollEvents`, and turns each event into the UI-facing callbacks and
/// completion closures the application already expects. The only state it keeps
/// is the opaque session ID, the last lifecycle state it observed, and the
/// closures waiting on opaque operation IDs.
@MainActor
package final class LanguageServerRuntimeSession: LanguageServerSession {
    /// How often the event queue is drained. Waiting on a completion is worth a
    /// tighter loop than sitting idle with nothing outstanding.
    private static let activePollNanoseconds: UInt64 = 10_000_000
    private static let idlePollNanoseconds: UInt64 = 50_000_000

    private let providerID: String
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let initializationOptions: ToolingJSONValue?
    private let runtimeExecutableURL: URL?
    private let cacheDirectoryURL: URL?
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID

    private var sessionID: String?
    private var pendingOperations: [String: PendingOperation] = [:]
    private var pollTask: Task<Void, Never>?
    private var state: LanguageServerSessionState = .stopped
    private var processID: Int32?

    package var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    package var onLog: ((LanguageServerLogLevel, String, String?) -> Void)?
    package var onStateChange: ((LanguageServerSessionState) -> Void)?
    package private(set) var features: LanguageServerFeatureSet = []
    package var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    package private(set) var serverInfo: LanguageServerInfo?
    package var onServerInfoChange: ((LanguageServerInfo?) -> Void)?

    package init(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        initializationOptions: ToolingJSONValue? = nil,
        runtimeExecutableURL: URL? = nil,
        cacheDirectoryURL: URL? = nil,
        initializeTimeout: TimeInterval = 60,
        requestTimeout: TimeInterval = 30,
        shutdownTimeout: TimeInterval = 2,
        core: any LanguageServerRuntimeCore,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence
    ) {
        self.providerID = providerID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.initializationOptions = initializationOptions
        self.runtimeExecutableURL = runtimeExecutableURL
        self.cacheDirectoryURL = cacheDirectoryURL
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.shutdownTimeout = shutdownTimeout
        self.core = core
        self.processRegistry = processRegistry
        self.moduleID = moduleID
    }

    /// Derived from the last lifecycle state Rust published: there is no local
    /// process handle to ask.
    package var isRunning: Bool {
        guard sessionID != nil else { return false }
        switch state {
        case .stopped, .failed:
            return false
        case .startingProcess, .initializing, .ready, .stopping:
            return true
        }
    }

    package func start(rootURL: URL) throws {
        guard sessionID == nil else { return }
        let normalizedRoot = rootURL.standardizedFileURL
        transition(to: .startingProcess)
        onLog?(
            .info,
            "Starting language server",
            ([executableURL.path] + arguments).joined(separator: " ")
        )
        switch core.startLanguageServer(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: normalizedRoot,
            workingDirectoryURL: normalizedRoot,
            initializationOptions: initializationOptions,
            runtimeExecutableURL: runtimeExecutableURL,
            cacheDirectoryURL: cacheDirectoryURL,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ) {
        case .success(let payload):
            sessionID = payload.sessionID
            processID = payload.processID
            if let processID {
                processRegistry?.registerLanguageServerProcess(pid: processID, moduleID: moduleID)
            }
            transition(to: Self.sessionState(payload.state) ?? .initializing)
            startPolling()
        case .failure(let error):
            let failure = LanguageServerRuntimeSessionError.startFailed(error.userMessage)
            let message = failure.localizedDescription
            transition(to: .failed(exitCode: nil, message: message))
            onLog?(.error, "Language server failed to start", message)
            throw failure
        }
    }

    package func synchronize(fileURL: URL, text: String, languageID: String) throws {
        guard let sessionID else { throw LanguageServerRuntimeSessionError.notReady }
        // Documents synced before initialize completes are held by the runtime and
        // opened once the server is ready, so there is nothing to queue here.
        if case .failure(let error) = core.syncLanguageServerDocument(
            sessionID: sessionID,
            fileURL: fileURL.standardizedFileURL,
            languageID: languageID,
            text: text
        ) {
            throw LanguageServerRuntimeSessionError.documentSyncFailed(error.userMessage)
        }
    }

    package func closeDocument(_ fileURL: URL) {
        guard let sessionID else { return }
        // The runtime owns which documents are open, so closing one it does not
        // know about is simply not its business.
        core.closeLanguageServerDocument(sessionID: sessionID, fileURL: fileURL.standardizedFileURL)
    }

    package func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try request(.completion, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: CompletionPayload.self)
            }.map { $0.makeModels() })
        }
    }

    package func hover(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try request(.hover, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: HoverPayload.self)
            }.map { $0.hover?.makeModel() })
        }
    }

    package func navigate(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard let operation = Self.navigationOperation(for: method) else {
            throw LanguageServerRuntimeSessionError.unsupportedNavigation(method)
        }
        try request(operation, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: NavigationPayload.self)
            }.map { $0.makeModels() })
        }
    }

    package func rename(
        fileURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        try request(.rename, fileURL: fileURL, position: position, newName: newName) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: WorkspaceEditPayload.self)
            }.map { $0.makeModel() })
        }
    }

    package func format(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        try request(.formatting, fileURL: fileURL) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: FormattingPayload.self)
            }.map { $0.makeModels() })
        }
    }

    package func codeActions(
        fileURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) throws {
        try request(
            .codeActions,
            fileURL: fileURL,
            range: range,
            diagnostics: diagnostics
        ) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: CodeActionsPayload.self)
            }.map { $0.makeModels() })
        }
    }

    package func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        try request(.resolveCompletion, fileURL: fileURL, completionItem: item) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: CompletionResolvePayload.self)
            }.map { $0.makeModel() })
        }
    }

    package func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        try request(.resolveCodeAction, fileURL: fileURL, codeAction: action) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: CodeActionResolvePayload.self)
            }.map { $0.makeModel() })
        }
    }

    package func execute(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        // A workspace command belongs to the server rather than to a document, so
        // it carries no document URI and is not gated on one being open.
        _ = fileURL
        try request(.executeCommand, fileURL: nil, command: command) { result in
            completion(result.map { _ in () })
        }
    }

    package func resolveVirtualDocument(
        uri: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) throws {
        try request(.virtualDocument, fileURL: nil, virtualURI: uri) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: VirtualDocumentPayload.self)
            }.map(\.text))
        }
    }

    package func stop() {
        guard let sessionID else {
            failPendingOperations(with: LanguageServerRuntimeSessionError.sessionStopped)
            transition(to: .stopped)
            return
        }
        // The runtime sends the shutdown, force-terminates on its own deadline,
        // and publishes the terminal transition. The poll loop releases the
        // session when that arrives, so nothing here waits on the server.
        core.stopLanguageServer(sessionID: sessionID)
        if isRunning { transition(to: .stopping) }
    }

    // MARK: - Requests

    private func request(
        _ operation: LanguageServerOperation,
        fileURL: URL?,
        virtualURI: String? = nil,
        position: LanguageServerPosition? = nil,
        newName: String? = nil,
        range: LanguageServerRange? = nil,
        diagnostics: [LanguageServerDiagnostic] = [],
        completionItem: LanguageServerCompletionItem? = nil,
        codeAction: LanguageServerCodeAction? = nil,
        command: LanguageServerCommand? = nil,
        completion: @escaping (Result<LanguageServerRuntimeEvent, Error>) -> Void
    ) throws {
        guard let sessionID, state == .ready else {
            throw LanguageServerRuntimeSessionError.notReady
        }
        switch core.requestLanguageServerOperation(
            sessionID: sessionID,
            operation: operation,
            fileURL: fileURL?.standardizedFileURL,
            virtualURI: virtualURI,
            position: position,
            newName: newName,
            range: range,
            diagnostics: diagnostics,
            completionItem: completionItem,
            codeAction: codeAction,
            command: command
        ) {
        case .success(let payload):
            pendingOperations[payload.operationID] = PendingOperation(completion: completion)
        case .failure(let error):
            throw LanguageServerRuntimeSessionError.requestRejected(error.userMessage)
        }
    }

    // MARK: - Event delivery

    private func startPolling() {
        pollTask?.cancel()
        // The task intentionally retains the session: it is what releases the
        // runtime session once the terminal transition arrives, and it has to
        // survive the manager dropping its own reference during shutdown.
        pollTask = Task { @MainActor [self] in
            while !Task.isCancelled {
                guard let sessionID else { return }
                let events = core.pollLanguageServerEvents(sessionID: sessionID)
                var reachedTerminalState = false
                for event in events where handle(event) {
                    reachedTerminalState = true
                }
                if reachedTerminalState {
                    releaseSession()
                    return
                }
                let isIdle = events.isEmpty && pendingOperations.isEmpty
                do {
                    try await Task.sleep(
                        nanoseconds: isIdle ? Self.idlePollNanoseconds : Self.activePollNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    /// Applies one runtime event and reports whether it ended the session.
    private func handle(_ event: LanguageServerRuntimeEvent) -> Bool {
        switch event.type {
        case "stateChanged":
            return handleStateChange(event)
        case "requestCompleted":
            guard let operationID = event.operationID,
                  let pending = pendingOperations.removeValue(forKey: operationID) else {
                return false
            }
            if let error = event.error {
                pending.completion(.failure(
                    LanguageServerRuntimeSessionError.serverError(Self.message(for: error))
                ))
            } else {
                pending.completion(.success(event))
            }
            return false
        case "diagnostics":
            guard let uri = event.uri, let url = URL(string: uri) else { return false }
            onDiagnostics?(
                url.standardizedFileURL,
                event.diagnostics ?? []
            )
            return false
        case "featuresChanged":
            updateFeatures(capabilityNames: event.capabilities ?? [])
            return false
        case "serverInfoChanged":
            let updated = event.serverInfo.map {
                LanguageServerInfo(name: $0.name, version: $0.version)
            }
            guard updated != serverInfo else { return false }
            serverInfo = updated
            onServerInfoChange?(updated)
            return false
        case "log":
            let level = event.level.flatMap(LanguageServerLogLevel.init(rawValue:)) ?? .info
            onLog?(level, event.message ?? "Language server", event.detail)
            return false
        default:
            return false
        }
    }

    private func handleStateChange(_ event: LanguageServerRuntimeEvent) -> Bool {
        guard let updated = event.state.flatMap(Self.sessionState) else { return false }
        switch updated {
        case .failed:
            let failure = Self.failureState(from: event)
            transition(to: failure)
            if case .failed(_, let message) = failure {
                onLog?(.error, "Language server session failed", message)
            }
            return true
        case .stopped:
            transition(to: .stopped)
            onLog?(.info, "Language server terminated", event.message)
            return true
        case .ready:
            transition(to: .ready)
            onLog?(.info, "Language server is ready", serverInfo?.name)
            return false
        default:
            transition(to: updated)
            return false
        }
    }

    /// Hands the session back to the runtime once it has reached a terminal state.
    private func releaseSession() {
        pollTask = nil
        failPendingOperations(with: LanguageServerRuntimeSessionError.sessionStopped)
        if let sessionID {
            core.destroyLanguageServer(sessionID: sessionID)
        }
        sessionID = nil
        if let processID {
            processRegistry?.unregisterLanguageServerProcess(pid: processID, moduleID: moduleID)
            self.processID = nil
        }
        if !features.isEmpty {
            features = []
            onFeaturesChange?([])
        }
        if serverInfo != nil {
            serverInfo = nil
            onServerInfoChange?(nil)
        }
    }

    private func failPendingOperations(with error: Error) {
        let pending = pendingOperations
        pendingOperations = [:]
        for operation in pending.values {
            operation.completion(.failure(error))
        }
    }

    private func transition(to updatedState: LanguageServerSessionState) {
        guard state != updatedState else { return }
        state = updatedState
        onStateChange?(updatedState)
    }

    private func updateFeatures(capabilityNames names: [String]) {
        let updated = names.reduce(into: LanguageServerFeatureSet()) { result, name in
            switch name {
            case "definition": result.insert(.definition)
            case "references": result.insert(.references)
            case "implementation": result.insert(.implementation)
            case "hover": result.insert(.hover)
            case "completion": result.insert(.completion)
            case "rename": result.insert(.rename)
            case "formatting": result.insert(.formatting)
            case "codeActions": result.insert(.codeActions)
            case "completionResolve": result.insert(.completionResolve)
            case "codeActionResolve": result.insert(.codeActionResolve)
            case "executeCommand": result.insert(.executeCommand)
            default: break
            }
        }
        guard updated != features else { return }
        features = updated
        onFeaturesChange?(updated)
    }

    private static func sessionState(_ lifecycle: String) -> LanguageServerSessionState? {
        switch lifecycle {
        case "created", "processStarting": .startingProcess
        case "initializing": .initializing
        case "ready": .ready
        case "stopping": .stopping
        case "stopped": .stopped
        case "failed": .failed(exitCode: nil, message: nil)
        default: nil
        }
    }

    private static func failureState(
        from event: LanguageServerRuntimeEvent
    ) -> LanguageServerSessionState {
        guard let error = event.error else {
            return .failed(exitCode: nil, message: event.message)
        }
        return .failed(
            exitCode: error.processExitCode.map(Int32.init),
            message: message(for: error)
        )
    }

    private static func message(for error: LanguageServerRuntimeError) -> String {
        var message = error.message
        if let underlying = error.underlyingMessage, !underlying.isEmpty {
            message += ": \(underlying)"
        }
        return message
    }

    private static func navigationOperation(for method: String) -> LanguageServerOperation? {
        switch method {
        case "textDocument/definition": .definition
        case "textDocument/declaration": .declaration
        case "textDocument/typeDefinition": .typeDefinition
        case "textDocument/implementation": .implementation
        case "textDocument/references": .references
        default: nil
        }
    }

    private static func decodeEventResult<Payload: Decodable>(
        _ event: LanguageServerRuntimeEvent,
        as _: Payload.Type
    ) -> Result<Payload, Error> {
        guard let result = event.result else {
            return .failure(LanguageServerRuntimeSessionError.missingResult)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: result.foundationObject)
            return .success(try JSONDecoder().decode(Payload.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    private struct PendingOperation {
        let completion: (Result<LanguageServerRuntimeEvent, Error>) -> Void
    }

    private enum LanguageServerRuntimeSessionError: LocalizedError {
        case notReady
        case startFailed(String)
        case documentSyncFailed(String)
        case requestRejected(String)
        case unsupportedNavigation(String)
        case missingResult
        case sessionStopped
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                "Language server is not ready."
            case .startFailed(let message):
                "Language server failed to start: \(message)"
            case .documentSyncFailed(let message):
                "Language server document sync failed: \(message)"
            case .requestRejected(let message):
                "Language server request was rejected: \(message)"
            case .unsupportedNavigation(let method):
                "Language server navigation \(method) is not supported."
            case .missingResult:
                "Language server response did not include a result."
            case .sessionStopped:
                "Language server session stopped before the request completed."
            case .serverError(let message):
                message
            }
        }
    }
}

package typealias StdioLanguageServerSession = LanguageServerRuntimeSession

private struct PositionPayload: Decodable {
    let line: Int
    let utf16Column: Int

    func makeModel() -> LanguageServerPosition {
        LanguageServerPosition(line: line, utf16Column: utf16Column)
    }
}

private struct RangePayload: Decodable {
    let start: PositionPayload
    let end: PositionPayload

    func makeModel() -> LanguageServerRange {
        LanguageServerRange(start: start.makeModel(), end: end.makeModel())
    }
}

private struct TextEditPayload: Decodable {
    let range: RangePayload
    let newText: String

    func makeModel() -> LanguageServerTextEdit {
        LanguageServerTextEdit(range: range.makeModel(), newText: newText)
    }
}

private struct CompletionItemPayload: Decodable {
    let label: String
    let insertText: String
    let kind: Int?
    let detail: String?
    let documentation: String?
    let sortText: String?
    let filterText: String?
    let textEdit: TextEditPayload?
    let additionalTextEdits: [TextEditPayload]?
    let data: ToolingJSONValue?

    func makeModel() -> LanguageServerCompletionItem {
        LanguageServerCompletionItem(
            label: label,
            detail: detail,
            documentation: documentation,
            insertText: insertText,
            sortText: sortText,
            filterText: filterText,
            kind: kind,
            textEdit: textEdit?.makeModel(),
            additionalTextEdits: additionalTextEdits?.map { $0.makeModel() } ?? [],
            data: data
        )
    }
}

private struct CompletionPayload: Decodable {
    let items: [CompletionItemPayload]
    func makeModels() -> [LanguageServerCompletionItem] { items.map { $0.makeModel() } }
}

private struct CompletionResolvePayload: Decodable {
    let item: CompletionItemPayload
    func makeModel() -> LanguageServerCompletionItem { item.makeModel() }
}

private struct HoverPayload: Decodable {
    struct Hover: Decodable {
        let contents: String
        let isMarkdown: Bool
        let range: RangePayload?

        func makeModel() -> LanguageServerHover {
            LanguageServerHover(
                contents: contents,
                isMarkdown: isMarkdown,
                range: range?.makeModel()
            )
        }
    }

    let hover: Hover?
}

private struct NavigationPayload: Decodable {
    struct Location: Decodable {
        let uri: String?
        let filePath: String?
        let range: RangePayload
        let isReadOnly: Bool
        let displayPath: String?

        func makeModel() -> LanguageServerLocation? {
            let url: URL
            if let filePath {
                url = URL(fileURLWithPath: filePath)
            } else if let uri, let virtualURL = URL(string: uri) {
                url = virtualURL
            } else {
                return nil
            }
            return LanguageServerLocation(
                url: url,
                range: range.makeModel(),
                isReadOnly: isReadOnly,
                displayPath: displayPath
            )
        }
    }

    let locations: [Location]
    func makeModels() -> [LanguageServerLocation] { locations.compactMap { $0.makeModel() } }
}

private struct VirtualDocumentPayload: Decodable {
    let text: String
}

private struct WorkspaceEditPayload: Decodable {
    let changes: [String: [TextEditPayload]]

    func makeModel() -> LanguageServerWorkspaceEdit {
        LanguageServerWorkspaceEdit(changes: Dictionary(
            uniqueKeysWithValues: changes.map { path, edits in
                (
                    URL(fileURLWithPath: path).standardizedFileURL,
                    edits.map { $0.makeModel() }
                )
            }
        ))
    }
}

private struct FormattingPayload: Decodable {
    let edits: [TextEditPayload]
    func makeModels() -> [LanguageServerTextEdit] { edits.map { $0.makeModel() } }
}

private struct CommandPayload: Decodable {
    let title: String
    let command: String
    let arguments: [ToolingJSONValue]?

    func makeModel() -> LanguageServerCommand {
        LanguageServerCommand(title: title, command: command, arguments: arguments ?? [])
    }
}

private struct CodeActionPayload: Decodable {
    let title: String
    let kind: String?
    let isPreferred: Bool
    let edit: WorkspaceEditPayload?
    let command: CommandPayload?
    let data: ToolingJSONValue?

    func makeModel() -> LanguageServerCodeAction {
        LanguageServerCodeAction(
            title: title,
            kind: kind,
            isPreferred: isPreferred,
            edit: edit?.makeModel(),
            command: command?.makeModel(),
            data: data
        )
    }
}

private struct CodeActionsPayload: Decodable {
    let actions: [CodeActionPayload]
    func makeModels() -> [LanguageServerCodeAction] { actions.map { $0.makeModel() } }
}

private struct CodeActionResolvePayload: Decodable {
    let action: CodeActionPayload
    func makeModel() -> LanguageServerCodeAction { action.makeModel() }
}
