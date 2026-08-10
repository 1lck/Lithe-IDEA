import Foundation

@MainActor
final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private let runtimeService: ProjectRuntimeService
    private let processFactory: () -> any RawProcessSession
    private let launch: StdioLanguageServerLaunch
    private let debugLaunch: StdioDebugAdapterLaunch?
    private let debugSessionFactory: (() -> (any DebugAdapterSession)?)?

    var supportsEditingSession: Bool { true }
    var supportsDebugAdapterSession: Bool { debugLaunch != nil || debugSessionFactory != nil }
    var unavailableToolingMessage: String? {
        let command = debugLaunch?.executableNames.first ?? launch.executableNames.first
        guard let command else { return nil }
        return runtimeService.missingToolMessage(command)
    }
    var declaredLanguageServerFeatures: LanguageServerFeatureSet { .standardEditing }

    init(
        descriptor: LanguageProviderDescriptor,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        launch: StdioLanguageServerLaunch,
        debugLaunch: StdioDebugAdapterLaunch? = nil,
        debugSessionFactory: (() -> (any DebugAdapterSession)?)? = nil
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.launch = launch
        self.debugLaunch = debugLaunch
        self.debugSessionFactory = debugSessionFactory
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? {
        guard let executableURL = launch.executableNames.lazy.compactMap({
            self.runtimeService.executableOnPath($0)
        }).first else { return nil }
        return StdioLanguageServerSession(
            executableURL: executableURL,
            arguments: launch.arguments,
            environment: runtimeService.processEnvironment(),
            process: processFactory()
        )
    }

    func makeDebugAdapterSession() -> (any DebugAdapterSession)? {
        if let debugSessionFactory { return debugSessionFactory() }
        guard let debugLaunch else { return nil }
        let direct = debugLaunch.executableNames.lazy.compactMap({ name in
            self.runtimeService.executableOnPath(name).map { ($0, debugLaunch.arguments) }
        }).first
        let fallback = debugLaunch.fallbacks.lazy.compactMap { fallback in
            self.runtimeService.executableOnPath(fallback.executableName).map {
                ($0, fallback.argumentPrefix + debugLaunch.arguments)
            }
        }.first
        guard let (executableURL, arguments) = direct ?? fallback else { return nil }
        return DebugAdapterProtocolSession(
            adapterID: debugLaunch.adapterID,
            executableURL: executableURL,
            arguments: arguments,
            environment: runtimeService.processEnvironment(),
            process: processFactory()
        )
    }

    /// Builds standard stdio runtimes from language-pack metadata.  No
    /// language identifiers or executable maps live in this runtime anymore;
    /// adding a provider means adding its launch definition to its pack.
    static func standard(
        packs: [LanguagePack],
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) -> [any LanguageProviderRuntime] {
        packs.compactMap { pack in
            guard let launch = pack.languageServerLaunch else { return nil }
            return StdioLanguageProviderRuntime(
                descriptor: pack.descriptor,
                runtimeService: runtimeService,
                processFactory: processFactory,
                launch: launch,
                debugLaunch: pack.debugAdapterLaunch,
                debugSessionFactory: debugSessionFactories[pack.descriptor.id]
            )
        }
    }

    static func standard(
        catalog: LanguageProviderCatalog,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) -> [any LanguageProviderRuntime] {
        standard(
            packs: LanguagePackRegistry.standard(catalog: catalog).packs,
            runtimeService: runtimeService,
            processFactory: processFactory,
            debugSessionFactories: debugSessionFactories
        )
    }
}

