import Foundation
import LitheCoreContracts

/// DAP session projected from the shared Rust Debug Core. This type owns only
/// callback correlation and UI model conversion; framing and state reduction
/// stay behind `DebugProtocolCore`, while native I/O stays in the transport.
@MainActor
public final class CoreDebugAdapterProtocolSession: DebugAdapterControllingSession,
    DebugAdapterRunInTerminalSession {
    private typealias OperationHandler = (Result<DebugCoreOperationResult, Error>) -> Void

    private struct PendingOperation {
        let handler: OperationHandler
        let deadline: any DebugOperationDeadline
    }

    private struct PendingRunInTerminalRequest {
        let deadline: any DebugOperationDeadline
    }

    private let adapterID: String
    private let transport: any DebugAdapterTransport
    private let core: any DebugProtocolCore
    private let sessionID: String
    private let deadlineScheduler: any DebugOperationDeadlineScheduling
    private let operationTimeoutMilliseconds: Int
    private var operationHandlers: [String: PendingOperation] = [:]
    private var pendingRunInTerminalRequests: [String: PendingRunInTerminalRequest] = [:]
    private var ownsCoreSession = false
    private var isStopping = false

    public private(set) var state: DebugAdapterState = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }
    public var onStateChange: ((DebugAdapterState) -> Void)?
    public var onEvent: ((DebugAdapterEvent) -> Void)?
    public var onRunInTerminalRequest: DebugRunInTerminalRequestHandler?
    public var isRunning: Bool { transport.isRunning }
    public private(set) var capabilities: DebugAdapterCapabilities = .unknown

    public init(
        adapterID: String,
        transport: any DebugAdapterTransport,
        core: any DebugProtocolCore,
        sessionID: String = UUID().uuidString,
        deadlineScheduler: any DebugOperationDeadlineScheduling,
        operationTimeoutMilliseconds: Int = 10_000
    ) {
        self.adapterID = adapterID
        self.transport = transport
        self.core = core
        self.sessionID = sessionID
        self.deadlineScheduler = deadlineScheduler
        self.operationTimeoutMilliseconds = max(1, operationTimeoutMilliseconds)
        transport.onData = { [weak self] data in self?.receive(data) }
        transport.onErrorOutput = { [weak self] data in
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            self?.onEvent?(.output(category: "stderr", output: text))
        }
        transport.onTermination = { [weak self] code in self?.transportTerminated(exitCode: code) }
    }

    public func start(rootURL: URL) throws {
        guard state == .idle || state == .terminated || state == .failed else { return }
        isStopping = false
        operationHandlers = [:]
        discardPendingRunInTerminalRequests()
        capabilities = .unknown
        try transport.start(rootURL: rootURL.standardizedFileURL)
        do {
            let update = try core.createDebugSession(
                sessionID: sessionID,
                adapterID: adapterID,
                rootPath: rootURL.standardizedFileURL.path,
                supportsRunInTerminalRequest: onRunInTerminalRequest != nil
            )
            ownsCoreSession = true
            try apply(update)
        } catch {
            transport.stop()
            releaseCoreSession()
            state = .failed
            throw error
        }
    }

    public func stop() {
        guard state != .idle || transport.isRunning || ownsCoreSession else { return }
        isStopping = true
        failPendingRunInTerminalRequests(DebugAdapterProtocolError.stopped)
        if ownsCoreSession, transport.isRunning,
           let update = try? core.disconnectDebugSession(sessionID: sessionID) {
            try? apply(update)
        }
        transport.stop()
        releaseCoreSession()
        failPendingOperations(DebugAdapterProtocolError.stopped)
        state = .idle
        capabilities = .unknown
        isStopping = false
    }

    public func launch(_ configuration: DebugLaunchConfiguration) throws {
        guard ownsCoreSession else { throw DebugAdapterProtocolError.notReady }
        let operationID = UUID().uuidString
        let update = try core.launchDebugSession(
            sessionID: sessionID,
            operationID: operationID,
            configuration: configuration
        )
        try apply(update)
    }

    public func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {
        guard ownsCoreSession else { return }
        do {
            try apply(core.setDebugBreakpoints(
                sessionID: sessionID,
                sourcePath: fileURL.standardizedFileURL.path,
                breakpoints: breakpoints
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
        }
    }

    public func setExceptionBreakpoints(_ breakpoints: [DebugExceptionBreakpoint]) {
        guard ownsCoreSession else { return }
        do {
            try apply(core.setDebugExceptionBreakpoints(
                sessionID: sessionID,
                breakpoints: breakpoints
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
        }
    }

    public func setFunctionBreakpoints(_ breakpoints: [DebugFunctionBreakpoint]) {
        guard ownsCoreSession else { return }
        do {
            try apply(core.setDebugFunctionBreakpoints(
                sessionID: sessionID,
                breakpoints: breakpoints
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
        }
    }

    public func setDataBreakpoints(_ breakpoints: [DebugDataBreakpoint]) {
        guard ownsCoreSession else { return }
        do {
            try apply(core.setDebugDataBreakpoints(
                sessionID: sessionID,
                breakpoints: breakpoints
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
        }
    }

    public func requestDataBreakpointInfo(
        name: String,
        variablesReference: Int?,
        frameID: Int?,
        completion: @escaping (Result<DebugDataBreakpointInfo, Error>) -> Void
    ) {
        guard ownsCoreSession else {
            completion(.failure(DebugAdapterProtocolError.stopped))
            return
        }
        guard capabilities.supportsDataBreakpoints else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("data breakpoints")))
            return
        }
        let operationID = UUID().uuidString
        registerOperation(operationID) { result in
            completion(result.flatMap { value in
                guard value.kind == "dataBreakpointInfo",
                      let description = value.description else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("dataBreakpointInfo"))
                }
                return .success(DebugDataBreakpointInfo(
                    dataID: value.dataID,
                    description: description,
                    accessTypes: value.accessTypes ?? [],
                    canPersist: value.canPersist ?? false
                ))
            })
        }
        do {
            try apply(core.debugDataBreakpointInfo(
                sessionID: sessionID,
                operationID: operationID,
                name: name,
                variablesReference: variablesReference,
                frameID: frameID
            ))
        } catch {
            completeOperation(operationID, result: .failure(error))
        }
    }

    public func execute(_ command: DebugExecutionCommand, threadID: Int?) {
        execute(command, threadID: threadID, targetID: nil, singleThread: false)
    }

    public func execute(_ command: DebugExecutionCommand, threadID: Int?, targetID: Int?) {
        execute(command, threadID: threadID, targetID: targetID, singleThread: false)
    }

    public func execute(
        _ command: DebugExecutionCommand,
        threadID: Int?,
        targetID: Int?,
        singleThread: Bool
    ) {
        guard ownsCoreSession else { return }
        let operationID = UUID().uuidString
        do {
            try apply(core.executeDebugCommand(
                sessionID: sessionID,
                operationID: operationID,
                command: command,
                threadID: threadID,
                targetID: targetID,
                singleThread: singleThread
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
        }
    }

    public func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        inspect(kind: "threads") { result in
            completion(result.flatMap { value in
                guard value.kind == "threads", let threads = value.threads else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("threads"))
                }
                return .success(threads.map { DebugThread(id: $0.id, name: $0.name) })
            })
        }
    }

    public func requestExceptionInfo(
        threadID: Int,
        completion: @escaping (Result<DebugExceptionInfo, Error>) -> Void
    ) {
        guard capabilities.supportsExceptionInfoRequest else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("exception information")))
            return
        }
        inspect(kind: "exceptionInfo", threadID: threadID) { result in
            completion(result.flatMap { value in
                guard value.kind == "exceptionInfo", let info = value.exceptionInfo else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("exceptionInfo"))
                }
                return .success(DebugExceptionInfo(
                    exceptionID: info.exceptionID,
                    description: info.description,
                    breakMode: info.breakMode,
                    details: info.details.map(Self.makeExceptionDetails)
                ))
            })
        }
    }

    public func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    ) {
        inspect(kind: "stackTrace", threadID: threadID) { result in
            completion(result.flatMap { value in
                guard value.kind == "stackTrace", let frames = value.stackFrames else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("stackTrace"))
                }
                return .success(frames.map {
                    DebugStackFrame(
                        id: $0.id,
                        name: $0.name,
                        sourceURL: $0.sourcePath.map { URL(fileURLWithPath: $0) },
                        line: $0.line,
                        column: $0.column,
                        isFiltered: $0.isFiltered
                    )
                })
            })
        }
    }

    public func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    ) {
        inspect(kind: "scopes", frameID: frameID) { result in
            completion(result.flatMap { value in
                guard value.kind == "scopes", let scopes = value.scopes else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("scopes"))
                }
                return .success(scopes.enumerated().map { offset, scope in
                    DebugScope(
                        id: scope.variablesReference * 1_000 + offset,
                        name: scope.name,
                        variablesReference: scope.variablesReference,
                        expensive: scope.expensive,
                        namedVariables: scope.namedVariables,
                        indexedVariables: scope.indexedVariables
                    )
                })
            })
        }
    }

    public func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        requestVariables(
            reference: reference,
            filter: nil,
            start: nil,
            count: nil,
            completion: completion
        )
    }

    public func requestVariables(
        reference: Int,
        filter: DebugVariableFilter?,
        start: Int?,
        count: Int?,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        inspect(
            kind: "variables",
            variablesReference: reference,
            variableFilter: filter,
            start: start,
            count: count
        ) { result in
            completion(result.flatMap { value in
                guard value.kind == "variables", let variables = value.variables else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("variables"))
                }
                return .success(variables.enumerated().map { offset, variable in
                    Self.makeVariable(
                        variable,
                        fallbackID: [
                            String(reference),
                            filter?.rawValue ?? "all",
                            String((start ?? 0) + offset)
                        ].joined(separator: ":"),
                        containerReference: reference
                    )
                })
            })
        }
    }

    public func setVariable(
        variablesReference: Int,
        name: String,
        value: String,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        guard ownsCoreSession else {
            completion(.failure(DebugAdapterProtocolError.stopped))
            return
        }
        guard capabilities.supportsSetVariable else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("variable mutation")))
            return
        }
        let operationID = UUID().uuidString
        registerOperation(operationID) { result in
            completion(result.flatMap { result in
                guard result.kind == "setVariable", let variable = result.variable else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("setVariable"))
                }
                return .success(Self.makeVariable(
                    variable,
                    fallbackID: "\(variablesReference):\(name)",
                    containerReference: variablesReference
                ))
            })
        }
        do {
            try apply(core.setDebugVariable(
                sessionID: sessionID,
                operationID: operationID,
                variablesReference: variablesReference,
                name: name,
                value: value
            ))
        } catch {
            completeOperation(operationID, result: .failure(error))
        }
    }

    public func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        inspect(kind: "evaluate", frameID: frameID, expression: expression) { result in
            completion(result.flatMap { value in
                guard value.kind == "evaluate", let variable = value.variable else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("evaluate"))
                }
                return .success(Self.makeVariable(variable, fallbackID: expression))
            })
        }
    }

    public func requestStepInTargets(
        frameID: Int,
        completion: @escaping (Result<[DebugStepInTarget], Error>) -> Void
    ) {
        inspect(kind: "stepInTargets", frameID: frameID) { result in
            completion(result.flatMap { value in
                guard value.kind == "stepInTargets", let targets = value.targets else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("stepInTargets"))
                }
                return .success(targets.map {
                    DebugStepInTarget(
                        id: $0.id,
                        label: $0.label,
                        line: $0.line,
                        column: $0.column,
                        endLine: $0.endLine,
                        endColumn: $0.endColumn
                    )
                })
            })
        }
    }

    public func requestGotoTargets(
        fileURL: URL,
        line: Int,
        column: Int?,
        completion: @escaping (Result<[DebugGotoTarget], Error>) -> Void
    ) {
        inspect(
            kind: "gotoTargets",
            sourcePath: fileURL.standardizedFileURL.path,
            line: line,
            column: column
        ) { result in
            completion(result.flatMap { value in
                guard value.kind == "gotoTargets", let targets = value.targets else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("gotoTargets"))
                }
                return .success(targets.compactMap {
                    guard let line = $0.line else { return nil }
                    return DebugGotoTarget(
                        id: $0.id,
                        label: $0.label,
                        line: line,
                        column: $0.column,
                        endLine: $0.endLine,
                        endColumn: $0.endColumn,
                        instructionPointerReference: $0.instructionPointerReference
                    )
                })
            })
        }
    }

    private func inspect(
        kind: String,
        threadID: Int? = nil,
        frameID: Int? = nil,
        variablesReference: Int? = nil,
        variableFilter: DebugVariableFilter? = nil,
        start: Int? = nil,
        count: Int? = nil,
        expression: String? = nil,
        sourcePath: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        completion: @escaping OperationHandler
    ) {
        guard ownsCoreSession else {
            completion(.failure(DebugAdapterProtocolError.stopped))
            return
        }
        let operationID = UUID().uuidString
        registerOperation(operationID, handler: completion)
        do {
            try apply(core.inspectDebugSession(
                sessionID: sessionID,
                operationID: operationID,
                kind: kind,
                threadID: threadID,
                frameID: frameID,
                variablesReference: variablesReference,
                variableFilter: variableFilter,
                start: start,
                count: count,
                expression: expression,
                sourcePath: sourcePath,
                line: line,
                column: column
            ))
        } catch {
            completeOperation(operationID, result: .failure(error))
        }
    }

    public func cancelPendingOperations() {
        for operationID in operationHandlers.keys.sorted() {
            cancelOperation(operationID, reason: "cancelled")
        }
    }

    private func receive(_ data: Data) {
        guard ownsCoreSession else { return }
        do {
            try apply(core.receiveDebugData(sessionID: sessionID, data: data))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
            failSession()
        }
    }

    private func apply(_ update: DebugCoreUpdate) throws {
        guard update.sessionID == sessionID else {
            throw DebugAdapterProtocolError.invalidResponse("session update")
        }
        for frame in update.outboundFrames {
            guard let data = Data(base64Encoded: frame) else {
                throw DebugAdapterProtocolError.invalidResponse("outbound frame")
            }
            try transport.send(data)
        }
        for event in update.events.sorted(by: { $0.sequence < $1.sequence }) {
            consume(event)
        }
        state = Self.adapterState(update.state)
    }

    private func consume(_ event: DebugCoreEvent) {
        switch event.type {
        case "stateChanged":
            if let state = event.state { self.state = Self.adapterState(state) }
        case "initialized":
            onEvent?(.initialized)
        case "capabilities":
            guard let value = event.capabilities else { return }
            capabilities = Self.makeCapabilities(value)
            onEvent?(.capabilities(capabilities))
        case "output":
            onEvent?(.output(category: event.category, output: event.output ?? ""))
        case "stopped":
            onEvent?(.stopped(
                reason: event.reason ?? "stopped",
                threadID: event.threadID,
                description: event.description
            ))
        case "continued":
            onEvent?(.continued(threadID: event.threadID))
        case "terminated":
            onEvent?(.terminated(exitCode: event.exitCode))
        case "breakpoint":
            guard let breakpoint = event.breakpoint else { return }
            onEvent?(.breakpoint(DebugBreakpoint(
                id: breakpoint.id,
                verified: breakpoint.verified,
                message: breakpoint.message,
                sourceURL: breakpoint.sourcePath.map { URL(fileURLWithPath: $0) },
                line: breakpoint.line,
                column: breakpoint.column,
                functionName: breakpoint.functionName,
                dataID: breakpoint.dataID
            )))
        case "runInTerminalRequested":
            guard let requestID = event.requestID,
                  let request = event.request else { return }
            beginRunInTerminalRequest(requestID: requestID, request: request)
        case "operationCompleted":
            guard let operationID = event.operationID,
                  let result = event.result else { return }
            completeOperation(operationID, result: .success(result))
        case "operationFailed":
            guard let operationID = event.operationID else { return }
            let command = event.command ?? "request"
            let error: DebugAdapterProtocolError = switch event.code {
            case "cancelled": .cancelled(command)
            case "timedOut": .timedOut(command)
            default: .requestFailed(
                command: command,
                message: event.message ?? "The Debug Adapter rejected the request."
            )
            }
            if operationHandlers[operationID] != nil {
                completeOperation(operationID, result: .failure(error))
            } else {
                onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
            }
        default:
            break
        }
    }

    private func transportTerminated(exitCode: Int) {
        guard !isStopping else { return }
        discardPendingRunInTerminalRequests()
        releaseCoreSession()
        failPendingOperations(DebugAdapterProtocolError.stopped)
        state = exitCode == 0 ? .terminated : .failed
        onEvent?(.terminated(exitCode: exitCode))
    }

    private func failSession() {
        transport.stop()
        discardPendingRunInTerminalRequests()
        releaseCoreSession()
        failPendingOperations(DebugAdapterProtocolError.stopped)
        state = .failed
    }

    private func releaseCoreSession() {
        guard ownsCoreSession else { return }
        ownsCoreSession = false
        core.destroyDebugSession(sessionID: sessionID)
    }

    private func beginRunInTerminalRequest(
        requestID: String,
        request: DebugRunInTerminalRequest
    ) {
        let deadline = deadlineScheduler.schedule(
            afterMilliseconds: operationTimeoutMilliseconds
        ) { [weak self] in
            self?.completeRunInTerminalRequest(
                requestID,
                result: .failure(DebugAdapterProtocolError.timedOut("runInTerminal"))
            )
        }
        pendingRunInTerminalRequests[requestID] = PendingRunInTerminalRequest(
            deadline: deadline
        )
        guard let handler = onRunInTerminalRequest else {
            completeRunInTerminalRequest(
                requestID,
                result: .failure(DebugAdapterCapabilityError.unsupported("run in terminal"))
            )
            return
        }
        handler(request) { [weak self] result in
            self?.completeRunInTerminalRequest(requestID, result: result)
        }
    }

    private func completeRunInTerminalRequest(
        _ requestID: String,
        result: Result<DebugRunInTerminalResponse, Error>
    ) {
        guard let pending = pendingRunInTerminalRequests.removeValue(forKey: requestID),
              ownsCoreSession else { return }
        pending.deadline.cancel()
        do {
            try apply(core.completeDebugRunInTerminalRequest(
                sessionID: sessionID,
                requestID: requestID,
                result: result
            ))
        } catch {
            onEvent?(.output(category: "stderr", output: error.localizedDescription + "\n"))
            if !isStopping { failSession() }
        }
    }

    private func failPendingRunInTerminalRequests(_ error: Error) {
        for requestID in pendingRunInTerminalRequests.keys.sorted() {
            completeRunInTerminalRequest(requestID, result: .failure(error))
        }
    }

    private func discardPendingRunInTerminalRequests() {
        let pending = pendingRunInTerminalRequests.values
        pendingRunInTerminalRequests = [:]
        pending.forEach { $0.deadline.cancel() }
    }

    private static func makeCapabilities(
        _ value: DebugCoreCapabilities
    ) -> DebugAdapterCapabilities {
        DebugAdapterCapabilities(
            negotiated: true,
            supportsConfigurationDone: value.supportsConfigurationDone,
            supportsConditionalBreakpoints: value.supportsConditionalBreakpoints,
            supportsHitConditionalBreakpoints: value.supportsHitConditionalBreakpoints,
            supportsLogPoints: value.supportsLogPoints,
            supportsFunctionBreakpoints: value.supportsFunctionBreakpoints,
            supportsDataBreakpoints: value.supportsDataBreakpoints,
            supportsExceptionOptions: value.supportsExceptionOptions,
            supportsExceptionFilterOptions: value.supportsExceptionFilterOptions,
            supportsSetVariable: value.supportsSetVariable,
            supportsCancelRequest: value.supportsCancelRequest,
            supportsSingleThreadExecutionRequests: value.supportsSingleThreadExecutionRequests,
            supportsRestartRequest: value.supportsRestartRequest,
            supportsTerminateRequest: value.supportsTerminateRequest,
            supportsStepBack: value.supportsStepBack,
            supportsExceptionInfoRequest: value.supportsExceptionInfoRequest,
            supportsStepInTargetsRequest: value.supportsStepInTargetsRequest,
            supportsGotoTargetsRequest: value.supportsGotoTargetsRequest,
            exceptionBreakpointFilters: value.exceptionBreakpointFilters
        )
    }

    private func failPendingOperations(_ error: Error) {
        let handlers = operationHandlers.values
        operationHandlers = [:]
        handlers.forEach {
            $0.deadline.cancel()
            $0.handler(.failure(error))
        }
    }

    private func registerOperation(_ operationID: String, handler: @escaping OperationHandler) {
        let deadline = deadlineScheduler.schedule(
            afterMilliseconds: operationTimeoutMilliseconds
        ) { [weak self] in
            self?.cancelOperation(operationID, reason: "timedOut")
        }
        operationHandlers[operationID] = PendingOperation(handler: handler, deadline: deadline)
    }

    private func completeOperation(
        _ operationID: String,
        result: Result<DebugCoreOperationResult, Error>
    ) {
        guard let operation = operationHandlers.removeValue(forKey: operationID) else { return }
        operation.deadline.cancel()
        operation.handler(result)
    }

    private func cancelOperation(_ operationID: String, reason: String) {
        guard operationHandlers[operationID] != nil, ownsCoreSession else { return }
        do {
            try apply(core.cancelDebugOperation(
                sessionID: sessionID,
                operationID: operationID,
                reason: reason
            ))
        } catch {
            completeOperation(operationID, result: .failure(error))
        }
    }

    private static func adapterState(_ state: DebugCoreSessionState) -> DebugAdapterState {
        switch state {
        case .idle: .idle
        case .initializing: .initializing
        case .ready: .ready
        case .launching: .launching
        case .running: .running
        case .paused: .paused
        case .terminating, .terminated: .terminated
        case .failed: .failed
        }
    }

    private static func makeVariable(
        _ variable: DebugCoreVariable,
        fallbackID: String,
        containerReference: Int? = nil
    ) -> DebugVariable {
        DebugVariable(
            id: variable.evaluateName ?? fallbackID + ":" + variable.name,
            name: variable.name,
            value: variable.value,
            type: variable.type,
            evaluateName: variable.evaluateName,
            variablesReference: variable.variablesReference,
            containerReference: containerReference,
            namedVariables: variable.namedVariables,
            indexedVariables: variable.indexedVariables
        )
    }

    private static func makeExceptionDetails(
        _ details: DebugCoreExceptionDetails
    ) -> DebugExceptionDetails {
        DebugExceptionDetails(
            message: details.message,
            typeName: details.typeName,
            fullTypeName: details.fullTypeName,
            evaluateName: details.evaluateName,
            stackTrace: details.stackTrace,
            innerExceptions: details.innerExceptions.map(makeExceptionDetails)
        )
    }
}
