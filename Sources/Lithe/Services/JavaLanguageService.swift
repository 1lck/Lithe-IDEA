import Foundation

@MainActor
final class JavaLanguageService: ObservableObject {
    enum ServiceError: LocalizedError {
        case serverNotInstalled
        case serverStopped
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .serverNotInstalled:
                "Java language server is not installed. Run: brew install jdtls"
            case .serverStopped:
                "Java language server stopped unexpectedly"
            case .invalidResponse:
                "Java language server returned an invalid response"
            }
        }
    }

    @Published private(set) var isStarting = false
    @Published private(set) var isReady = false
    @Published private(set) var statusMessage = "Java navigation is idle"
    @Published private(set) var diagnostics: [URL: [JavaDiagnostic]] = [:]

    var onDiagnostics: ((URL, [JavaDiagnostic]) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var responseHandlers: [Int: (Result<Any, Error>) -> Void] = [:]
    private var readyHandlers: [(Result<Void, Error>) -> Void] = []
    private var openedDocumentVersions: [String: Int] = [:]
    private var projectURL: URL?

    func configureProjectRoot(_ url: URL) {
        projectURL = url.standardizedFileURL
    }

    /// Starts JDT LS in the background while the workspace finishes opening.
    func prepare(for rootURL: URL) {
        guard !isReady, !isStarting else { return }
        ensureReady(for: rootURL) { _ in }
    }

    func locations(
        method: String,
        document: EditorDocument,
        line: Int,
        utf16Column: Int,
        completion: @escaping (Result<[JavaNavigationLocation], Error>) -> Void
    ) {
        guard document.url.pathExtension.lowercased() == "java" else {
            completion(.failure(ServiceError.invalidResponse))
            return
        }

        ensureReady(for: document.url.deletingLastPathComponent()) { [weak self, weak document] result in
            guard let self, let document else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.synchronize(document)
                var parameters: [String: Any] = [
                    "textDocument": ["uri": document.url.absoluteString],
                    "position": ["line": line, "character": utf16Column]
                ]
                if method == "textDocument/references" {
                    parameters["context"] = ["includeDeclaration": false]
                }
                self.sendRequest(method: method, parameters: parameters) { response in
                    switch response {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let value):
                        completion(.success(Self.parseLocations(value)))
                    }
                }
            }
        }
    }

    func workspaceSymbols(
        query: String,
        rootURL: URL,
        documents: [EditorDocument],
        completion: @escaping (Result<[JavaWorkspaceSymbol], Error>) -> Void
    ) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            completion(.success([]))
            return
        }

        ensureReady(for: rootURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                for document in documents where document.url.pathExtension.lowercased() == "java" {
                    self.synchronize(document)
                }
                self.sendRequest(method: "workspace/symbol", parameters: [
                    "query": normalizedQuery
                ]) { response in
                    switch response {
                    case .failure(let error): completion(.failure(error))
                    case .success(let value): completion(.success(Self.parseWorkspaceSymbols(value)))
                    }
                }
            }
        }
    }

    func inlayHints(
        document: EditorDocument,
        completion: @escaping (Result<[JavaInlayHint], Error>) -> Void
    ) {
        guard document.url.pathExtension.lowercased() == "java" else {
            completion(.success([]))
            return
        }
        ensureReady(for: document.url.deletingLastPathComponent()) { [weak self, weak document] result in
            guard let self, let document else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success:
                self.synchronize(document)
                let lines = max(0, document.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 })
                self.sendRequest(method: "textDocument/inlayHint", parameters: [
                    "textDocument": ["uri": document.url.absoluteString],
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": lines + 1, "character": 0]
                    ]
                ]) { response in
                    switch response {
                    case .failure(let error): completion(.failure(error))
                    case .success(let value): completion(.success(Self.parseInlayHints(value)))
                    }
                }
            }
        }
    }

    func update(_ document: EditorDocument) {
        guard document.url.pathExtension.lowercased() == "java" else { return }
        ensureReady(for: document.url.deletingLastPathComponent()) { [weak self, weak document] result in
            guard let self, let document else { return }
            guard case .success = result else { return }
            self.synchronize(document)
        }
    }

    func close(_ document: EditorDocument) {
        guard document.url.pathExtension.lowercased() == "java" else { return }
        let uri = document.url.absoluteString
        if isReady {
            sendNotification(method: "textDocument/didClose", parameters: [
                "textDocument": ["uri": uri]
            ])
        }
        openedDocumentVersions[uri] = nil
        diagnostics[document.url.standardizedFileURL] = nil
        onDiagnostics?(document.url.standardizedFileURL, [])
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        let error = ServiceError.serverStopped
        for handler in responseHandlers.values {
            handler(.failure(error))
        }
        for handler in readyHandlers {
            handler(.failure(error))
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        responseHandlers = [:]
        readyHandlers = []
        openedDocumentVersions = [:]
        diagnostics = [:]
        readBuffer = Data()
        isStarting = false
        isReady = false
        statusMessage = "Java navigation is idle"
    }

    private func ensureReady(
        for fileDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if isReady {
            completion(.success(()))
            return
        }
        readyHandlers.append(completion)
        guard !isStarting else { return }

        guard let executableURL = Self.serverExecutableURL() else {
            finishStartup(.failure(ServiceError.serverNotInstalled))
            return
        }

        let root = projectRoot(containing: fileDirectory)
        projectURL = root
        isStarting = true
        statusMessage = "Starting Java language server..."

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        var arguments: [String] = []
        if let javaExecutable = Self.javaExecutableURL() {
            arguments.append(contentsOf: ["--java-executable", javaExecutable.path])
        }
        arguments.append(contentsOf: ["-data", Self.dataDirectory(for: root).path])
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receive(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            // JDT LS writes JVM diagnostics and compatibility warnings to stderr
            // during normal operation. Drain the pipe without exposing that noise
            // as a user-facing navigation status.
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.process != nil else { return }
                self.stop()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: Self.dataDirectory(for: root),
                withIntermediateDirectories: true
            )
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            initialize(root: root)
        } catch {
            finishStartup(.failure(error))
        }
    }

    private func initialize(root: URL) {
        let capabilities: [String: Any] = [
            "textDocument": [
                "definition": ["dynamicRegistration": false, "linkSupport": true],
                "references": ["dynamicRegistration": false],
                "implementation": ["dynamicRegistration": false, "linkSupport": true],
                "inlayHint": ["dynamicRegistration": false, "resolveSupport": ["properties": []]],
                "publishDiagnostics": ["relatedInformation": true],
                "synchronization": ["dynamicRegistration": false, "didSave": true]
            ],
            "workspace": [
                "workspaceFolders": true,
                "configuration": true,
                "symbol": ["dynamicRegistration": false]
            ],
            "window": ["workDoneProgress": true]
        ]
        let parameters: [String: Any] = [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "Lithe", "version": "0.1.0"],
            "rootUri": root.absoluteString,
            "capabilities": capabilities,
            "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]]
        ]
        sendRequest(method: "initialize", parameters: parameters) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishStartup(.failure(error))
            case .success:
                self.sendNotification(method: "initialized", parameters: [:])
                self.sendNotification(method: "workspace/didChangeConfiguration", parameters: [
                    "settings": [
                        "java": [
                            "inlayHints": [
                                "parameterNames": ["enabled": "all"]
                            ]
                        ]
                    ]
                ])
                self.isReady = true
                self.isStarting = false
                self.statusMessage = "Java navigation ready"
                self.finishReadyHandlers(.success(()))
            }
        }
    }

    private func synchronize(_ document: EditorDocument) {
        let uri = document.url.absoluteString
        if let version = openedDocumentVersions[uri] {
            let nextVersion = version + 1
            openedDocumentVersions[uri] = nextVersion
            sendNotification(method: "textDocument/didChange", parameters: [
                "textDocument": ["uri": uri, "version": nextVersion],
                "contentChanges": [["text": document.text]]
            ])
        } else {
            openedDocumentVersions[uri] = 1
            sendNotification(method: "textDocument/didOpen", parameters: [
                "textDocument": [
                    "uri": uri,
                    "languageId": "java",
                    "version": 1,
                    "text": document.text
                ]
            ])
        }
    }

    private func sendRequest(
        method: String,
        parameters: [String: Any],
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        let id = nextRequestID
        nextRequestID += 1
        responseHandlers[id] = completion
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
    }

    private func sendNotification(method: String, parameters: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": parameters])
    }

    private func sendResponse(id: Any, result: Any) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        try? inputPipe?.fileHandleForWriting.write(contentsOf: framed)
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
            if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                handle(object)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, message["method"] == nil {
            guard let handler = responseHandlers.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                let detail = error["message"] as? String ?? ServiceError.invalidResponse.localizedDescription
                handler(.failure(NSError(domain: "JavaLanguageService", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])))
            } else {
                handler(.success(message["result"] ?? NSNull()))
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if message["id"] == nil {
            handleNotification(method: method, parameters: message["params"] as? [String: Any])
            return
        }
        guard let id = message["id"] else { return }
        switch method {
        case "workspace/configuration":
            let items = ((message["params"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            sendResponse(id: id, result: items.map { item -> Any in
                switch item["section"] as? String {
                case "java":
                    return ["inlayHints": ["parameterNames": ["enabled": "all"]]]
                case "java.inlayHints":
                    return ["parameterNames": ["enabled": "all"]]
                case "java.inlayHints.parameterNames":
                    return ["enabled": "all"]
                case "java.inlayHints.parameterNames.enabled":
                    return "all"
                default:
                    return NSNull()
                }
            })
        default:
            sendResponse(id: id, result: NSNull())
        }
    }

    private func handleNotification(method: String, parameters: [String: Any]?) {
        guard method == "textDocument/publishDiagnostics",
              let parameters,
              let uri = parameters["uri"] as? String,
              let url = URL(string: uri) else { return }
        let normalizedURL = url.standardizedFileURL
        let parsed = Self.parseDiagnostics(
            parameters["diagnostics"] as? [[String: Any]] ?? [],
            fileURL: normalizedURL
        )
        diagnostics[normalizedURL] = parsed
        onDiagnostics?(normalizedURL, parsed)
    }

    private func finishStartup(_ result: Result<Void, Error>) {
        isStarting = false
        if case .failure(let error) = result {
            statusMessage = error.localizedDescription
        }
        finishReadyHandlers(result)
    }

    private func finishReadyHandlers(_ result: Result<Void, Error>) {
        let handlers = readyHandlers
        readyHandlers = []
        handlers.forEach { $0(result) }
    }

    private func projectRoot(containing directory: URL) -> URL {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent("pom.xml").path) ||
                FileManager.default.fileExists(atPath: current.appendingPathComponent("build.gradle").path) ||
                FileManager.default.fileExists(atPath: current.appendingPathComponent("build.gradle.kts").path) ||
                FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return projectURL ?? directory
    }

    private static func serverExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/jdtls",
            "/usr/local/bin/jdtls",
            "/usr/bin/jdtls"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func javaExecutableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/opt/openjdk/bin/java",
            "/usr/local/opt/openjdk/bin/java",
            "/usr/bin/java"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func dataDirectory(for root: URL) -> URL {
        let key = String(root.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Lithe/jdtls", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private static func parseLocations(_ value: Any) -> [JavaNavigationLocation] {
        let rawLocations: [[String: Any]]
        if let array = value as? [[String: Any]] {
            rawLocations = array
        } else if let object = value as? [String: Any] {
            rawLocations = [object]
        } else {
            return []
        }

        return rawLocations.compactMap { object in
            let uri = (object["uri"] as? String) ?? (object["targetUri"] as? String)
            let range = (object["range"] as? [String: Any]) ??
                (object["targetSelectionRange"] as? [String: Any])
            let start = range?["start"] as? [String: Any]
            guard let uri, let url = URL(string: uri),
                  let line = start?["line"] as? Int,
                  let column = start?["character"] as? Int else { return nil }
            return JavaNavigationLocation(url: url, line: line, utf16Column: column)
        }
    }

    private static func parseWorkspaceSymbols(_ value: Any) -> [JavaWorkspaceSymbol] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let name = object["name"] as? String,
                  let kind = object["kind"] as? Int,
                  let location = object["location"] as? [String: Any] else { return nil }
            let uri = (location["uri"] as? String) ?? (location["targetUri"] as? String)
            let range = (location["range"] as? [String: Any]) ??
                (location["targetSelectionRange"] as? [String: Any])
            let start = range?["start"] as? [String: Any]
            guard let uri,
                  let url = URL(string: uri),
                  let line = start?["line"] as? Int,
                  let column = start?["character"] as? Int else { return nil }
            return JavaWorkspaceSymbol(
                name: name,
                containerName: object["containerName"] as? String,
                url: url.standardizedFileURL,
                line: line,
                utf16Column: column,
                kind: kind
            )
        }
    }

    private static func parseInlayHints(_ value: Any) -> [JavaInlayHint] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let position = object["position"] as? [String: Any],
                  let line = position["line"] as? Int,
                  let column = position["character"] as? Int else { return nil }
            let label: String
            if let raw = object["label"] as? String {
                label = raw
            } else if let parts = object["label"] as? [[String: Any]] {
                label = parts.compactMap { $0["value"] as? String }.joined()
            } else {
                return nil
            }
            guard !label.isEmpty else { return nil }
            return JavaInlayHint(line: line, utf16Column: column, label: label)
        }
    }

    private static func parseDiagnostics(
        _ objects: [[String: Any]],
        fileURL: URL
    ) -> [JavaDiagnostic] {
        objects.compactMap { parseDiagnostic($0, fileURL: fileURL) }
    }

    private static func parseDiagnostic(
        _ object: [String: Any],
        fileURL: URL
    ) -> JavaDiagnostic? {
            guard let range = object["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int,
                  let column = start["character"] as? Int,
                  let message = object["message"] as? String,
                  !message.isEmpty else { return nil }
            let end = range["end"] as? [String: Any]
            let endLine = end?["line"] as? Int ?? line
            let endColumn = end?["character"] as? Int ?? column + 1
            let severity = JavaDiagnosticSeverity(rawValue: object["severity"] as? Int ?? 1) ?? .error
            let source = object["source"] as? String
            let code = Self.parseDiagnosticCode(object["code"])
            let tags = Self.parseDiagnosticTags(object["tags"])
            let relatedInformation = Self.parseRelatedInformation(object["relatedInformation"])
            let id = fileURL.path + ":" + String(line) + ":" + String(column) + ":" + message + ":" + (code ?? "")
            return JavaDiagnostic(
                id: id,
                fileURL: fileURL,
                line: max(0, line),
                utf16Column: max(0, column),
                endLine: max(0, endLine),
                endUTF16Column: max(0, endColumn),
                severity: severity,
                message: message,
                source: source,
                code: code,
                tags: tags,
                relatedInformation: relatedInformation
            )
    }

    private static func parseDiagnosticCode(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? Int { return String(value) }
        return nil
    }

    private static func parseDiagnosticTags(_ value: Any?) -> Set<JavaDiagnosticTag> {
        guard let values = value as? [Any] else { return [] }
        return Set(values.compactMap { value in
            guard let rawValue = value as? Int else { return nil }
            return JavaDiagnosticTag(rawValue: rawValue)
        })
    }

    private static func parseRelatedInformation(_ value: Any?) -> [JavaDiagnosticRelatedInformation] {
        guard let objects = value as? [[String: Any]] else { return [] }
        return objects.compactMap { object in
            guard let location = object["location"] as? [String: Any],
                  let uri = location["uri"] as? String,
                  let fileURL = URL(string: uri),
                  let range = location["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int,
                  let column = start["character"] as? Int,
                  let message = object["message"] as? String,
                  !message.isEmpty else { return nil }
            return JavaDiagnosticRelatedInformation(
                fileURL: fileURL.standardizedFileURL,
                line: max(0, line),
                utf16Column: max(0, column),
                message: message
            )
        }
    }
}
