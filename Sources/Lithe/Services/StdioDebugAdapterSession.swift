import Foundation

enum DebugAdapterProtocolError: LocalizedError {
    case notReady
    case stopped
    case invalidResponse(String)
    case requestFailed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            "The Debug Adapter is not ready."
        case .stopped:
            "The Debug Adapter stopped."
        case .invalidResponse(let command):
            "The Debug Adapter returned an invalid \(command) response."
        case .requestFailed(let command, let message):
            "\(command) failed: \(message)"
        }
    }
}

@MainActor
final class ProcessDebugAdapterTransport: DebugAdapterTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let process: any RawProcessSession
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        process: any RawProcessSession
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.process = process
        process.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in self?.onData?(data) }
        }
        process.onError = { [weak self] data in
            Task { @MainActor [weak self] in self?.onErrorOutput?(data) }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in self?.onTermination?(Int(exitCode)) }
        }
    }

    var isRunning: Bool { process.isRunning }

    func start(rootURL: URL) throws {
        try process.start(ProcessRequest(
            operationID: UUID().uuidString,
            executablePath: executableURL.path,
            arguments: arguments,
            workingDirectory: rootURL.standardizedFileURL.path,
            environment: environment,
            keepsStandardInputOpen: true
        ))
    }

    func send(_ data: Data) throws { try process.send(data) }
    func stop() { process.stop() }
}

/// Generic Debug Adapter Protocol client. Transport details (stdio, TCP, or a
/// future platform channel) stay behind `DebugAdapterTransport`; sequencing,
/// breakpoints and inspection are shared by every language.
@MainActor
final class DebugAdapterProtocolSession: DebugAdapterControllingSession {
    private typealias ResponseHandler = (Result<[String: Any], Error>) -> Void

    private let adapterID: String
    private let transport: any DebugAdapterTransport
    private var rootURL: URL?
    private var readBuffer = Data()
    private var nextSequence = 1
    private var responseHandlers: [Int: ResponseHandler] = [:]
    private var breakpointsBySource: [URL: [DebugSourceBreakpoint]] = [:]
    private var didReceiveInitializedEvent = false
    private var supportsConfigurationDone = false
    private var pendingLaunch: DebugLaunchConfiguration?
    private var childSessions: [DebugAdapterProtocolSession] = []
    private weak var activeChildSession: DebugAdapterProtocolSession?

    private(set) var state: DebugAdapterState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }
    var onStateChange: ((DebugAdapterState) -> Void)?
    var onEvent: ((DebugAdapterEvent) -> Void)?

    convenience init(
        adapterID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        process: any RawProcessSession
    ) {
        self.init(
            adapterID: adapterID,
            transport: ProcessDebugAdapterTransport(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                process: process
            )
        )
    }

    init(adapterID: String, transport: any DebugAdapterTransport) {
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

    var isRunning: Bool { transport.isRunning }

    func start(rootURL: URL) throws {
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
                self.supportsConfigurationDone = body?["supportsConfigurationDoneRequest"] as? Bool ?? false
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

    func launch(_ configuration: DebugLaunchConfiguration) throws {
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

    func setBreakpoints(_ breakpoints: [DebugSourceBreakpoint], in fileURL: URL) {
        let normalizedURL = fileURL.standardizedFileURL
        breakpointsBySource[normalizedURL] = breakpoints.sorted { $0.line < $1.line }
        childSessions.forEach { $0.setBreakpoints(breakpoints, in: normalizedURL) }
        guard didReceiveInitializedEvent else { return }
        sendBreakpoints(for: normalizedURL)
    }

    func execute(_ command: DebugExecutionCommand, threadID: Int?) {
        if let activeChildSession {
            activeChildSession.execute(command, threadID: threadID)
            return
        }
        guard transport.isRunning else { return }
        var arguments: [String: Any] = [:]
        if let threadID { arguments["threadId"] = threadID }
        if command == .continueExecution || command == .next || command == .stepIn || command == .stepOut {
            arguments["singleThread"] = false
        }
        sendRequest(command: command.rawValue, arguments: arguments) { [weak self] result in
            if case .success = result, command != .pause {
                self?.state = .running
            }
        }
    }

    func requestThreads(_ completion: @escaping (Result<[DebugThread], Error>) -> Void) {
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

    func requestStackTrace(
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

    func requestScopes(
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

    func requestVariables(
        reference: Int,
        completion: @escaping (Result<[DebugVariable], Error>) -> Void
    ) {
        if let activeChildSession {
            activeChildSession.requestVariables(reference: reference, completion: completion)
            return
        }
        sendRequest(command: "variables", arguments: ["variablesReference": reference]) { result in
            completion(result.flatMap { response in
                guard let values = (response["body"] as? [String: Any])?["variables"] as? [[String: Any]] else {
                    return .failure(DebugAdapterProtocolError.invalidResponse("variables"))
                }
                return .success(values.enumerated().compactMap { index, value in
                    Self.parseVariable(value, fallbackID: "\(reference):\(index)")
                })
            })
        }
    }

    func evaluate(
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
                    variablesReference: body["variablesReference"] as? Int ?? 0
                ))
            })
        }
    }

    func stop() {
        let children = childSessions
        childSessions = []
        activeChildSession = nil
        children.forEach { $0.stop() }
        if transport.isRunning {
            sendRequest(command: "disconnect", arguments: [
                "restart": false,
                "terminateDebuggee": true
            ]) { _ in }
        }
        transport.stop()
        failPendingRequests(DebugAdapterProtocolError.stopped)
        state = .idle
        resetProtocolState(keepingState: true)
    }

    private func sendBreakpoints(for fileURL: URL) {
        let breakpoints = breakpointsBySource[fileURL] ?? []
        let values: [[String: Any]] = breakpoints.map { breakpoint in
            var value: [String: Any] = ["line": breakpoint.line]
            if let column = breakpoint.column { value["column"] = column }
            if let condition = breakpoint.condition, !condition.isEmpty { value["condition"] = condition }
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
                if let parsed = Self.parseBreakpoint(value, fallbackLine: fallback, sourceURL: fileURL, index: index) {
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
               let breakpoint = Self.parseBreakpoint(value, fallbackLine: nil, sourceURL: nil, index: 0) {
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
        pendingLaunch = nil
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
            expensive: value["expensive"] as? Bool ?? false
        )
    }

    private static func parseVariable(_ value: [String: Any], fallbackID: String) -> DebugVariable? {
        guard let name = value["name"] as? String,
              let rendered = value["value"] as? String else { return nil }
        return DebugVariable(
            id: (value["evaluateName"] as? String) ?? fallbackID + ":" + name,
            name: name,
            value: rendered,
            type: value["type"] as? String,
            evaluateName: value["evaluateName"] as? String,
            variablesReference: value["variablesReference"] as? Int ?? 0
        )
    }

    private static func parseBreakpoint(
        _ value: [String: Any],
        fallbackLine: Int?,
        sourceURL: URL?,
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
            column: value["column"] as? Int
        )
    }

    private static func sourceURL(_ source: [String: Any]?) -> URL? {
        guard let path = source?["path"] as? String, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

/// Source compatibility for callers created before TCP adapters were added.
typealias StdioDebugAdapterSession = DebugAdapterProtocolSession
