import Foundation

/// The semantic language-server surface the application depends on.
///
/// Rust owns the child process, the `Content-Length` framing, the JSON-RPC
/// request IDs, the document versions, and the protocol deadlines. This protocol
/// exposes only opaque session and operation IDs, so the facade below can be
/// driven by a test double without a real server behind it.
protocol LanguageServerRuntimeCore: Sendable {
    func lspStartServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        runtimeExecutableURL: URL?,
        cacheDirectoryURL: URL?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<RustCoreBridge.LspStartServerPayload, RustCoreBridge.CoreCallError>
    func lspStopServer(sessionID: String)
    func lspSyncDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> Result<Void, RustCoreBridge.CoreCallError>
    func lspCloseDocument(sessionID: String, fileURL: URL)
    func lspRequest(
        sessionID: String,
        operation: LanguageServerOperation,
        fileURL: URL?,
        virtualURI: String?,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> Result<RustCoreBridge.LspOperationPayload, RustCoreBridge.CoreCallError>
    func lspCancelOperation(sessionID: String, operationID: String)
    func lspPollEvents(sessionID: String) -> [RustCoreBridge.LspRuntimeEventPayload]
    func lspDestroyServer(sessionID: String)
}

extension RustCoreBridge: LanguageServerRuntimeCore {}

/// A language-server session projected from the Rust runtime.
///
/// This type starts a session, publishes semantic requests, drains
/// `lsp.pollEvents`, and turns each event into the UI-facing callbacks and
/// completion closures the application already expects. The only state it keeps
/// is the opaque session ID, the last lifecycle state it observed, and the
/// closures waiting on opaque operation IDs.
@MainActor
final class StdioLanguageServerSession: LanguageServerSession {
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

    private var sessionID: String?
    private var pendingOperations: [String: PendingOperation] = [:]
    private var pollTask: Task<Void, Never>?
    private var state: LanguageServerSessionState = .stopped

    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onLog: ((LanguageServerLogLevel, String, String?) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    private(set) var features: LanguageServerFeatureSet = []
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    private(set) var serverInfo: LanguageServerInfo?
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)?

    init(
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
        core: any LanguageServerRuntimeCore = RustCoreBridge()
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
    }

    /// Derived from the last lifecycle state Rust published: there is no local
    /// process handle to ask.
    var isRunning: Bool {
        guard sessionID != nil else { return false }
        switch state {
        case .stopped, .failed:
            return false
        case .startingProcess, .initializing, .ready, .stopping:
            return true
        }
    }

    func start(rootURL: URL) throws {
        guard sessionID == nil else { return }
        let normalizedRoot = rootURL.standardizedFileURL
        transition(to: .startingProcess)
        onLog?(
            .info,
            "Starting language server",
            ([executableURL.path] + arguments).joined(separator: " ")
        )
        switch core.lspStartServer(
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
            sessionID = payload.sessionId
            transition(to: Self.sessionState(payload.state) ?? .initializing)
            startPolling()
        case .failure(let error):
            let failure = StdioLanguageServerSessionError.startFailed(error.userMessage)
            let message = failure.localizedDescription
            transition(to: .failed(exitCode: nil, message: message))
            onLog?(.error, "Language server failed to start", message)
            throw failure
        }
    }

    func synchronize(fileURL: URL, text: String, languageID: String) throws {
        guard let sessionID else { throw StdioLanguageServerSessionError.notReady }
        // Documents synced before initialize completes are held by the runtime and
        // opened once the server is ready, so there is nothing to queue here.
        if case .failure(let error) = core.lspSyncDocument(
            sessionID: sessionID,
            fileURL: fileURL.standardizedFileURL,
            languageID: languageID,
            text: text
        ) {
            throw StdioLanguageServerSessionError.documentSyncFailed(error.userMessage)
        }
    }

    func closeDocument(_ fileURL: URL) {
        guard let sessionID else { return }
        // The runtime owns which documents are open, so closing one it does not
        // know about is simply not its business.
        core.lspCloseDocument(sessionID: sessionID, fileURL: fileURL.standardizedFileURL)
    }

