import Foundation

protocol LspClientCore: Sendable {
    func lspClientInitialize(rootURL: URL) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientInitialize(
        rootURL: URL,
        initializationOptions: ToolingJSONValue?
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientOpenDocument(
        state: ToolingJSONValue,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientChangeDocument(
        state: ToolingJSONValue,
        fileURL: URL,
        text: String
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientCloseDocument(
        state: ToolingJSONValue,
        fileURL: URL
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientShutdown(
        state: ToolingJSONValue
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientRequest(
        state: ToolingJSONValue,
        fileURL: URL,
        method: String,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientApplyServerMessage(
        state: ToolingJSONValue,
        message: String
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspFrameMessage(_ message: String) -> RustCoreBridge.LspFramePayload?
    func lspParseServerMessages(
        buffer: [UInt8],
        chunk: [UInt8]
    ) -> RustCoreBridge.LspParsedMessagesPayload?
}

extension RustCoreBridge: LspClientCore {}

protocol LspSessionCore: LspClientCore {
    func lspSessionCreate(
        rootURL: URL,
        initializationOptions: ToolingJSONValue?
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionOpenDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionChangeDocument(
        sessionID: String,
        fileURL: URL,
        text: String
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionCloseDocument(
        sessionID: String,
        fileURL: URL
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionShutdown(sessionID: String) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionRequest(
        sessionID: String,
        fileURL: URL,
        method: String,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionApplyServerMessage(
        sessionID: String,
        message: String
    ) -> RustCoreBridge.LspSessionResponsePayload?
    func lspSessionDestroy(sessionID: String)
}

extension RustCoreBridge: LspSessionCore {}

extension LspClientCore {
    func lspClientInitialize(
        rootURL: URL,
        initializationOptions _: ToolingJSONValue?
    ) -> RustCoreBridge.LspClientResponsePayload? {
        lspClientInitialize(rootURL: rootURL)
    }

    func lspClientCloseDocument(
        state _: ToolingJSONValue,
        fileURL _: URL
    ) -> RustCoreBridge.LspClientResponsePayload? { nil }

    func lspClientShutdown(
        state _: ToolingJSONValue
    ) -> RustCoreBridge.LspClientResponsePayload? { nil }
}

@MainActor
final class StdioLanguageServerSession: LanguageServerSession {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let initializationOptions: ToolingJSONValue?
    private let initializeTimeoutNanoseconds: UInt64
    private let requestTimeoutNanoseconds: UInt64
    private let process: any RawProcessSession
    private let core: any LspClientCore
    private var legacyState: ToolingJSONValue?
    private var sessionID: String?
    private var readBuffer = Data()
    private var openedDocumentURIs: Set<String> = []
    private var pendingDocuments: [String: PendingDocument] = [:]
    private var responseHandlers: [String: PendingResponse] = [:]
    private var responseTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var isInitialized = false
    private var isStopping = false
    private var state: LanguageServerSessionState = .stopped
    private var initializeTimeoutTask: Task<Void, Never>?
    private var shutdownFallbackTask: Task<Void, Never>?

    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?
    var onLog: ((LanguageServerLogLevel, String, String?) -> Void)?
    var onStateChange: ((LanguageServerSessionState) -> Void)?
    private(set) var features: LanguageServerFeatureSet = []
    var onFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    private(set) var serverInfo: LanguageServerInfo?
    var onServerInfoChange: ((LanguageServerInfo?) -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        initializationOptions: ToolingJSONValue? = nil,
        initializeTimeoutNanoseconds: UInt64 = 10_000_000_000,
        requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
        process: any RawProcessSession,
        core: any LspClientCore = RustCoreBridge()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.initializationOptions = initializationOptions
        self.initializeTimeoutNanoseconds = initializeTimeoutNanoseconds
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
        self.process = process
        self.core = core
        process.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.onError = { [weak self] data in
            Task { @MainActor [weak self] in self?.receiveError(data) }
        }
        process.onStateChange = { [weak self] event in
            Task { @MainActor [weak self] in self?.receiveStateChange(event) }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                self?.recordTermination(exitCode: exitCode)
                self?.resetTransientState()
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    func start(rootURL: URL) throws {
        transition(to: .startingProcess)
        onLog?(
            .info,
            "Starting language server",
            ([executableURL.path] + arguments).joined(separator: " ")
        )
        do {
            try process.start(ProcessRequest(
                operationID: UUID().uuidString,
                executablePath: executableURL.path,
                arguments: arguments,
                workingDirectory: rootURL.standardizedFileURL.path,
                environment: environment,
                keepsStandardInputOpen: true
            ))
            transition(to: .initializing)
            if let sessionCore = core as? any LspSessionCore {
                guard let response = sessionCore.lspSessionCreate(
                    rootURL: rootURL,
                    initializationOptions: initializationOptions
                ) else {
                    throw StdioLanguageServerSessionError.coreRejected("initialize")
                }
                sessionID = response.sessionId
                try apply(response)
            } else {
                guard let response = core.lspClientInitialize(
                    rootURL: rootURL,
                    initializationOptions: initializationOptions
                ) else {
                    throw StdioLanguageServerSessionError.coreRejected("initialize")
                }
                try apply(response)
            }
            if !isInitialized {
                scheduleInitializeTimeout()
            }
        } catch {
            failSession(error)
            throw error
        }
    }

    func synchronize(fileURL: URL, text: String, languageID: String) throws {
        guard sessionID != nil || legacyState != nil else {
            throw StdioLanguageServerSessionError.notReady
        }
        let standardizedURL = fileURL.standardizedFileURL
        let uri = standardizedURL.absoluteString
        guard isInitialized else {
            pendingDocuments[uri] = PendingDocument(
                fileURL: standardizedURL,
                text: text,
                languageID: languageID
            )
            return
        }
        if let sessionCore = core as? any LspSessionCore,
           let sessionID {
            let wasOpen = openedDocumentURIs.contains(uri)
            let response = wasOpen
                ? sessionCore.lspSessionChangeDocument(
                    sessionID: sessionID,
                    fileURL: standardizedURL,
                    text: text
                )
                : sessionCore.lspSessionOpenDocument(
                    sessionID: sessionID,
                    fileURL: standardizedURL,
                    languageID: languageID,
                    text: text
                )
            guard let response else {
                let error = StdioLanguageServerSessionError.coreRejected(
                    wasOpen ? "textDocument/didChange" : "textDocument/didOpen"
                )
                failSession(error)
                throw error
            }
            do {
                try apply(response)
                if !wasOpen { openedDocumentURIs.insert(uri) }
            } catch {
                failSession(error)
                throw error
            }
        } else if let legacyState {
            let response: RustCoreBridge.LspClientResponsePayload?
            let wasOpen = openedDocumentURIs.contains(uri)
            if wasOpen {
                response = core.lspClientChangeDocument(
                    state: legacyState,
                    fileURL: standardizedURL,
                    text: text
                )
            } else {
                response = core.lspClientOpenDocument(
                    state: legacyState,
                    fileURL: standardizedURL,
                    languageID: languageID,
                    text: text
                )
            }
            guard let response else {
                let error = StdioLanguageServerSessionError.coreRejected(
                    wasOpen ? "textDocument/didChange" : "textDocument/didOpen"
                )
                failSession(error)
                throw error
            }
            do {
                try apply(response)
                if !wasOpen { openedDocumentURIs.insert(uri) }
            } catch {
                failSession(error)
                throw error
            }
        }
    }

    func closeDocument(_ fileURL: URL) {
        let standardizedURL = fileURL.standardizedFileURL
        let uri = standardizedURL.absoluteString
        pendingDocuments[uri] = nil
        guard openedDocumentURIs.contains(uri) else { return }
        if let sessionCore = core as? any LspSessionCore,
           let sessionID {
            guard let response = sessionCore.lspSessionCloseDocument(
               sessionID: sessionID,
               fileURL: standardizedURL
            ) else {
                failSession(StdioLanguageServerSessionError.coreRejected("textDocument/didClose"))
                return
            }
            do {
                try apply(response)
                openedDocumentURIs.remove(uri)
            } catch {
                failSession(error)
            }
        } else if let legacyState {
            guard let response = core.lspClientCloseDocument(
                    state: legacyState,
                    fileURL: standardizedURL
            ) else {
                failSession(StdioLanguageServerSessionError.coreRejected("textDocument/didClose"))
                return
            }
            do {
                try apply(response)
                openedDocumentURIs.remove(uri)
            } catch {
                failSession(error)
            }
        }
    }

    func completions(
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try requestFeature(
            method: "textDocument/completion",
            fileURL: fileURL,
            position: position
        ) { result in
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
        try requestFeature(
            method: "textDocument/hover",
            fileURL: fileURL,
            position: position
        ) { result in
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
        try requestFeature(method: method, fileURL: fileURL, position: position) { result in
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
        try requestFeature(
            method: "textDocument/rename",
            fileURL: fileURL,
            position: position,
            newName: newName
        ) { result in
            completion(result.flatMap {
                Self.decodeEventResult($0, as: RustCoreBridge.LspWorkspaceEditPayload.self)
            }.map { $0.makeModel() })
        }
    }

    func format(
        fileURL: URL,
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) throws {
        try requestFeature(
            method: "textDocument/formatting",
            fileURL: fileURL,
            position: nil
        ) { result in
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
        try requestFeature(
            method: "textDocument/codeAction",
            fileURL: fileURL,
            position: nil,
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
        try requestFeature(
            method: "completionItem/resolve",
            fileURL: fileURL,
            position: nil,
            completionItem: item
        ) { result in
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
        try requestFeature(
            method: "codeAction/resolve",
            fileURL: fileURL,
            position: nil,
            codeAction: action
        ) { result in
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
        try requestFeature(
            method: "workspace/executeCommand",
            fileURL: fileURL,
            position: nil,
            command: command
        ) { result in
            switch result {
            case .success(let event):
                if let error = event.error {
                    completion(.failure(StdioLanguageServerSessionError.serverError(error)))
                } else {
                    completion(.success(()))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func stop() {
        guard process.isRunning else {
            failPendingRequests(with: StdioLanguageServerSessionError.sessionStopped)
            resetTransientState()
            transition(to: .stopped)
            return
        }
        guard !isStopping, isInitialized else {
            forceStop(pendingError: StdioLanguageServerSessionError.sessionStopped)
            return
        }
        failPendingRequests(with: StdioLanguageServerSessionError.sessionStopped)
        isStopping = true
        transition(to: .stopping)
        do {
            if let sessionCore = core as? any LspSessionCore,
               let sessionID,
               let response = sessionCore.lspSessionShutdown(sessionID: sessionID) {
                try apply(response)
            } else if let legacyState,
                      let response = core.lspClientShutdown(state: legacyState) {
                try apply(response)
            } else {
                forceStop(pendingError: StdioLanguageServerSessionError.sessionStopped)
                return
            }
        } catch {
            failSession(error)
            return
        }
        shutdownFallbackTask?.cancel()
        // The task intentionally retains the session after its manager removes it.
        shutdownFallbackTask = Task { @MainActor [self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            forceStop(pendingError: StdioLanguageServerSessionError.sessionStopped)
        }
    }

    private func apply(_ response: RustCoreBridge.LspClientResponsePayload) throws {
        try validateInitializeEvents(response.events)
        for message in response.messages {
            try sendRawJSON(message)
        }
        legacyState = response.state
        updateFeatures(from: response.state)
        try handle(response.events)
    }

    private func apply(_ response: RustCoreBridge.LspSessionResponsePayload) throws {
        try validateInitializeEvents(response.events)
        for message in response.messages {
            try sendRawJSON(message)
        }
        updateFeatures(capabilityNames: response.serverCapabilities)
        try handle(response.events)
    }

    private func handle(_ events: [RustCoreBridge.LspClientEventPayload]) throws {
        for event in events {
            if let requestID = event.requestId,
               let pending = responseHandlers.removeValue(forKey: requestID) {
                responseTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                pending.completion(.success(event))
            }
            if event.method == "initialize" {
                try handleInitialize(event)
            }
            if event.method == "shutdown" {
                forceStop(pendingError: StdioLanguageServerSessionError.sessionStopped)
                return
            }
            if event.kind == "diagnostics",
               let uri = event.uri,
               let url = URL(string: uri),
               let diagnostics = event.diagnostics {
                onDiagnostics?(url.standardizedFileURL, diagnostics.map { $0.makeModel() })
            }
        }
    }

    private func requestFeature(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition?,
        newName: String? = nil,
        range: LanguageServerRange? = nil,
        diagnostics: [LanguageServerDiagnostic] = [],
        completionItem: LanguageServerCompletionItem? = nil,
        codeAction: LanguageServerCodeAction? = nil,
        command: LanguageServerCommand? = nil,
        completion: @escaping (Result<RustCoreBridge.LspClientEventPayload, Error>) -> Void
    ) throws {
        guard isInitialized else {
            throw StdioLanguageServerSessionError.notReady
        }
        guard openedDocumentURIs.contains(fileURL.standardizedFileURL.absoluteString) else {
            throw StdioLanguageServerSessionError.documentNotOpen
        }
        let messages: [String]
        let events: [RustCoreBridge.LspClientEventPayload]
        var updatedLegacyState: ToolingJSONValue?
        var updatedCapabilityNames: [String]?
        if let sessionCore = core as? any LspSessionCore,
           let sessionID,
           let response = sessionCore.lspSessionRequest(
               sessionID: sessionID,
               fileURL: fileURL,
               method: method,
               position: position,
               newName: newName,
               range: range,
               diagnostics: diagnostics,
               completionItem: completionItem,
               codeAction: codeAction,
               command: command
           ) {
            updatedCapabilityNames = response.serverCapabilities
            messages = response.messages
            events = response.events
        } else if let legacyState,
                  let response = core.lspClientRequest(
                    state: legacyState,
                    fileURL: fileURL,
                    method: method,
                    position: position,
                    newName: newName,
                    range: range,
                    diagnostics: diagnostics,
                    completionItem: completionItem,
                    codeAction: codeAction,
                    command: command
                  ) {
            updatedLegacyState = response.state
            messages = response.messages
            events = response.events
        } else {
            throw StdioLanguageServerSessionError.requestRejected
        }
        guard let requestID = messages.lazy.compactMap({ Self.requestID(from: $0) }).first else {
            throw StdioLanguageServerSessionError.missingRequestID
        }
        responseHandlers[requestID] = PendingResponse(
            method: method,
            fileURL: fileURL.standardizedFileURL,
            completion: completion
        )
        do {
            for message in messages {
                try sendRawJSON(message)
            }
            if let updatedLegacyState {
                legacyState = updatedLegacyState
                updateFeatures(from: updatedLegacyState)
            } else if let updatedCapabilityNames {
                updateFeatures(capabilityNames: updatedCapabilityNames)
            }
            try handle(events)
        } catch {
            responseHandlers[requestID] = nil
            responseTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            failSession(error)
            throw error
        }
        if responseHandlers[requestID] != nil {
            scheduleRequestTimeout(requestID: requestID)
        }
    }

    private func flushPendingDocuments() throws {
        let documents = pendingDocuments.sorted { $0.key < $1.key }
        for (uri, document) in documents {
            try synchronize(
                fileURL: document.fileURL,
                text: document.text,
                languageID: document.languageID
            )
            pendingDocuments[uri] = nil
        }
    }

    private func sendRawJSON(_ message: String) throws {
        guard process.isRunning else {
            throw StdioLanguageServerSessionError.transportFailure("Language server process is not running.")
        }
        if let frame = core.lspFrameMessage(message)?.frame,
           let data = frame.data(using: .utf8) {
            do {
                try process.send(data)
            } catch {
                throw StdioLanguageServerSessionError.transportFailure(error.localizedDescription)
            }
            return
        }
        guard let body = message.data(using: .utf8) else {
            throw StdioLanguageServerSessionError.transportFailure("Could not encode LSP message as UTF-8.")
        }
        var fallback = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        fallback.append(body)
        do {
            try process.send(fallback)
        } catch {
            throw StdioLanguageServerSessionError.transportFailure(error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        guard !isFailed else { return }
        receiveServerData(data)
    }

    private func receiveServerData(_ data: Data) {
        guard let parsed = core.lspParseServerMessages(
            buffer: Array(readBuffer),
            chunk: Array(data)
        ) else {
            failSession(StdioLanguageServerSessionError.protocolFailure(
                "Rust core could not parse the language server output."
            ))
            return
        }
        readBuffer = Data(parsed.buffer)
        do {
            for message in parsed.messages {
                if let sessionCore = core as? any LspSessionCore,
                   let sessionID {
                    guard let response = sessionCore.lspSessionApplyServerMessage(
                        sessionID: sessionID,
                        message: message
                    ) else {
                        throw StdioLanguageServerSessionError.coreRejected("server message")
                    }
                    try apply(response)
                } else if let legacyState {
                    guard let response = core.lspClientApplyServerMessage(
                        state: legacyState,
                        message: message
                    ) else {
                        throw StdioLanguageServerSessionError.coreRejected("server message")
                    }
                    try apply(response)
                } else {
                    throw StdioLanguageServerSessionError.notReady
                }
            }
        } catch {
            failSession(error)
        }
    }

    private func receiveError(_ data: Data) {
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        onLog?(.warning, "Language server stderr", raw)
    }

    private func receiveStateChange(_ event: ProcessLifecycleEvent) {
        switch event.state {
        case .starting:
            if state == .stopped { transition(to: .startingProcess) }
            onLog?(.info, "Language server process is starting", nil)
        case .running:
            if state == .startingProcess { transition(to: .initializing) }
            onLog?(.info, "Language server process is running", nil)
        case .stopping:
            if !isFailed { transition(to: .stopping) }
            onLog?(.info, "Language server process is stopping", event.message)
        case .finished:
            onLog?(
                isStopping ? .info : .warning,
                "Language server process finished",
                event.message ?? exitCodeDetail(event.exitCode)
            )
            if let exitCode = event.exitCode {
                recordTermination(exitCode: exitCode)
            }
        case .failed:
            failSession(
                StdioLanguageServerSessionError.transportFailure(
                    event.message ?? "Language server process failed to start."
                ),
                exitCode: event.exitCode,
                stopProcess: false
            )
        }
    }

    private func recordTermination(exitCode: Int32) {
        guard !isFailed, state != .stopped else { return }
        if isStopping {
            failPendingRequests(with: StdioLanguageServerSessionError.sessionStopped)
            resetTransientState()
            transition(to: .stopped)
            onLog?(.info, "Language server terminated", exitCodeDetail(exitCode))
        } else {
            failSession(
                StdioLanguageServerSessionError.sessionTerminated(exitCode),
                exitCode: exitCode,
                stopProcess: false
            )
        }
    }

    private func exitCodeDetail(_ exitCode: Int32?) -> String? {
        guard let exitCode else { return nil }
        return "exit code \(exitCode)"
    }

    private func resetTransientState() {
        initializeTimeoutTask?.cancel()
        initializeTimeoutTask = nil
        shutdownFallbackTask?.cancel()
        shutdownFallbackTask = nil
        responseTimeoutTasks.values.forEach { $0.cancel() }
        responseTimeoutTasks = [:]
        if !responseHandlers.isEmpty {
            failPendingRequests(with: StdioLanguageServerSessionError.sessionStopped)
        }
        if let sessionCore = core as? any LspSessionCore,
           let sessionID {
            sessionCore.lspSessionDestroy(sessionID: sessionID)
        }
        sessionID = nil
        legacyState = nil
        readBuffer = Data()
        openedDocumentURIs = []
        pendingDocuments = [:]
        isInitialized = false
        isStopping = false
        if !features.isEmpty {
            features = []
            onFeaturesChange?([])
        }
        if serverInfo != nil {
            serverInfo = nil
            onServerInfoChange?(nil)
        }
    }

    private func forceStop(pendingError: Error) {
        shutdownFallbackTask?.cancel()
        shutdownFallbackTask = nil
        failPendingRequests(with: pendingError)
        isStopping = true
        if !isFailed { transition(to: .stopping) }
        process.stop()
        resetTransientState()
        if !isFailed { transition(to: .stopped) }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func transition(to updatedState: LanguageServerSessionState) {
        guard state != updatedState else { return }
        state = updatedState
        onStateChange?(updatedState)
    }

    private func failSession(
        _ error: Error,
        exitCode: Int32? = nil,
        stopProcess: Bool = true
    ) {
        guard !isFailed else { return }
        initializeTimeoutTask?.cancel()
        initializeTimeoutTask = nil
        failPendingRequests(with: error)
        let message = error.localizedDescription
        transition(to: .failed(exitCode: exitCode, message: message))
        onLog?(.error, "Language server session failed", message)
        if stopProcess, process.isRunning {
            process.stop()
        }
        resetTransientState()
    }

    private func failPendingRequests(with error: Error) {
        let pending = responseHandlers
        responseHandlers = [:]
        let timeoutTasks = responseTimeoutTasks.values
        responseTimeoutTasks = [:]
        timeoutTasks.forEach { $0.cancel() }
        for response in pending.values {
            response.completion(.failure(error))
        }
    }

    private func handleInitialize(_ event: RustCoreBridge.LspClientEventPayload) throws {
        let result = try validatedInitializeResult(event)
        initializeTimeoutTask?.cancel()
        initializeTimeoutTask = nil
        isInitialized = true
        let initializedServerInfo = Self.serverInfo(from: result["serverInfo"])
        transition(to: .ready)
        if initializedServerInfo != serverInfo {
            serverInfo = initializedServerInfo
            onServerInfoChange?(initializedServerInfo)
        }
        onLog?(.info, "Language server is ready", initializedServerInfo?.name)
        try flushPendingDocuments()
    }

    private func validateInitializeEvents(
        _ events: [RustCoreBridge.LspClientEventPayload]
    ) throws {
        for event in events where event.method == "initialize" {
            _ = try validatedInitializeResult(event)
        }
    }

    private func validatedInitializeResult(
        _ event: RustCoreBridge.LspClientEventPayload
    ) throws -> [String: ToolingJSONValue] {
        if event.kind == "error" || event.error != nil {
            throw StdioLanguageServerSessionError.initializeFailed(
                event.error ?? "Language server rejected initialize."
            )
        }
        guard event.kind == "response",
              case .object(let result)? = event.result,
              case .object = result["capabilities"] else {
            throw StdioLanguageServerSessionError.invalidInitializeResult
        }
        return result
    }

    private func scheduleInitializeTimeout() {
        initializeTimeoutTask?.cancel()
        let timeout = initializeTimeoutNanoseconds
        initializeTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard let self, !self.isInitialized, !self.isStopping, !self.isFailed else { return }
            self.failSession(StdioLanguageServerSessionError.initializeTimedOut)
        }
    }

    private func scheduleRequestTimeout(requestID: String) {
        responseTimeoutTasks[requestID]?.cancel()
        let timeout = requestTimeoutNanoseconds
        responseTimeoutTasks[requestID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard let self,
                  let pending = self.responseHandlers.removeValue(forKey: requestID) else { return }
            self.responseTimeoutTasks[requestID] = nil
            let timeoutError = StdioLanguageServerSessionError.requestTimedOut(
                method: pending.method,
                fileURL: pending.fileURL
            )
            var transportError: Error?
            do {
                try self.sendCancellation(requestID: requestID)
            } catch {
                transportError = error
            }
            pending.completion(.failure(timeoutError))
            if let transportError {
                self.failSession(transportError)
            }
        }
    }

    private func sendCancellation(requestID: String) throws {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "$/cancelRequest",
            "params": ["id": requestID]
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw StdioLanguageServerSessionError.protocolFailure(
                "Could not encode cancellation for LSP request \(requestID)."
            )
        }
        guard let message = String(data: data, encoding: .utf8) else {
            throw StdioLanguageServerSessionError.protocolFailure(
                "Could not encode cancellation for LSP request \(requestID)."
            )
        }
        try sendRawJSON(message)
    }

    private static func serverInfo(from value: ToolingJSONValue?) -> LanguageServerInfo? {
        guard case .object(let object)? = value,
              case .string(let name)? = object["name"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let version: String?
        if case .string(let value)? = object["version"], !value.isEmpty {
            version = value
        } else {
            version = nil
        }
        return LanguageServerInfo(name: name, version: version)
    }

    private func updateFeatures(from state: ToolingJSONValue) {
        guard case .object(let object) = state,
              case .array(let capabilityValues)? = object["serverCapabilities"] else { return }
        let names = capabilityValues.compactMap { value -> String? in
            guard case .string(let name) = value else { return nil }
            return name
        }
        updateFeatures(capabilityNames: names)
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

    private static func requestID(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return nil }
        if let string = id as? String { return string }
        if let number = id as? NSNumber { return number.stringValue }
        return nil
    }

    private static func decodeEventResult<Payload: Decodable>(
        _ event: RustCoreBridge.LspClientEventPayload,
        as _: Payload.Type
    ) -> Result<Payload, Error> {
        if let error = event.error {
            return .failure(StdioLanguageServerSessionError.serverError(error))
        }
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

    private struct PendingDocument {
        let fileURL: URL
        let text: String
        let languageID: String
    }

    private struct PendingResponse {
        let method: String
        let fileURL: URL
        let completion: (Result<RustCoreBridge.LspClientEventPayload, Error>) -> Void
    }

    private enum StdioLanguageServerSessionError: LocalizedError {
        case notReady
        case documentNotOpen
        case requestRejected
        case missingRequestID
        case missingResult
        case coreRejected(String)
        case initializeFailed(String)
        case invalidInitializeResult
        case initializeTimedOut
        case transportFailure(String)
        case protocolFailure(String)
        case requestTimedOut(method: String, fileURL: URL)
        case sessionTerminated(Int32)
        case sessionStopped
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                "Language server is not ready."
            case .documentNotOpen:
                "Document is not open in the language server."
            case .requestRejected:
                "Language server request was rejected by Rust core."
            case .missingRequestID:
                "Language server request did not include a JSON-RPC request ID."
            case .missingResult:
                "Language server response did not include a result."
            case .coreRejected(let operation):
                "Rust core rejected the LSP \(operation) operation."
            case .initializeFailed(let message):
                "Language server initialize failed: \(message)"
            case .invalidInitializeResult:
                "Language server initialize returned an invalid result."
            case .initializeTimedOut:
                "Language server initialize timed out."
            case .transportFailure(let message):
                "Language server transport failed: \(message)"
            case .protocolFailure(let message):
                "Language server protocol failed: \(message)"
            case .requestTimedOut(let method, let fileURL):
                "Language server request \(method) timed out for \(fileURL.lastPathComponent)."
            case .sessionTerminated(let exitCode):
                "Language server terminated unexpectedly with exit code \(exitCode)."
            case .sessionStopped:
                "Language server session stopped before the request completed."
            case .serverError(let message):
                message
            }
        }
    }
}
