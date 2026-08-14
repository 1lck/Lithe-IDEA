import Foundation
import LitheCoreContracts
import LitheModuleAPI

extension RustCoreBridge: LanguageServerRuntimeCore {
    func startLanguageServer(
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
    ) -> Result<LanguageServerRuntimeStart, LanguageServerRuntimeFailure> {
        lspStartServer(
            providerID: providerID,
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            rootURL: rootURL,
            workingDirectoryURL: workingDirectoryURL,
            initializationOptions: initializationOptions,
            runtimeExecutableURL: runtimeExecutableURL,
            cacheDirectoryURL: cacheDirectoryURL,
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
    ) -> Result<Void, LanguageServerRuntimeFailure> {
        lspSyncDocument(
            sessionID: sessionID,
            fileURL: fileURL,
            languageID: languageID,
            text: text
        ).mapError(Self.runtimeFailure)
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
            completionItem: completionItem,
            codeAction: codeAction,
            command: command
        ).map { LanguageServerRuntimeOperation(operationID: $0.operationId) }
            .mapError(Self.runtimeFailure)
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
                        message: $0.message,
                        underlyingMessage: $0.underlyingMessage,
                        processExitCode: $0.processExitCode
                    )
                },
                capabilities: event.capabilities,
                serverInfo: event.serverInfo.map {
                    LanguageServerInfo(name: $0.name, version: $0.version)
                },
                level: event.level,
                message: event.message,
                detail: event.detail
            )
        }
    }

    func destroyLanguageServer(sessionID: String) {
        lspDestroyServer(sessionID: sessionID)
    }

    private static func runtimeFailure(_ error: CoreCallError) -> LanguageServerRuntimeFailure {
        LanguageServerRuntimeFailure(
            code: error.code,
            message: error.message,
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
