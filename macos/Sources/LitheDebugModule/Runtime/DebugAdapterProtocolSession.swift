import Foundation
import LitheCoreContracts

public enum DebugAdapterProtocolError: LocalizedError {
    case notReady
    case stopped
    case invalidResponse(String)
    case requestFailed(command: String, message: String)
    case cancelled(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .notReady:
            "The Debug Adapter is not ready."
        case .stopped:
            "The Debug Adapter stopped."
        case .invalidResponse(let command):
            "The Debug Adapter returned an invalid \(command) response."
        case .requestFailed(let command, let message):
            "\(command) failed: \(message)"
        case .cancelled(let command):
            "\(command) was cancelled."
        case .timedOut(let command):
            "\(command) timed out."
        }
    }
}

/// Generic Debug Adapter Protocol client. Transport details (stdio, TCP, or a
/// future platform channel) stay behind `DebugAdapterTransport`; sequencing,
/// breakpoints and inspection are shared by every language.
@MainActor
public final class DebugAdapterProtocolSession: DebugAdapterControllingSession {
    private typealias ResponseHandler = (Result<[String: Any], Error>) -> Void

    private let adapterID: String
    private let transport: any DebugAdapterTransport
    private var rootURL: URL?
    private var readBuffer = Data()
    private var nextSequence = 1
    private var responseHandlers: [Int: ResponseHandler] = [:]
    private var breakpointsBySource: [URL: [DebugSourceBreakpoint]] = [:]
    private var exceptionBreakpoints: [DebugExceptionBreakpoint] = []
    private var functionBreakpoints: [DebugFunctionBreakpoint] = []
    private var dataBreakpoints: [DebugDataBreakpoint] = []
    private var didReceiveInitializedEvent = false
    private var supportsConfigurationDone = false
    private var pendingLaunch: DebugLaunchConfiguration?
    private var activeRequestKind: DebugRequestKind?
    private var childSessions: [DebugAdapterProtocolSession] = []
    private weak var activeChildSession: DebugAdapterProtocolSession?

    public private(set) var state: DebugAdapterState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    public var onStateChange: ((DebugAdapterState) -> Void)?
    public var onEvent: ((DebugAdapterEvent) -> Void)?
    public private(set) var capabilities: DebugAdapterCapabilities = .unknown

