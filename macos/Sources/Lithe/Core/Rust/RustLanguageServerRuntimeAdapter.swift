import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension RustCoreBridge: LanguageServerRuntimeCore {
    func observingPluginStartup(_ handoff: PluginOperationHandoff) -> any LanguageServerRuntimeCore {
        var runtime = self; runtime.startupOperation = handoff; return runtime
    }
    func loggingRuntime(role: LanguageServerLogRole, logSubject: String?, pluginID: String?) -> any LanguageServerRuntimeCore {
        var runtime = self
        runtime.logRole = role; runtime.logSubject = logSubject; runtime.logPluginID = pluginID
        return runtime
    }
    func emitCoreLog(_ record: CoreLogRecord) { coreLogSink?.emit(record) }

    func requiresBackgroundLanguageServerStart(rootURL: URL) -> Bool {
        remoteWorkspaces?.resolve(rootURL) != nil
    }

    func startLanguageServer(
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        workingDirectoryURL: URL,
        initializationOptions: ToolingJSONValue?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: workingDirectoryURL,
            initializationOptions: initializationOptions,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(
                sessionID: $0.sessionId,
                state: $0.state,
                processID: $0.processId
            )
        }.mapError(Self.runtimeFailure)
    }

    func stopLanguageServer(sessionID: String) {
        lspStopServer(sessionID: sessionID)
    }

    func syncLanguageServerDocument(
        sessionID: String,
        fileURL: URL,
        languageID: String,
        text: String
    ) -> Result<LanguageServerDocumentSync, LanguageServerRuntimeFailure> {
        lspSyncDocument(
            sessionID: sessionID,
            fileURL: fileURL,
            languageID: languageID,
            text: text
        ).map {
            LanguageServerDocumentSync(
                documentVersion: $0.documentVersion,
                changed: $0.changed
            )
        }.mapError(Self.runtimeFailure)
    }

    func notifyLanguageServerWorkspaceFilesChanged(
        sessionID: String,
        changes: [LanguageServerWorkspaceFileChange]
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        lspWorkspaceFilesChanged(sessionID: sessionID, changes: changes)
            .mapError(Self.runtimeFailure)
    }

    func saveLanguageServerDocument(sessionID: String, fileURL: URL, text: String) -> Result<Bool, LanguageServerRuntimeFailure> {
        lspSaveDocument(sessionID: sessionID, fileURL: fileURL, text: text).mapError(Self.runtimeFailure)
    }

    func closeLanguageServerDocument(sessionID: String, fileURL: URL) {
        lspCloseDocument(sessionID: sessionID, fileURL: fileURL)
    }

    func requestLanguageServerOperation(
        sessionID: String,
        operation: LanguageServerOperation,
        fileURL: URL?,
        virtualURI: String?,
        position: LanguageServerPosition?,
        newName: String?,
        range: LanguageServerRange?,
        diagnostics: [LanguageServerDiagnostic],
        completionContext: LanguageServerCompletionContext?,
        completionItem: LanguageServerCompletionItem?,
        codeAction: LanguageServerCodeAction?,
        command: LanguageServerCommand?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspRequest(
            sessionID: sessionID,
            operation: operation,
            fileURL: fileURL,
            virtualURI: virtualURI,
            position: position,
            newName: newName,
            range: range,
            diagnostics: diagnostics,
            completionContext: completionContext,
            completionItem: completionItem,
            codeAction: codeAction,
            command: command
        ).map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func requestBuildProvider(
        sessionID: String,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspBuildRequest(sessionID: sessionID, method: method, params: params, timeout: timeout)
            .map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func requestVcsProvider(
        sessionID: String,
        vcs: String,
        operation: String,
        root: String,
        tool: String?,
        arguments: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspVcsRequest(
            sessionID: sessionID, vcs: vcs, operation: operation, root: root, tool: tool,
            arguments: arguments, timeout: timeout
        )
        .map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
        .mapError(Self.runtimeFailure)
    }

    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        startPluginLanguageServer(
            pluginID: pluginID, providerID: providerID, executableURL: executableURL, arguments: arguments,
            environment: environment, rootURL: rootURL, initializationOptions: initializationOptions,
            workspaceConfiguration: nil, hostServices: [],
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        )
    }

    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue?,
        hostServices: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            pluginID: pluginID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: rootURL,
            initializationOptions: initializationOptions,
            workspaceConfiguration: workspaceConfiguration,
            hostServices: hostServices,
            editorOptions: .macOS,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(sessionID: $0.sessionId, state: $0.state, processID: $0.processId)
        }.mapError(Self.runtimeFailure)
    }

    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue?,
        sessionPolicy: ToolingJSONValue,
        hostServices: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            pluginID: pluginID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: rootURL,
            initializationOptions: initializationOptions,
            workspaceConfiguration: workspaceConfiguration,
            hostServices: hostServices,
            sessionPolicy: sessionPolicy,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(sessionID: $0.sessionId, state: $0.state, processID: $0.processId)
        }.mapError(Self.runtimeFailure)
    }

    func requestToolchainProvider(
        sessionID: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspToolchainRequest(sessionID: sessionID, params: params, timeout: timeout)
            .map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func requestKeymapImportProvider(
        sessionID: String, providerID: String, snapshotID: String, timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspKeymapImportRequest(sessionID: sessionID, providerID: providerID, snapshotID: snapshotID, timeout: timeout)
            .map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func startPluginKeymapImportBackend(
        pluginID: String, providerID: String, executableURL: URL, arguments: [String],
        environment: [String: String], rootURL: URL, initializationOptions: ToolingJSONValue?,
        hostServices: [String], toolchainProviders: [String], keymapImportProviders: [String],
        initializeTimeout: TimeInterval, requestTimeout: TimeInterval, shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID, pluginID: pluginID, executableURL: executableURL,
            arguments: arguments, environment: environment, rootURL: rootURL, workingDirectoryURL: rootURL,
            initializationOptions: initializationOptions, hostServices: hostServices, editorOptions: .macOS,
            toolchainProviders: toolchainProviders, keymapImportProviders: keymapImportProviders,
            initializeTimeout: initializeTimeout, requestTimeout: requestTimeout, shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(sessionID: $0.sessionId, state: $0.state, processID: $0.processId)
        }.mapError(Self.runtimeFailure)
    }

    func startPluginToolchainBackend(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        toolchainProviders: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            pluginID: pluginID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: rootURL,
            initializationOptions: initializationOptions,
            hostServices: hostServices,
            editorOptions: .macOS,
            toolchainProviders: toolchainProviders,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(sessionID: $0.sessionId, state: $0.state, processID: $0.processId)
        }.mapError(Self.runtimeFailure)
    }

    func startPluginLanguageServer(
        pluginID: String,
        providerID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        rootURL: URL,
        initializationOptions: ToolingJSONValue?,
        hostServices: [String],
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        shutdownTimeout: TimeInterval
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            pluginID: pluginID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: rootURL,
            initializationOptions: initializationOptions,
            hostServices: hostServices,
            editorOptions: .macOS,
            initializeTimeout: initializeTimeout,
            requestTimeout: requestTimeout,
            shutdownTimeout: shutdownTimeout
        ).map {
            LanguageServerRuntimeStart(sessionID: $0.sessionId, state: $0.state, processID: $0.processId)
        }.mapError(Self.runtimeFailure)
    }

    func respondToPluginHostRequest(
        sessionID: String,
        hostRequestID: String,
        outcome: Result<ToolingJSONValue, PluginHostRequestFailure>
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        let result: ToolingJSONValue?
        let failure: PluginHostRequestFailure?
        switch outcome {
        case .success(let value): result = value; failure = nil
        case .failure(let reason): result = nil; failure = reason
        }
        return lspHostResponse(
            sessionID: sessionID, hostRequestID: hostRequestID, result: result,
            failureMessage: failure?.message, failureCode: failure?.code, failureDetails: failure?.details
        ).mapError(Self.runtimeFailure)
    }

    func notifyPluginBackend(
        sessionID: String,
        method: String,
        params: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure> {
        lspHostNotify(sessionID: sessionID, method: method, params: params)
            .mapError(Self.runtimeFailure)
    }

    func configurePluginFunctionRelay(
        _ snapshot: PluginFunctionRelaySnapshot
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        lspConfigureFunctionRelay(snapshot).mapError(Self.runtimeFailure)
    }

    func updateWorkspaceConfiguration(
        sessionID: String,
        configuration: ToolingJSONValue
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        lspUpdateWorkspaceConfiguration(sessionID: sessionID, configuration: configuration)
            .mapError(Self.runtimeFailure)
    }

    func requestPluginFunction(
        sessionID: String,
        pluginID: String,
        functionID: String,
        params: ToolingJSONValue,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspFunctionRequest(
            sessionID: sessionID, pluginID: pluginID, functionID: functionID, params: params, timeout: timeout
        ).map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func requestPluginFunction(
        sessionID: String,
        pluginID: String,
        functionID: String,
        params: ToolingJSONValue,
        context: PluginWorkspaceContextReference?,
        timeout: TimeInterval
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspFunctionRequest(
            sessionID: sessionID, pluginID: pluginID, functionID: functionID, params: params,
            context: context, timeout: timeout
        ).map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func pluginServerRequest(
        sessionID: String,
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue,
        timeout: TimeInterval?
    ) -> Result<LanguageServerRuntimeOperation, LanguageServerRuntimeFailure> {
        lspPluginServerRequest(
            sessionID: sessionID, pluginID: pluginID, serverID: serverID, method: method, params: params,
            timeout: timeout
        ).map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
    }

    func pluginServerNotify(
        sessionID: String,
        pluginID: String,
        serverID: String,
        method: String,
        params: ToolingJSONValue
    ) -> Result<Bool, LanguageServerRuntimeFailure> {
        lspPluginServerNotify(
            sessionID: sessionID, pluginID: pluginID, serverID: serverID, method: method, params: params
        ).mapError(Self.runtimeFailure)
    }

    func cancelLanguageServerOperation(sessionID: String, operationID: String) {
        lspCancelOperation(sessionID: sessionID, operationID: operationID)
    }

    func pollLanguageServerEvents(sessionID: String) -> [LanguageServerRuntimeEvent] {
        lspPollEvents(sessionID: sessionID).map { event in
            LanguageServerRuntimeEvent(
                type: event.type,
                state: event.state,
                operationID: event.operationId,
                uri: event.uri,
                diagnostics: event.diagnostics?.map { $0.makeModel() },
                result: event.result,
                error: event.error.map {
                    LanguageServerRuntimeError(
                        code: $0.code,
                        stage: $0.stage,
                        message: $0.message,
                        underlyingMessage: $0.underlyingMessage,
                        processExitCode: $0.processExitCode,
                        pluginErrorCode: $0.pluginErrorCode,
                        details: $0.details
                    )
                },
                capabilities: event.capabilities,
                serverInfo: event.serverInfo.map {
                    LanguageServerInfo(name: $0.name, version: $0.version)
                },
                level: event.level,
                message: event.message,
                detail: event.detail,
                method: event.method,
                coreLog: event.event.flatMap { id in
                    guard let level = event.catalogLevel, let channel = event.channel, let fields = event.fields else { return nil }
                    return CoreLogRecord(event: id, level: level, channel: channel, op: event.operationId, fields: fields)
                }, pluginID: event.pluginId, role: event.role
            )
        }
    }

    func destroyLanguageServer(sessionID: String) {
        lspDestroyServer(sessionID: sessionID)
        releaseLogSession?(sessionID)
    }

    private static func runtimeFailure(_ error: CoreCallError) -> LanguageServerRuntimeFailure {
        // Only translate our own request validation; upstream diagnostics stay intact.
        let message: String
        switch (error.code, error.message) {
        case ("invalid_request", "Invalid completion trigger kind"):
            message = L10n.string("Invalid completion trigger kind")
        case ("invalid_request", "Completion trigger character is required"):
            message = L10n.string("Completion trigger character is required")
        default:
            message = error.message
        }
        return LanguageServerRuntimeFailure(
            code: error.code,
            message: message,
            details: error.details
        )
    }
}

extension RustCoreBridge: BuiltinLanguageFeatureCore {
    package var isBuiltinLanguageFeatureAvailable: Bool { isAvailable }
}

extension ManagedProcessRegistry: LanguageServerProcessRegistry {
    func registerLanguageServerProcess(pid: Int32, moduleID: ModuleID) {
        register(pid: pid, category: .languageServer, moduleID: moduleID)
    }

    func unregisterLanguageServerProcess(pid: Int32, moduleID: ModuleID) {
        unregister(pid: pid, category: .languageServer, moduleID: moduleID)
    }
}