@MainActor
final class StdioLanguageServerSession: LanguageServerEditingSession, LanguageServerFeatureReportingSession {
    enum SessionError: LocalizedError {
        case launchFailed(String)
        case stopped
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): message
            case .stopped: "The language server stopped before answering."
            case .requestFailed(let message): message
            }
        }
    }

    private typealias ResponseHandler = (Result<Any, Error>) -> Void

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let process: any RawProcessSession
    private var readBuffer = Data()
    private var initializeRequestID: Int?
    private var nextRequestID = 1
    private var responseHandlers: [Int: ResponseHandler] = [:]
    private var pendingRequests: [(String, [String: Any], ResponseHandler)] = []
    private var initializedFeatures: LanguageServerFeatureSet = .standardEditing
    private var dynamicallyRegisteredFeatures: [String: LanguageServerFeatureSet] = [:]
    private var documentsByURI: [String: PendingDocument] = [:]
    private var openedDocumentVersions: [String: Int] = [:]
    private var lastSentDocumentTextByURI: [String: String] = [:]
    private(set) var isReady = false
    private(set) var supportedFeatures: LanguageServerFeatureSet = .standardEditing
    var onSupportedFeaturesChange: ((LanguageServerFeatureSet) -> Void)?
    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?

    private struct PendingDocument {
        let url: URL
        let languageIdentifier: String
        let text: String
    }

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
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isReady = false
                self?.initializeRequestID = nil
                self?.failPendingRequests(SessionError.stopped)
            }
        }
    }

    var isRunning: Bool { process.isRunning }

    func start(rootURL: URL) throws {
        if process.isRunning { return }
        isReady = false
        initializedFeatures = .standardEditing
        dynamicallyRegisteredFeatures = [:]
        publishSupportedFeatures()
        readBuffer = Data()
        openedDocumentVersions = [:]
        let operationID = UUID().uuidString
        do {
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: executableURL.path,
                arguments: arguments,
                workingDirectory: rootURL.standardizedFileURL.path,
                environment: environment,
                keepsStandardInputOpen: true
            ))
            let id = nextRequestID
            nextRequestID += 1
            initializeRequestID = id
            send([
                "jsonrpc": "2.0",
                "id": id,
                "method": "initialize",
                "params": [
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "clientInfo": ["name": "Lithe", "version": "0.1.0"],
                    "rootUri": rootURL.standardizedFileURL.absoluteString,
                    "capabilities": [
                    "workspace": [
                        "workspaceFolders": true,
                        "configuration": true,
                        "applyEdit": true
                    ],
                        "textDocument": [
                            "synchronization": ["didSave": true],
                            "publishDiagnostics": ["relatedInformation": true],
                            "definition": ["dynamicRegistration": true, "linkSupport": true],
                            "references": ["dynamicRegistration": true],
                            "implementation": ["dynamicRegistration": true, "linkSupport": true],
                            "hover": ["dynamicRegistration": true, "contentFormat": ["markdown", "plaintext"]],
                            "completion": ["dynamicRegistration": true, "completionItem": [
                                "documentationFormat": ["markdown", "plaintext"],
                                "snippetSupport": true,
                                "resolveSupport": ["properties": ["detail", "documentation", "textEdit", "additionalTextEdits"]]
                            ]],
                            "rename": ["dynamicRegistration": true, "prepareSupport": true],
                            "formatting": ["dynamicRegistration": true],
                            "codeAction": [
                                "dynamicRegistration": true,
                                "resolveSupport": ["properties": ["edit", "command"]],
                                "codeActionLiteralSupport": [
                                    "codeActionKind": ["valueSet": ["quickfix", "refactor", "source"]]
                                ]
                            ]
                        ],
                        "executeCommand": ["dynamicRegistration": true]
                    ],
                    "workspaceFolders": [[
                        "uri": rootURL.standardizedFileURL.absoluteString,
                        "name": rootURL.lastPathComponent
                    ]]
                ]
            ])
        } catch {
            process.stop()
            throw SessionError.launchFailed(error.localizedDescription)
        }
    }

    func stop() {
        if process.isRunning {
            send(["jsonrpc": "2.0", "method": "exit", "params": [:]])
        }
        process.stop()
        isReady = false
        initializeRequestID = nil
        readBuffer = Data()
        openedDocumentVersions = [:]
        initializedFeatures = .standardEditing
        dynamicallyRegisteredFeatures = [:]
        lastSentDocumentTextByURI = [:]
        documentsByURI = [:]
        failPendingRequests(SessionError.stopped)
    }

    func synchronizeDocument(url: URL, languageIdentifier: String, text: String) {
        let normalizedURL = url.standardizedFileURL
        let uri = normalizedURL.absoluteString
        documentsByURI[uri] = PendingDocument(
            url: normalizedURL,
            languageIdentifier: languageIdentifier,
            text: text
        )
        guard isReady else { return }
        synchronize(uri: uri)
    }

    func closeDocument(url: URL) {
        let normalizedURL = url.standardizedFileURL
        let uri = normalizedURL.absoluteString
        documentsByURI[uri] = nil
        lastSentDocumentTextByURI[uri] = nil
        if openedDocumentVersions.removeValue(forKey: uri) != nil, isReady {
            send([
                "jsonrpc": "2.0",
                "method": "textDocument/didClose",
                "params": ["textDocument": ["uri": uri]]
            ])
        }
        onDiagnostics?(normalizedURL, [])
    }

    func locations(
        method: String,
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) {
        var parameters: [String: Any] = [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.utf16Column]
        ]
        if method == "textDocument/references" {
            parameters["context"] = ["includeDeclaration": true]
        }
        request(method: method, parameters: parameters) { result in
            completion(result.map(LanguageServerResponseParser.locations))
        }
    }

    func hover(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) {
        request(
            method: "textDocument/hover",
            parameters: positionParameters(documentURL: documentURL, position: position)
        ) { result in
            completion(result.map(LanguageServerResponseParser.hover))
        }
    }

    func completions(
        documentURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) {
        var parameters = positionParameters(documentURL: documentURL, position: position)
        parameters["context"] = ["triggerKind": 1]
        request(method: "textDocument/completion", parameters: parameters) { result in
            completion(result.map(LanguageServerResponseParser.completionItems))
        }
    }

    func rename(
        documentURL: URL,
        position: LanguageServerPosition,
        newName: String,
        completion: @escaping (Result<LanguageServerWorkspaceEdit, Error>) -> Void
    ) {
        var parameters = positionParameters(documentURL: documentURL, position: position)
        parameters["newName"] = newName
        request(method: "textDocument/rename", parameters: parameters) { result in
            completion(result.map(LanguageServerResponseParser.workspaceEdit))
        }
    }

    func formatting(
        documentURL: URL,
        options: [String: Any],
        completion: @escaping (Result<[LanguageServerTextEdit], Error>) -> Void
    ) {
        let parameters: [String: Any] = [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "options": options
        ]
        request(method: "textDocument/formatting", parameters: parameters) { result in
            completion(result.map(LanguageServerResponseParser.textEdits))
        }
    }

    func codeActions(
        documentURL: URL,
        range: LanguageServerRange,
        diagnostics: [LanguageServerDiagnostic],
        completion: @escaping (Result<[LanguageServerCodeAction], Error>) -> Void
    ) {
        let diagnosticValues: [[String: Any]] = diagnostics.map { diagnostic in
            var value: [String: Any] = [
                "range": Self.foundationRange(diagnostic.range),
                "message": diagnostic.message
            ]
            if let severity = diagnostic.severity { value["severity"] = severity }
            if let source = diagnostic.source { value["source"] = source }
            if let code = diagnostic.code { value["code"] = code }
            return value
        }
        let parameters: [String: Any] = [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "range": Self.foundationRange(range),
            "context": ["diagnostics": diagnosticValues, "only": ["quickfix", "refactor"]]
        ]
        request(method: "textDocument/codeAction", parameters: parameters) { result in
            completion(result.map(LanguageServerResponseParser.codeActions))
        }
    }

    func execute(
        command: LanguageServerCommand,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        request(method: "workspace/executeCommand", parameters: [
            "command": command.command,
            "arguments": command.arguments.map(\.foundationObject)
        ]) { result in
            completion(result.map { _ in () })
        }
    }

    func resolveCompletion(
        _ item: LanguageServerCompletionItem,
        completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void
    ) {
        request(
            method: "completionItem/resolve",
            parameters: LanguageServerResponseParser.foundationCompletionItem(item)
        ) { result in
            completion(result.flatMap { value in
                guard let item = LanguageServerResponseParser.completionItem(value) else {
                    return .failure(SessionError.requestFailed("The language server returned an invalid completion item."))
                }
                return .success(item)
            })
        }
    }

    func resolveCodeAction(
        _ action: LanguageServerCodeAction,
        completion: @escaping (Result<LanguageServerCodeAction, Error>) -> Void
    ) {
        request(
            method: "codeAction/resolve",
            parameters: LanguageServerResponseParser.foundationCodeAction(action)
        ) { result in
            completion(result.flatMap { value in
                guard let action = LanguageServerResponseParser.codeAction(value) else {
                    return .failure(SessionError.requestFailed("The language server returned an invalid code action."))
                }
                return .success(action)
            })
        }
    }

    private func positionParameters(
        documentURL: URL,
        position: LanguageServerPosition
    ) -> [String: Any] {
        [
            "textDocument": ["uri": documentURL.standardizedFileURL.absoluteString],
            "position": ["line": position.line, "character": position.utf16Column]
        ]
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? process.send(framed)
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
        if let id = message["id"] as? Int,
           id == initializeRequestID,
           message["method"] == nil {
            initializeRequestID = nil
            guard message["error"] == nil else {
                process.stop()
                isReady = false
                return
            }
            initializedFeatures = LanguageServerResponseParser.serverFeatures(
                fromInitializeResult: message["result"] ?? NSNull()
            )
            dynamicallyRegisteredFeatures = [:]
            publishSupportedFeatures()
            send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
            isReady = true
            for uri in documentsByURI.keys.sorted() {
                synchronize(uri: uri)
            }
            flushPendingRequests()
            return
        }
        if let id = message["id"] as? Int,
           message["method"] == nil,
           let handler = responseHandlers.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                handler(.failure(SessionError.requestFailed(
                    error["message"] as? String ?? "The language server request failed."
                )))
            } else {
                handler(.success(message["result"] ?? NSNull()))
            }
            return
        }
        if message["method"] as? String == "textDocument/publishDiagnostics",
           let parameters = message["params"] as? [String: Any] {
            publishDiagnostics(parameters)
            return
        }
        if let method = message["method"] as? String,
           let id = message["id"],
           method == "client/registerCapability" {
            registerCapabilities(message["params"] as? [String: Any])
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            return
        }
        if let method = message["method"] as? String,
           let id = message["id"],
           method == "client/unregisterCapability" {
            unregisterCapabilities(message["params"] as? [String: Any])
            send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            return
        }
        guard message["method"] != nil, let id = message["id"] else { return }
        send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
    }

    private func registerCapabilities(_ parameters: [String: Any]?) {
        let registrations = parameters?["registrations"] as? [[String: Any]] ?? []
        for registration in registrations {
            guard let id = registration["id"] as? String,
                  let method = registration["method"] as? String else { continue }
            dynamicallyRegisteredFeatures[id] = LanguageServerResponseParser.registeredFeatures(
                for: method,
                registerOptions: registration["registerOptions"]
            )
        }
        publishSupportedFeatures()
    }

    private func unregisterCapabilities(_ parameters: [String: Any]?) {
        let registrations = (parameters?["unregisterations"] as? [[String: Any]])
            ?? (parameters?["unregistrations"] as? [[String: Any]])
            ?? []
        for registration in registrations {
            guard let id = registration["id"] as? String else { continue }
            dynamicallyRegisteredFeatures[id] = nil
        }
        publishSupportedFeatures()
    }

    private func publishSupportedFeatures() {
        supportedFeatures = dynamicallyRegisteredFeatures.values.reduce(initializedFeatures) {
            $0.union($1)
        }
        onSupportedFeaturesChange?(supportedFeatures)
    }

    private func request(
        method: String,
        parameters: [String: Any],
        completion: @escaping ResponseHandler
    ) {
        guard process.isRunning else {
            completion(.failure(SessionError.stopped))
            return
        }
        guard isReady else {
            pendingRequests.append((method, parameters, completion))
            return
        }
        sendRequest(method: method, parameters: parameters, completion: completion)
    }

    private func sendRequest(
        method: String,
        parameters: [String: Any],
        completion: @escaping ResponseHandler
    ) {
        let requiredFeature = LanguageServerResponseParser.requiredFeature(forRequestMethod: method)
        guard requiredFeature.isEmpty || supportedFeatures.contains(requiredFeature) else {
            completion(.failure(SessionError.requestFailed(
                "The language server does not support \(method)."
            )))
            return
        }
        let id = nextRequestID
        nextRequestID += 1
        responseHandlers[id] = completion
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
    }

    private func flushPendingRequests() {
        let requests = pendingRequests
        pendingRequests = []
        for (method, parameters, completion) in requests {
            sendRequest(method: method, parameters: parameters, completion: completion)
        }
    }

    private func failPendingRequests(_ error: Error) {
        let handlers = responseHandlers.values
        let queued = pendingRequests.map(\.2)
        responseHandlers = [:]
        pendingRequests = []
        handlers.forEach { $0(.failure(error)) }
        queued.forEach { $0(.failure(error)) }
    }

    private func synchronize(uri: String) {
        guard let document = documentsByURI[uri] else { return }
        if let version = openedDocumentVersions[uri] {
            guard lastSentDocumentTextByURI[uri] != document.text else { return }
            let nextVersion = version + 1
            openedDocumentVersions[uri] = nextVersion
            lastSentDocumentTextByURI[uri] = document.text
            send([
                "jsonrpc": "2.0",
                "method": "textDocument/didChange",
                "params": [
                    "textDocument": ["uri": uri, "version": nextVersion],
                    "contentChanges": [["text": document.text]]
                ]
            ])
        } else {
            openedDocumentVersions[uri] = 1
            lastSentDocumentTextByURI[uri] = document.text
            send([
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": [
                    "textDocument": [
                        "uri": uri,
                        "languageId": document.languageIdentifier,
                        "version": 1,
                        "text": document.text
                    ]
                ]
            ])
        }
    }

    private func publishDiagnostics(_ parameters: [String: Any]) {
        guard let uri = parameters["uri"] as? String,
              let url = URL(string: uri) else { return }
        let diagnostics = (parameters["diagnostics"] as? [[String: Any]] ?? []).compactMap {
            Self.parseDiagnostic($0)
        }
        onDiagnostics?(url.standardizedFileURL, diagnostics)
    }

    private static func parseDiagnostic(_ value: [String: Any]) -> LanguageServerDiagnostic? {
        guard let range = value["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startColumn = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endColumn = end["character"] as? Int,
              let message = value["message"] as? String else { return nil }
        let code = (value["code"] as? String)
            ?? (value["code"] as? Int).map(String.init)
        return LanguageServerDiagnostic(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: startLine, utf16Column: startColumn),
                end: LanguageServerPosition(line: endLine, utf16Column: endColumn)
            ),
            severity: value["severity"] as? Int,
            message: message,
            source: value["source"] as? String,
            code: code
        )
    }

    private static func foundationRange(_ range: LanguageServerRange) -> [String: Any] {
        [
            "start": ["line": range.start.line, "character": range.start.utf16Column],
            "end": ["line": range.end.line, "character": range.end.utf16Column]
        ]
    }

}
