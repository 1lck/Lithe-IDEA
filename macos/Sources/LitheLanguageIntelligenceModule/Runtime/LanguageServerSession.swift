import Foundation
import LitheCoreContracts
import LitheModuleAPI

package struct LanguageServerRequestFailure: LocalizedError, Equatable, Sendable {
    package let runtimeError: LanguageServerRuntimeError

    package var errorDescription: String? {
        var message = runtimeError.message
        if let underlying = runtimeError.underlyingMessage, !underlying.isEmpty {
            message += ": \(underlying)"
        }
        return message
    }
}

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
    private let launchResolver: (@MainActor (URL) throws -> ResolvedLanguageServerLaunch)?
    private let hostIntegrationLaunch: LanguageServerHostIntegrationLaunch?
    private let cacheDirectoryURL: URL?
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let shutdownTimeout: TimeInterval
    private let core: any LanguageServerRuntimeCore
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID
    /// The plugin that owns the process; nil for host-owned servers, which
    /// serve no plugin functions.
    private let pluginID: String?

    private var sessionID: String?
    private var pendingOperations: [String: PendingOperation] = [:]
    /// Progress listeners of running plugin functions, by operation ID.
    private var functionProgress: [String: @MainActor @Sendable (PluginFunctionProgress) -> Void] = [:]
    private var documentVersions: [URL: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var state: LanguageServerSessionState = .stopped
    private var processID: Int32?
    /// Requests being written off the main actor. Core writes a request to
    /// the server's stdin synchronously, and a server that stopped reading
    /// blocks that write, so plugin requests are sent from a background task.
    /// While one is in flight the poll loop holds the events, so a reply
    /// never arrives before its operation is registered.
    private var sendsInFlight = 0
    private var stopWatchdog: SendWatchdog?

    /// How long a write may stay blocked after its call was cancelled or the
    /// session was stopped before the process is ended to free it.
    package var stuckSendGrace: Duration = .seconds(2)
    /// Ends the server process at once. The owner of a plugin backend sets
    /// it; ending the process is the only way to free a write blocked on a
    /// server that no longer reads its input.
    package var terminateProcess: (@MainActor () -> Void)?
    /// Called once the session has ended and handed its process back to
    /// Core, so the owner can end what the process left running.
    package var onReleased: (@MainActor () -> Void)?

    package var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    package var onLog: ((LanguageServerLogLevel, String, String?, String?) -> Void)?
    package var onProjectPreparation: ((ProjectPreparationSnapshot) -> Void)?
    package var onMavenProfileTask: ((String) -> Void)?
    package var onMavenProfileProject: ((MavenProfileProjectResult) -> Void)?
    package var onStateChange: ((LanguageServerSessionState) -> Void)?
    package private(set) var features: LanguageServerFeatureSet = []
    package var onSemanticTokensRefresh: (() -> Void)?
    package var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    package private(set) var serverInfo: LanguageServerInfo?
    /// Plugin functions the backend registers now, sorted, as Core's last
    /// `functionsChanged` event listed them.
    package private(set) var functionIDs: [String] = []
    package var onFunctionsChange: (([String]) -> Void)?
    package var onServerInfoChange: ((LanguageServerInfo?) -> Void)?
    package var javaTestRunnerURL: URL? {
        hostIntegrationLaunch?.coreLaunch?.jdtlsLaunchResources?.javaTestRunnerURL
    }

    package init(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        initializationOptions: ToolingJSONValue? = nil,
        launchResolver: (@MainActor (URL) throws -> ResolvedLanguageServerLaunch)? = nil,
        hostIntegrationLaunch: LanguageServerHostIntegrationLaunch? = nil,
        cacheDirectoryURL: URL? = nil,
        initializeTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 30,
        shutdownTimeout: TimeInterval = 2,
        core: any LanguageServerRuntimeCore,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence,
        pluginID: String? = nil
    ) {
        self.providerID = providerID
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.initializationOptions = initializationOptions
        self.launchResolver = launchResolver
        self.hostIntegrationLaunch = hostIntegrationLaunch
        self.cacheDirectoryURL = cacheDirectoryURL
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.shutdownTimeout = shutdownTimeout
        self.core = core
        self.processRegistry = processRegistry
        self.moduleID = moduleID
        self.pluginID = pluginID
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

    package func start(rootURL: URL, workspaceFingerprint: String?) throws {
        try start(
            rootURL: rootURL,
            workspaceFingerprint: workspaceFingerprint,
            mavenContext: nil
        )
    }

    package func start(rootURL: URL, workspaceFingerprint: String?, mavenContext: MavenLaunchContext?) throws {
        try start(rootURL: rootURL, workspaceFingerprint: workspaceFingerprint, mavenContext: mavenContext, javaGradle: nil)
    }

    package func start(
        rootURL: URL,
        workspaceFingerprint: String?,
        mavenContext: MavenLaunchContext?,
        javaGradle: JavaGradleImportConfiguration?
    ) throws {
        guard sessionID == nil else { return }
        let normalizedRoot = rootURL.standardizedFileURL
        transition(to: .startingProcess)
        var arguments = arguments
        var initializationOptions = initializationOptions
        if let launchResolver {
            do {
                let resolved = try launchResolver(normalizedRoot)
                arguments = resolved.arguments
                initializationOptions = resolved.initializationOptions
            } catch {
                let message = "Language server launch could not be prepared: \(error.localizedDescription)"
                let failure = LanguageServerSessionFailure(
                    code: (error as? DeclarativePluginRejection)?.code ?? "plugin.launch.missing",
                    stage: "processStart",
                    message: message
                )
                transition(to: .failed(failure))
                onLog?(.error, "Language server failed to start", message, nil)
                throw LanguageServerSessionStartError(failure: failure)
            }
        }
        onLog?(
            .info,
            "Starting language server",
            ([executableURL.path] + arguments).joined(separator: " "),
            nil
        )
        let started = if let pluginID {
            core.startPluginLanguageServer(
                pluginID: pluginID,
                providerID: providerID,
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                rootURL: normalizedRoot,
                initializationOptions: initializationOptions,
                initializeTimeout: initializeTimeout,
                requestTimeout: requestTimeout,
                shutdownTimeout: shutdownTimeout
            )
        } else {
            core.startLanguageServer(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: normalizedRoot,
            workingDirectoryURL: normalizedRoot,
            initializationOptions: initializationOptions,
            runtimeExecutableURL: hostIntegrationLaunch?.runtimeExecutableURL,
            jdtlsLaunchResources: hostIntegrationLaunch?.coreLaunch?.jdtlsLaunchResources,
            cacheDirectoryURL: cacheDirectoryURL,
            workspaceFingerprint: workspaceFingerprint,
            mavenContext: mavenContext,
            javaGradle: javaGradle,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
            )
        }
        switch started {
        case .success(let payload):
            sessionID = payload.sessionID
            processID = payload.processID
            if let processID {
                processRegistry?.registerLanguageServerProcess(pid: processID, moduleID: moduleID)
            }
            transition(to: Self.sessionState(payload.state) ?? .initializing)
            startPolling()
        case .failure(let error):
            let message = "Language server failed to start: \(error.userMessage)"
            let failure = LanguageServerSessionFailure(
                code: error.code,
                stage: "processStart",
                message: message
            )
            transition(to: .failed(failure))
            onLog?(.error, "Language server failed to start", message, nil)
            throw LanguageServerSessionStartError(failure: failure)
        }
    }

    package func synchronize(fileURL: URL, text: String, languageID: String) throws {
        guard let sessionID else { throw LanguageServerRuntimeSessionError.notReady }
        // Documents synced before initialize completes are held by the runtime and
        // opened once the server is ready, so there is nothing to queue here.
        switch core.syncLanguageServerDocument(
            sessionID: sessionID,
            fileURL: fileURL.standardizedFileURL,
            languageID: languageID,
            text: text
        ) {
        case .success(let sync):
            documentVersions[fileURL.standardizedFileURL] = sync.documentVersion
        case .failure(let error):
            throw LanguageServerRuntimeSessionError.documentSyncFailed(error.userMessage)
        }
    }

    package func synchronize(
        fileURL: URL,
        text: String,
        languageID: String,
        changes: [LanguageServerDocumentChange]
    ) throws {
        guard let sessionID else { throw LanguageServerRuntimeSessionError.notReady }
        guard let incrementalCore = core as? any IncrementalLanguageServerRuntimeCore else {
            return try synchronize(fileURL: fileURL, text: text, languageID: languageID)
        }
        switch incrementalCore.syncLanguageServerDocument(
            sessionID: sessionID,
            fileURL: fileURL.standardizedFileURL,
            languageID: languageID,
            text: text,
            changes: changes
        ) {
        case .success(let sync):
            documentVersions[fileURL.standardizedFileURL] = sync.documentVersion
        case .failure(let error):
            throw LanguageServerRuntimeSessionError.documentSyncFailed(error.userMessage)
        }
    }
    package func notifyWorkspaceFilesChanged(
        _ changes: [LanguageServerWorkspaceFileChange]
    ) throws {
        guard let sessionID else { throw LanguageServerRuntimeSessionError.notReady }
        guard !changes.isEmpty else { return }
        switch core.notifyLanguageServerWorkspaceFilesChanged(
            sessionID: sessionID,
            changes: changes
        ) {
        case .success:
            onLog?(
                .info,
                "Language server workspace changes sent",
                "changeCount=\(changes.count)",
                nil
            )
        case .failure(let error):
            onLog?(
                .error,
                "Language server workspace changes failed",
                error.userMessage,
                nil
            )
            throw LanguageServerRuntimeSessionError.documentSyncFailed(error.userMessage)
        }
    }

    package func closeDocument(_ fileURL: URL) {
        guard let sessionID else { return }
        documentVersions[fileURL.standardizedFileURL] = nil
        // The runtime owns which documents are open, so closing one it does not
        // know about is simply not its business.
        core.closeLanguageServerDocument(sessionID: sessionID, fileURL: fileURL.standardizedFileURL)
    }

    package func javaNavigationMarkers(
        fileURL: URL,
        completion: @escaping (Result<[JavaNavigationMarker], Error>) -> Void
    ) throws {
        let normalizedURL = fileURL.standardizedFileURL
        guard let sessionID, state == .ready else {
            throw LanguageServerRuntimeSessionError.notReady
        }
        guard let documentVersion = documentVersions[normalizedURL] else {
            throw LanguageServerRuntimeSessionError.documentNotSynchronized
        }
        switch core.requestJavaNavigationMarkers(
            sessionID: sessionID,
            fileURL: normalizedURL,
            documentVersion: documentVersion
        ) {
        case .success(let operation):
            registerPendingOperation(
                operation,
                name: "javaNavigationMarkers"
            ) { [weak self] result in
                guard let self else { return }
                completion(result.flatMap {
                    Self.decodeEventResult($0, as: JavaNavigationMarkersPayload.self)
                }.flatMap { payload in
                    guard self.documentVersions[normalizedURL] == payload.documentVersion else {
                        return .failure(LanguageServerRuntimeSessionError.staleDocument)
                    }
                    return .success(payload.makeModels())
                })
            }
        case .failure(let error):
            throw LanguageServerRuntimeSessionError.requestRejected(error.userMessage)
        }
    }

    package func resolveJavaNavigation(
        fileURL: URL,
        marker: JavaNavigationMarker,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        let normalizedURL = fileURL.standardizedFileURL
        guard let sessionID, state == .ready else {
            throw LanguageServerRuntimeSessionError.notReady
        }
        guard let documentVersion = documentVersions[normalizedURL] else {
            throw LanguageServerRuntimeSessionError.documentNotSynchronized
        }
        switch core.resolveJavaNavigation(
            sessionID: sessionID,
            fileURL: normalizedURL,
            marker: marker,
            documentVersion: documentVersion
        ) {
        case .success(let operation):
            registerPendingOperation(
                operation,
                name: "javaResolveNavigation"
            ) { [weak self] result in
                guard let self else { return }
                completion(result.flatMap {
                    Self.decodeEventResult($0, as: JavaNavigationLocationsPayload.self)
                }.flatMap { payload in
                    guard self.documentVersions[normalizedURL] == payload.documentVersion else {
                        return .failure(LanguageServerRuntimeSessionError.staleDocument)
                    }
                    return .success(payload.makeModels())
                })
            }
        case .failure(let error):
            throw LanguageServerRuntimeSessionError.requestRejected(error.userMessage)
        }
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

    package func inlayHints(fileURL: URL, range: LanguageServerRange,
                            completion: @escaping (Result<[LanguageServerInlayHint], Error>) -> Void) throws {
        try request(.inlayHints, fileURL: fileURL, range: range) { result in
            completion(result.flatMap { Self.decodeEventResult($0, as: InlayHintsPayload.self) }
                .map { $0.hints.map { $0.makeModel() } })
        }
    }

    package func semanticTokens(fileURL: URL, completion: @escaping (Result<LanguageServerSemanticTokens, Error>) -> Void) throws {
        try request(.semanticTokens, fileURL: fileURL) { result in
            completion(result.flatMap { Self.decodeEventResult($0, as: LanguageServerSemanticTokens.self) })
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
        try executeReturningValue(command, fileURL: fileURL) { result in
            completion(result.map { _ in () })
        }
    }

    package func executeReturningValue(
        _ command: LanguageServerCommand,
        fileURL: URL,
        completion: @escaping (Result<ToolingJSONValue, Error>) -> Void
    ) throws {
        // A workspace command belongs to the server rather than to a document, so
        // it carries no document URI and is not gated on one being open.
        _ = fileURL
        try request(.executeCommand, fileURL: nil, command: command) { result in
            completion(result.flatMap { event in
                guard case .object(let object)? = event.result,
                      let value = object["value"] else {
                    return .failure(LanguageServerRuntimeSessionError.missingResult)
                }
                return .success(value)
            })
        }
    }

    package func buildRequest(
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) async throws -> ToolingJSONValue {
        guard let sessionID, state == .ready else {
            throw LanguageServerRuntimeSessionError.notReady
        }
        let operation: LanguageServerRuntimeOperation
        switch await send(timeout: timeout, { core in
            core.requestBuildProvider(sessionID: sessionID, method: method, params: params, timeout: timeout)
        }) {
        case .success(let started): operation = started
        case .failure(let error):
            sendsInFlight -= 1
            try Task.checkCancellation()
            throw LanguageServerRuntimeSessionError.requestRejected(error.userMessage)
        }
        // Registration happens before this actor can run the cancellation
        // below, so a cancelled request always finds its pending entry and
        // ends with the cancellation event Core publishes.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerPendingOperation(operation, name: method) { result in
                    continuation.resume(with: result.flatMap { event in
                        guard case .object(let object)? = event.result, let value = object["value"] else {
                            return .failure(LanguageServerRuntimeSessionError.missingResult)
                        }
                        return .success(value)
                    })
                }
                sendsInFlight -= 1
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOffMain(operation.operationID) }
        }
    }

    /// Invokes a plugin function of the plugin that owns this session. Core
    /// checks ownership and registration; a refusal or a failed call throws
    /// `PluginFunctionFailure`, and cancelling the task cancels the call.
    package func invokeFunction(
        _ functionID: String,
        params: ToolingJSONValue,
        timeout: TimeInterval,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        guard let pluginID else {
            throw PluginFunctionFailure(
                code: "plugin.function.unavailable", message: "This server belongs to no plugin."
            )
        }
        guard let sessionID, state == .ready else {
            throw LanguageServerRuntimeSessionError.notReady
        }
        let operation: LanguageServerRuntimeOperation
        switch await send(timeout: timeout, { core in
            core.requestPluginFunction(
                sessionID: sessionID, pluginID: pluginID, functionID: functionID, params: params, timeout: timeout
            )
        }) {
        case .success(let started): operation = started
        case .failure(let error):
            sendsInFlight -= 1
            try Task.checkCancellation()
            let code = Self.refusalCode(of: error)
            // A diagnostic that did not become the code stays in the message.
            throw PluginFunctionFailure(code: code, message: code == error.details ? error.message : error.userMessage)
        }
        functionProgress[operation.operationID] = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerPendingOperation(operation, name: functionID) { [weak self] result in
                    self?.functionProgress[operation.operationID] = nil
                    continuation.resume(with: result.mapError(Self.functionFailure).flatMap { event in
                        guard case .object(let object)? = event.result, let value = object["value"] else {
                            return .failure(LanguageServerRuntimeSessionError.missingResult)
                        }
                        return .success(value)
                    })
                }
                sendsInFlight -= 1
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelOffMain(operation.operationID) }
        }
    }

    /// Codes Core puts in `details` when it refuses a call before it reaches
    /// the backend. Any other `details`, such as an OS error text from a
    /// failed write, is a diagnostic and never becomes the page's code.
    private static let functionRefusalCodes: Set<String> = [
        "plugin.function.invalidReference",
        "plugin.function.invalidParams",
        "plugin.function.unavailable",
        "plugin.function.wrongPlugin",
        "plugin.function.unknown",
    ]

    package static func refusalCode(of error: LanguageServerRuntimeFailure) -> String {
        if let details = error.details, functionRefusalCodes.contains(details) { return details }
        return error.code
    }

    /// Runs `request` off the main actor and returns its result. The caller
    /// must decrement `sendsInFlight` once it has registered the operation,
    /// or right away when the request was refused.
    ///
    /// A write that is still blocked when the call's timeout passes, or
    /// `stuckSendGrace` after the caller was cancelled, ends the process:
    /// the write then fails and Core fails the session.
    private func send(
        timeout: TimeInterval,
        _ request: @escaping @Sendable (any LanguageServerRuntimeCore) -> Result<
            LanguageServerRuntimeOperation, LanguageServerRuntimeFailure
        >
    ) async -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        sendsInFlight += 1
        let core = core
        let sending = Task.detached(priority: .userInitiated) { request(core) }
        let watchdog = SendWatchdog()
        let grace = stuckSendGrace
        let endStuck: @MainActor () -> Void = { [weak self] in self?.endStuckSend() }
        watchdog.arm(after: .seconds(max(timeout, 0)), endStuck)
        let result = await withTaskCancellationHandler {
            await sending.value
        } onCancel: {
            Task { @MainActor in watchdog.arm(after: grace, endStuck) }
        }
        watchdog.disarm()
        return result
    }

    /// Cancels an operation without waiting on the main actor: Core takes the
    /// same write lock a blocked request holds.
    private func cancelOffMain(_ operationID: String) {
        guard let sessionID else { return }
        let core = core
        Task.detached(priority: .userInitiated) {
            core.cancelLanguageServerOperation(sessionID: sessionID, operationID: operationID)
        }
    }

    private func endStuckSend() {
        guard sendsInFlight > 0 else { return }
        onLog?(.warning, "Language server stopped reading its input", "Ending the process to free a blocked request.", nil)
        terminateProcess?()
    }

    private static func functionFailure(_ error: Error) -> Error {
        guard let failure = error as? LanguageServerRequestFailure else { return error }
        let runtimeError = failure.runtimeError
        return PluginFunctionFailure(
            code: runtimeError.code, message: runtimeError.message, pluginErrorCode: runtimeError.pluginErrorCode
        )
    }

    /// Asks JDT, through Core, which classes in the workspace can be launched.
    package func javaEntrypoints(
        completion: @escaping (Result<JavaEntrypoints, Error>) -> Void
    ) throws {
        try request(.javaEntrypoints, fileURL: nil) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: JavaEntrypoints.self)
            })
        }
    }

    package func javaTestItems(
        fileURL: URL,
        completion: @escaping (Result<JavaTestItems, Error>) -> Void
    ) throws {
        try request(.javaTestItems, fileURL: fileURL) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: JavaTestItems.self)
            })
        }
    }

    /// Asks JDT, through Core, which `main` methods in one file can be launched.
    package func javaMainMethods(
        fileURL: URL,
        completion: @escaping (Result<JavaMainMethods, Error>) -> Void
    ) throws {
        try request(.javaMainMethods, fileURL: fileURL) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: JavaMainMethods.self)
            })
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
        if sendsInFlight > 0 {
            // Core's stop waits for the request being written. A server that
            // stopped reading never lets that write finish, so it is ended
            // once the grace has passed.
            let core = core
            Task.detached(priority: .userInitiated) { core.stopLanguageServer(sessionID: sessionID) }
            if stopWatchdog == nil {
                let watchdog = SendWatchdog()
                watchdog.arm(after: stuckSendGrace) { [weak self] in self?.endStuckSend() }
                stopWatchdog = watchdog
            }
        } else {
            core.stopLanguageServer(sessionID: sessionID)
        }
        if isRunning { transition(to: .stopping) }
    }

    package func retryMavenProfiles() {
        guard let sessionID, isRunning else { return }
        if case .failure(let failure) = core.retryMavenProfiles(sessionID: sessionID) {
            onLog?(.error, "Maven profile retry failed", failure.message, nil)
        }
    }

    /// Hands a changed Maven context to the running server. A failure means the
    /// session cannot take it and the caller should restart the session.
    package func updateMavenConfiguration(
        _ context: MavenLaunchContext,
        reloadProjects: Bool
    ) -> Result<LanguageServerMavenConfigurationUpdate, LanguageServerRuntimeFailure> {
        guard let sessionID, isRunning else {
            return .failure(LanguageServerRuntimeFailure(
                code: "sessionStopped",
                message: "The Java language session is no longer running."
            ))
        }
        let result = core.updateMavenConfiguration(
            sessionID: sessionID,
            context: context,
            reloadProjects: reloadProjects
        )
        if case .failure(let failure) = result {
            onLog?(.warning, "Maven configuration update failed", failure.userMessage, nil)
        }
        return result
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
            registerPendingOperation(payload, name: operation.rawValue, completion: completion)
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
                // Core keeps the events until the requests being written are
                // registered; see `sendsInFlight`.
                let events = sendsInFlight > 0 ? [] : core.pollLanguageServerEvents(sessionID: sessionID)
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
        case "projectPreparation":
            switch Self.decodeEventResult(event, as: ProjectPreparationSnapshot.self) {
            case .success(let snapshot): onProjectPreparation?(snapshot)
            case .failure(let error): onLog?(.error, "Invalid project preparation event", error.localizedDescription, nil)
            }
            return false

        case "stateChanged":
            return handleStateChange(event)
        case "requestCompleted":
            guard let operationID = event.operationID,
                  let pending = pendingOperations.removeValue(forKey: operationID) else {
                return false
            }
            if let error = event.error {
                let outcome = PendingOperationOutcome(errorCode: error.code)
                onLog?(
                    outcome.logLevel,
                    outcome.logMessage,
                    "operation=\(pending.name); \(Self.message(for: error))",
                    operationID
                )
                if error.code == "staleDocumentVersion" || error.code == "requestCancelled" {
                    pending.completion(.failure(CancellationError()))
                } else {
                    pending.completion(.failure(LanguageServerRequestFailure(runtimeError: error)))
                }
            } else {
                onLog?(
                    .info,
                    "Language server request succeeded",
                    "operation=\(pending.name)",
                    operationID
                )
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
        case "semanticTokensRefresh":
            onSemanticTokensRefresh?()
            return false
        case "functionsChanged":
            guard case .object(let object)? = event.result, case .array(let values)? = object["functions"] else {
                return false
            }
            let updated = values.compactMap { value -> String? in
                if case .string(let id) = value { return id }
                return nil
            }.sorted()
            guard updated != functionIDs else { return false }
            functionIDs = updated
            onFunctionsChange?(updated)
            return false
        case "requestProgress":
            guard let operationID = event.operationID, let listener = functionProgress[operationID],
                  case .object(let object)? = event.result else {
                return false
            }
            var message: String?
            if case .string(let text)? = object["message"] { message = text }
            var percentage: Int?
            if case .integer(let value)? = object["percentage"] { percentage = value }
            listener(PluginFunctionProgress(message: message, percentage: percentage))
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
            if let status = event.mavenProfileTask { onMavenProfileTask?(status) }
            if let result = event.mavenProfileProject { onMavenProfileProject?(result) }
            let level = event.level.flatMap(LanguageServerLogLevel.init(rawValue:)) ?? .info
            onLog?(level, event.message ?? "Language server", event.detail, event.operationID)
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
            if case .failed(let details) = failure {
                onLog?(.error, "Language server session failed", details.message, nil)
            }
            return true
        case .stopped:
            transition(to: .stopped)
            onLog?(.info, "Language server terminated", event.message, nil)
            return true
        case .ready:
            transition(to: .ready)
            onLog?(.info, "Language server is ready", serverInfo?.name, nil)
            return false
        default:
            transition(to: updated)
            return false
        }
    }

    /// Hands the session back to the runtime once it has reached a terminal state.
    private func releaseSession() {
        pollTask = nil
        stopWatchdog?.disarm()
        stopWatchdog = nil
        functionProgress = [:]
        failPendingOperations(with: LanguageServerRuntimeSessionError.sessionStopped)
        if let sessionID {
            core.destroyLanguageServer(sessionID: sessionID)
        }
        sessionID = nil
        documentVersions = [:]
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
        if !functionIDs.isEmpty {
            functionIDs = []
            onFunctionsChange?([])
        }
        let released = onReleased
        onReleased = nil
        released?()
    }

    private func failPendingOperations(with error: Error) {
        let pending = pendingOperations
        pendingOperations = [:]
        for (operationID, operation) in pending {
            onLog?(
                .warning,
                "Language server request cancelled",
                "operation=\(operation.name); \(error.localizedDescription)",
                operationID
            )
            operation.completion(.failure(error))
        }
    }

    private func registerPendingOperation(
        _ operation: LanguageServerRuntimeOperation,
        name: String,
        completion: @escaping (Result<LanguageServerRuntimeEvent, Error>) -> Void
    ) {
        pendingOperations[operation.operationID] = PendingOperation(
            name: name,
            completion: completion
        )
        onLog?(
            .info,
            "Language server request started",
            "operation=\(name)",
            operation.operationID
        )
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
            case "semanticTokens": result.insert(.semanticTokens)
            case "inlayHints": result.insert(.inlayHints)
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
        case "failed": .failed(LanguageServerSessionFailure())
        default: nil
        }
    }

    private static func failureState(
        from event: LanguageServerRuntimeEvent
    ) -> LanguageServerSessionState {
        guard let error = event.error else {
            return .failed(LanguageServerSessionFailure(message: event.message))
        }
        return .failed(LanguageServerSessionFailure(
            code: error.code,
            stage: error.stage,
            exitCode: error.processExitCode.map(Int32.init),
            message: message(for: error)
        ))
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
        let name: String
        let completion: (Result<LanguageServerRuntimeEvent, Error>) -> Void
    }

    /// Maps stable Rust runtime error codes to the terminal request state used
    /// by host logs. This keeps timeout and cancellation semantics out of UI text.
    private enum PendingOperationOutcome {
        case failed
        case cancelled
        case timedOut

        init(errorCode: String) {
            switch errorCode {
            case "requestCancelled": self = .cancelled
            case "requestTimeout": self = .timedOut
            default: self = .failed
            }
        }

        var logLevel: LanguageServerLogLevel {
            switch self {
            case .failed, .timedOut: .error
            case .cancelled: .warning
            }
        }

        var logMessage: String {
            switch self {
            case .failed: "Language server request failed"
            case .cancelled: "Language server request cancelled"
            case .timedOut: "Language server request timed out"
            }
        }
    }

    private enum LanguageServerRuntimeSessionError: LocalizedError {
        case notReady
        case startFailed(String)
        case documentSyncFailed(String)
        case documentNotSynchronized
        case requestRejected(String)
        case unsupportedNavigation(String)
        case missingResult
        case sessionStopped
        case staleDocument

        var errorDescription: String? {
            switch self {
            case .notReady:
                "Language server is not ready."
            case .startFailed(let message):
                "Language server failed to start: \(message)"
            case .documentSyncFailed(let message):
                "Language server document sync failed: \(message)"
            case .documentNotSynchronized:
                "The document is not synchronized with the language server."
            case .requestRejected(let message):
                "Language server request was rejected: \(message)"
            case .unsupportedNavigation(let method):
                "Language server navigation \(method) is not supported."
            case .missingResult:
                "Language server response did not include a result."
            case .sessionStopped:
                "Language server session stopped before the request completed."
            case .staleDocument:
                "The document changed before Java navigation completed."
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
    let insertTextFormat: Int?
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
            data: data,
            insertTextFormat: insertTextFormat ?? 1
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

private struct JavaNavigationMarkersPayload: Decodable {
    struct Marker: Decodable {
        let line: Int
        let utf16Column: Int
        let implementationCount: Int
        let direction: JavaNavigationDirection
        let relation: JavaNavigationRelation

        func makeModel() -> JavaNavigationMarker {
            JavaNavigationMarker(
                line: line,
                utf16Column: utf16Column,
                implementationCount: implementationCount,
                direction: direction,
                relation: relation
            )
        }
    }

    let documentVersion: Int
    let markers: [Marker]

    func makeModels() -> [JavaNavigationMarker] { markers.map { $0.makeModel() } }
}

private struct JavaNavigationLocationsPayload: Decodable {
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

    let documentVersion: Int
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

private struct InlayHintsPayload: Decodable {
    let hints: [InlayHintPayload]
}

private struct InlayHintPayload: Decodable {
    let position: PositionPayload
    let label: String
    let kind: Int?
    let tooltip: String?
    let paddingLeft: Bool?
    let paddingRight: Bool?
    let textEdits: [TextEditPayload]?

    func makeModel() -> LanguageServerInlayHint {
        LanguageServerInlayHint(position: position.makeModel(), label: label, kind: kind, tooltip: tooltip,
                               paddingLeft: paddingLeft ?? false, paddingRight: paddingRight ?? false,
                               textEdits: (textEdits ?? []).map { $0.makeModel() })
    }
}

/// Runs an action once a delay has passed, unless disarmed first. Arming
/// again replaces the pending delay; a disarmed watchdog never fires.
@MainActor
private final class SendWatchdog {
    private var finished = false
    private var timer: Task<Void, Never>?

    func arm(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        guard !finished else { return }
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self, !self.finished else { return }
            self.finished = true
            action()
        }
    }

    func disarm() {
        finished = true
        timer?.cancel()
        timer = nil
    }
}