    public init(adapterID: String, transport: any DebugAdapterTransport) {
        self.adapterID = adapterID
        self.transport = transport
        transport.onData = { [weak self] data in self?.receive(data) }
        transport.onErrorOutput = { [weak self] data in
            guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }
            self?.onEvent?(.output(category: "stderr", output: output))
        }
        transport.onTermination = { [weak self] exitCode in
            self?.terminated(exitCode: exitCode)
        }
    }

    public var isRunning: Bool { transport.isRunning }

    public func start(rootURL: URL) throws {
        if transport.isRunning { return }
        resetProtocolState()
        self.rootURL = rootURL.standardizedFileURL
        state = .initializing
        do {
            try transport.start(rootURL: rootURL.standardizedFileURL)
        } catch {
            state = .failed
            throw error
        }
        sendRequest(command: "initialize", arguments: [
            "clientID": "lithe",
            "clientName": "Lithe",
            "adapterID": adapterID,
            "locale": Locale.current.identifier,
            "linesStartAt1": true,
            "columnsStartAt1": true,
            "pathFormat": "path",
            "supportsVariableType": true,
            "supportsVariablePaging": true,
            "supportsRunInTerminalRequest": false,
            "supportsMemoryReferences": false,
            "supportsProgressReporting": false,
            "supportsInvalidatedEvent": true
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                let body = response["body"] as? [String: Any]
                self.capabilities = Self.parseCapabilities(body ?? [:])
                self.supportsConfigurationDone = self.capabilities.supportsConfigurationDone
                self.onEvent?(.capabilities(self.capabilities))
                self.state = .ready
                if let pendingLaunch = self.pendingLaunch {
                    self.pendingLaunch = nil
                    self.performLaunch(pendingLaunch)
                }
            case .failure:
                self.state = .failed
            }
        }
    }

    public func launch(_ configuration: DebugLaunchConfiguration) throws {
        guard transport.isRunning else {
            throw DebugAdapterProtocolError.notReady
        }
        if state == .initializing {
            pendingLaunch = configuration
            return
        }
        guard state == .ready else { throw DebugAdapterProtocolError.notReady }
        performLaunch(configuration)
    }

    private func performLaunch(_ configuration: DebugLaunchConfiguration) {
        var requestArguments = configuration.arguments.mapValues(\.foundationObject)
        requestArguments["name"] = configuration.name
        if requestArguments["cwd"] == nil, let rootURL {
            requestArguments["cwd"] = rootURL.path
        }
        activeRequestKind = configuration.request
        state = .launching
        sendRequest(command: configuration.request.rawValue, arguments: requestArguments) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if self.state == .launching { self.state = .running }
            case .failure:
                self.state = .failed
            }
        }
    }

    private static func parseCapabilities(_ body: [String: Any]) -> DebugAdapterCapabilities {
        let filters = (body["exceptionBreakpointFilters"] as? [[String: Any]] ?? [])
            .compactMap { value -> DebugExceptionBreakpointFilter? in
                guard let filter = value["filter"] as? String, !filter.isEmpty,
                      let label = value["label"] as? String, !label.isEmpty else { return nil }
                return DebugExceptionBreakpointFilter(
                    filter: filter,
                    label: label,
                    description: value["description"] as? String,
                    isDefault: value["default"] as? Bool ?? false,
                    supportsCondition: value["supportsCondition"] as? Bool ?? false,
                    conditionDescription: value["conditionDescription"] as? String
                )
            }
        return DebugAdapterCapabilities(
            negotiated: true,
            supportsConfigurationDone: body["supportsConfigurationDoneRequest"] as? Bool ?? false,
            supportsConditionalBreakpoints: body["supportsConditionalBreakpoints"] as? Bool ?? false,
            supportsHitConditionalBreakpoints: body["supportsHitConditionalBreakpoints"] as? Bool ?? false,
            supportsLogPoints: body["supportsLogPoints"] as? Bool ?? false,
            supportsFunctionBreakpoints: body["supportsFunctionBreakpoints"] as? Bool ?? false,
            supportsDataBreakpoints: body["supportsDataBreakpoints"] as? Bool ?? false,
            supportsExceptionOptions: body["supportsExceptionOptions"] as? Bool ?? false,
            supportsExceptionFilterOptions: body["supportsExceptionFilterOptions"] as? Bool ?? false,
            supportsSetVariable: body["supportsSetVariable"] as? Bool ?? false,
            supportsCancelRequest: body["supportsCancelRequest"] as? Bool ?? false,
            supportsSingleThreadExecutionRequests:
                body["supportsSingleThreadExecutionRequests"] as? Bool ?? false,
            supportsRestartRequest: body["supportsRestartRequest"] as? Bool ?? false,
            supportsTerminateRequest: body["supportsTerminateRequest"] as? Bool ?? false,
            supportsStepBack: body["supportsStepBack"] as? Bool ?? false,
            supportsStepInTargetsRequest: body["supportsStepInTargetsRequest"] as? Bool ?? false,
            supportsGotoTargetsRequest: body["supportsGotoTargetsRequest"] as? Bool ?? false,
            exceptionBreakpointFilters: filters
        )
    }

    public func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        breakpointsBySource[normalizedURL] = breakpoints.sorted { $0.line < $1.line }
        childSessions.forEach { $0.setBreakpoints(breakpoints, in: normalizedURL) }
        guard didReceiveInitializedEvent else { return }
        sendBreakpoints(for: normalizedURL)
    }

    public func setExceptionBreakpoints(_ breakpoints: [DebugExceptionBreakpoint]) {
        exceptionBreakpoints = breakpoints.sorted { $0.filter < $1.filter }
        childSessions.forEach { $0.setExceptionBreakpoints(breakpoints) }
        guard didReceiveInitializedEvent else { return }
        sendExceptionBreakpoints()
    }

    public func setFunctionBreakpoints(_ breakpoints: [DebugFunctionBreakpoint]) {
        functionBreakpoints = breakpoints.sorted { $0.name < $1.name }
        childSessions.forEach { $0.setFunctionBreakpoints(breakpoints) }
        guard didReceiveInitializedEvent, capabilities.supportsFunctionBreakpoints else { return }
        sendFunctionBreakpoints()
    }

    public func setDataBreakpoints(_ breakpoints: [DebugDataBreakpoint]) {
        dataBreakpoints = breakpoints.sorted {
            ($0.dataID, $0.accessType ?? "") < ($1.dataID, $1.accessType ?? "")
        }
        childSessions.forEach { $0.setDataBreakpoints(breakpoints) }
        guard didReceiveInitializedEvent, capabilities.supportsDataBreakpoints else { return }
        sendDataBreakpoints()
    }

    public func requestDataBreakpointInfo(
        name: String,
        variablesReference: Int?,
        frameID: Int?,
        completion: @escaping (Result<DebugDataBreakpointInfo, Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestDataBreakpointInfo(
                name: name,
                variablesReference: variablesReference,
                frameID: frameID,
                completion: completion
            )
            return
        }
        guard capabilities.supportsDataBreakpoints else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("data breakpoints")))
            return
        }
        var arguments: [String: Any] = ["name": name]
        if let variablesReference { arguments["variablesReference"] = variablesReference }
        if let frameID { arguments["frameId"] = frameID }
        sendRequest(command: "dataBreakpointInfo", arguments: arguments) { result in
            completion(result.flatMap { response in
                guard let body = response["body"] as? [String: Any],
                      let description = body["description"] as? String else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("dataBreakpointInfo"))
                }
                return .success(DebugDataBreakpointInfo(
                    dataID: body["dataId"] as? String,
                    description: description,
                    accessTypes: body["accessTypes"] as? [String] ?? [],
                    canPersist: body["canPersist"] as? Bool ?? false
                ))
            })
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
        if let activeChildSession {
            activeChildSession.execute(
                command,
                threadID: threadID,
                targetID: targetID,
                singleThread: singleThread
            )
            return
        }
        guard transport.isRunning else { return }
        if command == .stepBack, !capabilities.supportsStepBack { return }
        if command == .goto, !capabilities.supportsGotoTargetsRequest { return }
        if command == .restart, !capabilities.supportsRestartRequest { return }
        if command == .terminate, !capabilities.supportsTerminateRequest { return }
        if singleThread, !capabilities.supportsSingleThreadExecutionRequests { return }
        if [.next, .stepIn, .stepOut, .stepBack, .goto].contains(command), state != .paused { return }
        if command == .pause, state != .running { return }
        if command == .continueExecution, state != .paused { return }
        var arguments: [String: Any] = [:]
        if command != .restart, command != .terminate, let threadID {
            arguments["threadId"] = threadID
        }
        if let targetID, command == .stepIn || command == .goto {
            arguments["targetId"] = targetID
        }
        if command == .continueExecution || command == .next || command == .stepIn
            || command == .stepOut || command == .stepBack || command == .goto
            || command == .pause {
            arguments["singleThread"] = singleThread
        }
        sendRequest(command: command.rawValue, arguments: arguments) { [weak self] result in
            if case .success = result {
                if command != .pause, command != .terminate,
                   !(singleThread && command == .continueExecution) {
                    self?.state = .running
                }
            }
        }
    }

    public func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
        if let activeChildSession {
            activeChildSession.requestThreads(completion)
            return
        }
        sendRequest(command: "threads", arguments: [:]) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["threads"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("threads"))
                }
                return .success(values.compactMap(Self.parseThread))
            })
        }
    }

    public func requestStackTrace(
        threadID: Int,
        completion: @escaping (Result<[DebugStackFrame], Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestStackTrace(threadID: threadID, completion: completion)
            return
        }
        sendRequest(command: "stackTrace", arguments: ["threadId": threadID]) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["stackFrames"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("stackTrace"))
                }
                return .success(values.compactMap(Self.parseStackFrame))
            })
        }
    }

    public func requestScopes(
        frameID: Int,
        completion: @escaping (Result<[DebugScope], Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestScopes(frameID: frameID, completion: completion)
            return
        }
        sendRequest(command: "scopes", arguments: ["frameId": frameID]) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["scopes"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("scopes"))
                }
                return .success(values.enumerated().compactMap(Self.parseScope))
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
        if let activeChildSession {
            activeChildSession.requestVariables(
                reference: reference,
                filter: filter,
                start: start,
                count: count,
                completion: completion
            )
            return
        }
        var arguments: [String: Any] = ["variablesReference": reference]
        if let filter { arguments["filter"] = filter.rawValue }
        if let start { arguments["start"] = start }
        if let count { arguments["count"] = count }
        sendRequest(command: "variables", arguments: arguments) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["variables"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("variables"))
                }
                return .success(values.enumerated().compactMap { index, value in
                    Self.parseVariable(
                        value,
                        fallbackID: [
                            String(reference),
                            filter?.rawValue ?? "all",
                            String((start ?? 0) + index)
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
        if let activeChildSession {
            activeChildSession.setVariable(
                variablesReference: variablesReference,
                name: name,
                value: value,
                completion: completion
            )
            return
        }
        guard capabilities.supportsSetVariable else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("variable mutation")))
            return
        }
        sendRequest(command: "setVariable", arguments: [
            "variablesReference": variablesReference,
            "name": name,
            "value": value
        ]) { result in
            completion(result.flatMap { response in
                guard let body = response["body"] as? [String: Any],
                      let resolvedValue = body["value"] as? String else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("setVariable"))
                }
                return .success(DebugVariable(
                    id: "\(variablesReference):\(name)",
                    name: name,
                    value: resolvedValue,
                    type: body["type"] as? String,
                    evaluateName: nil,
                    variablesReference: body["variablesReference"] as? Int ?? 0,
                    containerReference: variablesReference,
                    namedVariables: body["namedVariables"] as? Int ?? 0,
                    indexedVariables: body["indexedVariables"] as? Int ?? 0
                ))
            })
        }
    }

    public func evaluate(
        _ expression: String,
        frameID: Int?,
        completion: @escaping (Result<DebugVariable, Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.evaluate(expression, frameID: frameID, completion: completion)
            return
        }
        var arguments: [String: Any] = ["expression": expression, "context": "watch"]
        if let frameID { arguments["frameId"] = frameID }
        sendRequest(command: "evaluate", arguments: arguments) { result in
            completion(result.flatMap { response in
                guard let body = response["body"] as? [String: Any],
                      let value = body["result"] as? String else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("evaluate"))
                }
                return .success(DebugVariable(
                    id: "evaluate:\(expression)",
                    name: expression,
                    value: value,
                    type: body["type"] as? String,
                    evaluateName: expression,
                    variablesReference: body["variablesReference"] as? Int ?? 0,
                    namedVariables: body["namedVariables"] as? Int ?? 0,
                    indexedVariables: body["indexedVariables"] as? Int ?? 0
                ))
            })
        }
    }

    public func requestStepInTargets(
        frameID: Int,
        completion: @escaping (Result<[DebugStepInTarget], Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestStepInTargets(frameID: frameID, completion: completion)
            return
        }
        guard capabilities.supportsStepInTargetsRequest else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("smart step into")))
            return
        }
        sendRequest(command: "stepInTargets", arguments: ["frameId": frameID]) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["targets"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("stepInTargets"))
                }
                return .success(values.compactMap(Self.parseStepInTarget))
            })
        }
    }

    public func requestGotoTargets(
        fileURL: URL,
        line: Int,
        column: Int?,
        completion: @escaping (Result<[DebugGotoTarget], Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestGotoTargets(
                fileURL: fileURL,
                line: line,
                column: column,
                completion: completion
            )
            return
        }
        guard capabilities.supportsGotoTargetsRequest else {
            completion(.failure(DebugAdapterCapabilityError.unsupported("run to cursor")))
            return
        }
        var arguments: [String: Any] = ["source": ["path": fileURL.path], "line": line]
        if let column { arguments["column"] = column }
        sendRequest(command: "gotoTargets", arguments: arguments) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["targets"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("gotoTargets"))
                }
                return .success(values.compactMap(Self.parseGotoTarget))
            })
        }
    }

    public func stop() {
        let children = childSessions
        childSessions = []
        activeChildSession = nil
        children.forEach { $0.stop() }
        if transport.isRunning {
            sendRequest(command: "disconnect", arguments: [
                "restart": false,
                "terminateDebuggee": activeRequestKind == .launch
            ]) { _ in }
        }
        transport.stop()
        failPendingRequests(DebugAdapterProtocolError.stopped)
        state = .idle
        resetProtocolState(keepingState: true)
    }

    private func sendBreakpoints(for fileURL: URL) {
        let breakpoints = (breakpointsBySource[fileURL] ?? []).filter(\.enabled)
        let values: [[String: Any]] = breakpoints.map { breakpoint in
            var value: [String: Any] = ["line": breakpoint.line]
            if let column = breakpoint.column { value["column"] = column }
            if let condition = breakpoint.condition, !condition.isEmpty { value["condition"] = condition }
            if let hitCondition = breakpoint.hitCondition, !hitCondition.isEmpty {
                value["hitCondition"] = hitCondition
            }
            if let logMessage = breakpoint.logMessage, !logMessage.isEmpty {
                value["logMessage"] = logMessage
            }
            return value
        }
        sendRequest(command: "setBreakpoints", arguments: [
            "source": ["name": fileURL.lastPathComponent, "path": fileURL.path],
            "breakpoints": values,
            "sourceModified": false
        ]) { [weak self] result in
            guard let self, case .success(let response) = result,
                  let returned = (response["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]]
            else { return }
            for (index, value) in returned.enumerated() {
                let fallback = breakpoints.indices.contains(index) ? breakpoints[index].line : nil
                if let parsed = Self.parseBreakpoint(
                    value,
                    fallbackLine: fallback,
                    sourceURL: fileURL,
                    functionName: nil,
                    index: index
                ) {
                    self.onEvent?(.breakpoint(parsed))
                }
            }
        }
    }

    private func sendExceptionBreakpoints() {
        let active = exceptionBreakpoints.filter(\.enabled)
        var arguments: [String: Any] = ["filters": active.map(\.filter)]
        if capabilities.supportsExceptionFilterOptions {
            let options = active.compactMap { breakpoint -> [String: Any]? in
                guard let condition = breakpoint.condition, !condition.isEmpty else { return nil }
                return ["filterId": breakpoint.filter, "condition": condition]
            }
            if !options.isEmpty { arguments["filterOptions"] = options }
        }
        sendRequest(command: "setExceptionBreakpoints", arguments: arguments) { _ in }
    }

    private func sendFunctionBreakpoints() {
        let active = functionBreakpoints.filter(\.enabled)
        let values: [[String: Any]] = active.map { breakpoint in
            var value: [String: Any] = ["name": breakpoint.name]
            if let condition = breakpoint.condition, !condition.isEmpty {
                value["condition"] = condition
            }
            if let hitCondition = breakpoint.hitCondition, !hitCondition.isEmpty {
                value["hitCondition"] = hitCondition
            }
            return value
        }
        sendRequest(command: "setFunctionBreakpoints", arguments: ["breakpoints": values]) { [weak self] result in
            guard let self, case .success(let response) = result,
                  let returned = (response["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]]
            else { return }
            for (index, value) in returned.enumerated() {
                let functionName = active.indices.contains(index) ? active[index].name : nil
                if let parsed = Self.parseBreakpoint(
                    value,
                    fallbackLine: nil,
                    sourceURL: nil,
                    functionName: functionName,
                    index: index
                ) {
                    self.onEvent?(.breakpoint(parsed))
                }
            }
        }
    }

    private func sendDataBreakpoints() {
        let active = dataBreakpoints.filter(\.enabled)
        let values: [[String: Any]] = active.map { breakpoint in
            var value: [String: Any] = ["dataId": breakpoint.dataID]
            if let accessType = breakpoint.accessType, !accessType.isEmpty {
                value["accessType"] = accessType
            }
            if let condition = breakpoint.condition, !condition.isEmpty {
                value["condition"] = condition
            }
            if let hitCondition = breakpoint.hitCondition, !hitCondition.isEmpty {
                value["hitCondition"] = hitCondition
            }
            return value
        }
        sendRequest(command: "setDataBreakpoints", arguments: ["breakpoints": values]) { [weak self] result in
            guard let self, case .success(let response) = result,
                  let returned = (response["body"] as? [String: Any])?["breakpoints"] as? [[String: Any]]
            else { return }
            for (index, value) in returned.enumerated() {
                let dataID = active.indices.contains(index) ? active[index].dataID : nil
                if let parsed = Self.parseBreakpoint(
                    value,
                    fallbackLine: nil,
                    sourceURL: nil,
                    functionName: nil,
                    dataID: dataID,
                    index: index
                ) {
                    self.onEvent?(.breakpoint(parsed))
                }
            }
        }
    }

    private func sendRequest(
        command: String,
        arguments: [String: Any],
        completion: @escaping ResponseHandler
    ) {
        guard transport.isRunning else {
            completion(.failure(DebugAdapterProtocolError.stopped))
            return
        }
        let sequence = nextSequence
        nextSequence += 1
        responseHandlers[sequence] = completion
        send([
            "seq": sequence,
            "type": "request",
            "command": command,
            "arguments": arguments
        ])
    }

    private func sendResponse(
        requestSequence: Int,
        command: String,
        success: Bool,
        message: String? = nil
    ) {
        var response: [String: Any] = [
            "seq": nextSequence,
            "type": "response",
            "request_seq": requestSequence,
            "success": success,
            "command": command
        ]
        nextSequence += 1
        if let message { response["message"] = message }
        send(response)
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? transport.send(framed)
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let headerEnd = readBuffer.range(of: Data("\r\n\r\n".utf8)) {
            let headerData = readBuffer[..<headerEnd.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8),
                  let contentLength = header
                    .split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })?
                    .split(separator: ":", maxSplits: 1)
                    .last
                    .flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
                readBuffer.removeSubrange(...headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard readBuffer.count >= bodyStart + contentLength else { return }
            let body = readBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            readBuffer.removeSubrange(0..<(bodyStart + contentLength))
            guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "response": handleResponse(message)
        case "event": handleEvent(message)
        case "request":
            guard let sequence = message["seq"] as? Int,
                  let command = message["command"] as? String else { return }
            if command == "startDebugging" {
                startChildDebugging(message, requestSequence: sequence)
            } else {
                sendResponse(
                    requestSequence: sequence,
                    command: command,
                    success: false,
                    message: "Lithe does not support the \(command) reverse request yet."
                )
            }
        default: break
        }
    }

    private func handleResponse(_ message: [String: Any]) {
        guard let requestSequence = message["request_seq"] as? Int,
              let handler = responseHandlers.removeValue(forKey: requestSequence) else { return }
        let success = message["success"] as? Bool ?? false
        if success {
            handler(.success(message))
        } else {
            let command = message["command"] as? String ?? "request"
            let detail = message["message"] as? String ?? "Unknown Debug Adapter error"
            handler(.failure(DebugAdapterProtocolError.requestFailed(command: command, message: detail)))
        }
    }

    private func handleEvent(_ message: [String: Any]) {
        guard let event = message["event"] as? String else { return }
        let body = message["body"] as? [String: Any] ?? [:]
        switch event {
        case "initialized":
            didReceiveInitializedEvent = true
            onEvent?(.initialized)
            sendExceptionBreakpoints()
            if capabilities.supportsFunctionBreakpoints {
                sendFunctionBreakpoints()
            }
            if capabilities.supportsDataBreakpoints {
                sendDataBreakpoints()
            }
            for source in breakpointsBySource.keys.sorted(by: { $0.path < $1.path }) {
                sendBreakpoints(for: source)
            }
            if supportsConfigurationDone {
                sendRequest(command: "configurationDone", arguments: [:]) { _ in }
            }
        case "output":
            let output = body["output"] as? String ?? ""
            onEvent?(.output(category: body["category"] as? String, output: output))
        case "stopped":
            state = .paused
            onEvent?(.stopped(
                reason: body["reason"] as? String ?? "stopped",
                threadID: body["threadId"] as? Int,
                description: body["description"] as? String ?? body["text"] as? String
            ))
        case "continued":
            state = .running
            onEvent?(.continued(threadID: body["threadId"] as? Int))
        case "terminated", "exited":
            state = .terminated
            onEvent?(.terminated(exitCode: body["exitCode"] as? Int))
        case "breakpoint":
            if let value = body["breakpoint"] as? [String: Any],
               let breakpoint = Self.parseBreakpoint(
                   value,
                   fallbackLine: nil,
                   sourceURL: nil,
                   functionName: nil,
                   dataID: nil,
                   index: 0
               ) {
                onEvent?(.breakpoint(breakpoint))
            }
        default: break
        }
    }

    private func terminated(exitCode: Int) {
        failPendingRequests(DebugAdapterProtocolError.stopped)
        if state != .idle {
            state = exitCode == 0 ? .terminated : .failed
            onEvent?(.terminated(exitCode: exitCode))
        }
    }

    private func startChildDebugging(_ message: [String: Any], requestSequence: Int) {
        guard let rootURL,
              let provider = transport as? any DebugAdapterChildTransportProviding,
              let childTransport = provider.makeChildTransport(),
              let arguments = message["arguments"] as? [String: Any],
              let rawConfiguration = arguments["configuration"] as? [String: Any],
              let requestValue = rawConfiguration["request"] as? String,
              let request = DebugRequestKind(rawValue: requestValue) else {
            sendResponse(
                requestSequence: requestSequence,
                command: "startDebugging",
                success: false,
                message: "The adapter did not provide a valid child debug configuration."
            )
            return
        }

        var childArguments: [String: ToolingJSONValue] = [:]
        for (key, value) in rawConfiguration where key != "name" && key != "request" {
            if let parsed = Self.toolingJSONValue(value) { childArguments[key] = parsed }
        }
        let configuration = DebugLaunchConfiguration(
            name: rawConfiguration["name"] as? String ?? "Child Debug Session",
            request: request,
            arguments: childArguments
        )
        let child = DebugAdapterProtocolSession(adapterID: adapterID, transport: childTransport)
        child.setExceptionBreakpoints(exceptionBreakpoints)
        child.setFunctionBreakpoints(functionBreakpoints)
        child.setDataBreakpoints(dataBreakpoints)
        for (source, breakpoints) in breakpointsBySource {
            child.setBreakpoints(breakpoints, in: source)
        }
        child.onStateChange = { [weak self, weak child] childState in
            guard let self else { return }
            switch childState {
            case .paused:
                self.activeChildSession = child
                self.state = .paused
            case .running:
                self.activeChildSession = child
                self.state = .running
            case .failed:
                self.state = .failed
            case .terminated:
                if self.activeChildSession === child { self.activeChildSession = nil }
                self.state = .terminated
            default:
                break
            }
        }
        child.onEvent = { [weak self, weak child] event in
            if case .stopped = event { self?.activeChildSession = child }
            self?.onEvent?(event)
        }
        do {
            try child.start(rootURL: rootURL)
            try child.launch(configuration)
            childSessions.append(child)
            sendResponse(
                requestSequence: requestSequence,
                command: "startDebugging",
                success: true
            )
        } catch {
            child.stop()
            sendResponse(
                requestSequence: requestSequence,
                command: "startDebugging",
                success: false,
                message: error.localizedDescription
            )
        }
    }

    private static func toolingJSONValue(_ value: Any) -> ToolingJSONValue? {
        switch value {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as Int: .integer(value)
        case let value as Double: .number(value)
        case let value as [String: Any]:
            .object(value.reduce(into: [:]) { result, element in
                if let parsed = toolingJSONValue(element.value) { result[element.key] = parsed }
            })
        case let value as [Any]: .array(value.compactMap(toolingJSONValue))
        case _ as NSNull: .null
        default: nil
        }
    }

    private func failPendingRequests(_ error: Error) {
        let handlers = responseHandlers.values
        responseHandlers = [:]
        handlers.forEach { $0(.failure(error)) }
    }

    private func resetProtocolState(keepingState: Bool = false) {
        readBuffer = Data()
        nextSequence = 1
        responseHandlers = [:]
        didReceiveInitializedEvent = false
        supportsConfigurationDone = false
        capabilities = .unknown
        pendingLaunch = nil
        activeRequestKind = nil
        activeChildSession = nil
        childSessions = []
        if !keepingState { state = .idle }
    }

    private static func parseThread(_ value: [String: Any]) -> DebugThread? {
        guard let id = value["id"] as? Int, let name = value["name"] as? String else { return nil }
        return DebugThread(id: id, name: name)
    }

    private static func parseStackFrame(_ value: [String: Any]) -> DebugStackFrame? {
        guard let id = value["id"] as? Int,
              let name = value["name"] as? String,
              let line = value["line"] as? Int,
              let column = value["column"] as? Int else { return nil }
        return DebugStackFrame(
            id: id,
            name: name,
            sourceURL: sourceURL(value["source"] as? [String: Any]),
            line: line,
            column: column
        )
    }

    private static func parseScope(_ offset: Int, _ value: [String: Any]) -> DebugScope? {
        guard let name = value["name"] as? String,
              let reference = value["variablesReference"] as? Int else { return nil }
        return DebugScope(
            id: value["presentationHint"] as? Int ?? reference * 1_000 + offset,
            name: name,
            variablesReference: reference,
            expensive: value["expensive"] as? Bool ?? false,
            namedVariables: value["namedVariables"] as? Int ?? 0,
            indexedVariables: value["indexedVariables"] as? Int ?? 0
        )
    }

    private static func parseVariable(
        _ value: [String: Any],
        fallbackID: String,
        containerReference: Int? = nil
    ) -> DebugVariable? {
        guard let name = value["name"] as? String,
              let rendered = value["value"] as? String else { return nil }
        return DebugVariable(
            id: (value["evaluateName"] as? String) ?? fallbackID + ":" + name,
            name: name,
            value: rendered,
            type: value["type"] as? String,
            evaluateName: value["evaluateName"] as? String,
            variablesReference: value["variablesReference"] as? Int ?? 0,
            containerReference: containerReference,
            namedVariables: value["namedVariables"] as? Int ?? 0,
            indexedVariables: value["indexedVariables"] as? Int ?? 0
        )
    }

    private static func parseStepInTarget(_ value: [String: Any]) -> DebugStepInTarget? {
        guard let id = value["id"] as? Int, let label = value["label"] as? String else { return nil }
        return DebugStepInTarget(
            id: id,
            label: label,
            line: value["line"] as? Int,
            column: value["column"] as? Int,
            endLine: value["endLine"] as? Int,
            endColumn: value["endColumn"] as? Int
        )
    }

    private static func parseGotoTarget(_ value: [String: Any]) -> DebugGotoTarget? {
        guard let id = value["id"] as? Int,
              let label = value["label"] as? String,
              let line = value["line"] as? Int else { return nil }
        return DebugGotoTarget(
            id: id,
            label: label,
            line: line,
            column: value["column"] as? Int,
            endLine: value["endLine"] as? Int,
            endColumn: value["endColumn"] as? Int,
            instructionPointerReference: value["instructionPointerReference"] as? String
        )
    }

    private static func parseBreakpoint(
        _ value: [String: Any],
        fallbackLine: Int?,
        sourceURL: URL?,
        functionName: String?,
        dataID: String? = nil,
        index: Int
    ) -> DebugBreakpoint? {
        let line = value["line"] as? Int ?? fallbackLine
        let source = Self.sourceURL(value["source"] as? [String: Any]) ?? sourceURL
        return DebugBreakpoint(
            id: value["id"] as? Int ?? -(index + 1),
            verified: value["verified"] as? Bool ?? false,
            message: value["message"] as? String,
            sourceURL: source,
            line: line,
            column: value["column"] as? Int,
            functionName: functionName,
            dataID: dataID
        )
    }

    private static func sourceURL(_ source: [String: Any]?) -> URL? {
        guard let path = source?["path"] as? String, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