    func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try request(.completion, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.BuiltinCompletionPayload.self)
            }.map { $0.makeModels() })
        }
    }

    func hover(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try request(.hover, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.BuiltinHoverPayload.self)
            }.map { $0.hover?.makeModel() })
        }
    }

    func navigate(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        guard let operation = Self.navigationOperation(for: method) else {
            throw StdioLanguageServerSessionError.unsupportedNavigation(method)
        }
        try request(operation, fileURL: fileURL, position: position) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.BuiltinNavigationPayload.self)
            }.map { $0.makeModels() })
        }
    }

    func rename(
        fileURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) throws {
        try request(.rename, fileURL: fileURL, position: position, newName: newName) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.LspWorkspaceEditPayload.self)
            }.map { $0.makeModel() })
        }
    }

    func format(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        try request(.formatting, fileURL: fileURL) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.LspFormattingPayload.self)
            }.map { $0.makeModels() })
        }
    }

    func codeActions(
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
                Self.decodeEventResult($0, as: RustCoreBridge.LspCodeActionsPayload.self)
            }.map { $0.makeModels() })
        }
    }

    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) throws {
        try request(.resolveCompletion, fileURL: fileURL, completionItem: item) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.LspCompletionResolvePayload.self)
            }.map { $0.makeModel() })
        }
    }

    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        fileURL: URL,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) throws {
        try request(.resolveCodeAction, fileURL: fileURL, codeAction: action) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.LspCodeActionResolvePayload.self)
            }.map { $0.makeModel() })
        }
    }

    func execute(
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

    func stop() {
        guard let sessionID else {
            failPendingOperations(with: StdioLanguageServerSessionError.sessionStopped)
            transition(to: .stopped)
            return
        }
        // The runtime sends the shutdown, force-terminates on its own deadline,
        // and publishes the terminal transition. The poll loop releases the
        // session when that arrives, so nothing here waits on the server.
        core.lspStopServer(sessionID: sessionID)
        if isRunning { transition(to: .stopping) }
    }

    // MARK: - Requests

    private func request(
        _ operation: LanguageServerOperation,
        fileURL: URL?,
        position: LanguageServerPosition? = nil,
        newName: String? = nil,
        range: LanguageServerRange? = nil,
        diagnostics: [LanguageServerDiagnostic] = [],
        completionItem: LanguageServerCompletionItem? = nil,
        codeAction: LanguageServerCodeAction? = nil,
        command: LanguageServerCommand? = nil,
        completion: @escaping (Result<RustCoreBridge.LspRuntimeEventPayload, Error>) -> Void
    ) throws {
        guard let sessionID, state == .ready else {
            throw StdioLanguageServerSessionError.notReady
        }
        switch core.lspRequest(
            sessionID: sessionID,
            operation: operation,
            fileURL: fileURL?.standardizedFileURL,
            virtualURI: nil,
            position: position,
            newName: newName,
            range: range,
            diagnostics: diagnostics,
            completionItem: completionItem,
            codeAction: codeAction,
            command: command
        ) {
        case .success(let payload):
            pendingOperations[payload.operationId] = PendingOperation(completion: completion)
        case .failure(let error):
            throw StdioLanguageServerSessionError.requestRejected(error.userMessage)
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
                let events = core.lspPollEvents(sessionID: sessionID)
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
    private func handle(_ event: RustCoreBridge.LspRuntimeEventPayload) -> Bool {
        switch event.type {
        case "stateChanged":
            return handleStateChange(event)
        case "requestCompleted":
            guard let operationID = event.operationId,
                  let pending = pendingOperations.removeValue(forKey: operationID) else {
                return false
            }
            if let error = event.error {
                pending.completion(.failure(
                    StdioLanguageServerSessionError.serverError(Self.message(for: error))
                ))
            } else {
                pending.completion(.success(event))
            }
            return false
        case "diagnostics":
            guard let uri = event.uri, let url = URL(string: uri) else { return false }
            onDiagnostics?(
                url.standardizedFileURL,
                (event.diagnostics ?? []).map { $0.makeModel() }
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

    private func handleStateChange(_ event: RustCoreBridge.LspRuntimeEventPayload) -> Bool {
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
        failPendingOperations(with: StdioLanguageServerSessionError.sessionStopped)
        if let sessionID {
            core.lspDestroyServer(sessionID: sessionID)
        }
        sessionID = nil
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
        from event: RustCoreBridge.LspRuntimeEventPayload
    ) -> LanguageServerSessionState {
        guard let error = event.error else {
            return .failed(exitCode: nil, message: event.message)
        }
        return .failed(
            exitCode: error.processExitCode.map(Int32.init),
            message: message(for: error)
        )
    }

    private static func message(for error: RustCoreBridge.LspRuntimeErrorPayload) -> String {
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
        _ event: RustCoreBridge.LspRuntimeEventPayload,
        as _: Payload.Type
    ) -> Result<Payload, Error> {
        guard let result = event.result else {
            return .failure(StdioLanguageServerSessionError.missingResult)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: result.foundationObject)
            return .success(try JSONDecoder().decode(Payload.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    private struct PendingOperation {
        let completion: (Result<RustCoreBridge.LspRuntimeEventPayload, Error>) -> Void
    }

    private enum StdioLanguageServerSessionError: LocalizedError {
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
