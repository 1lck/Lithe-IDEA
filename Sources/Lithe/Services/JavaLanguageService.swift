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
        readBuffer = Data()
        projectURL = nil
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
                "synchronization": ["dynamicRegistration": false, "didSave": true]
            ],
            "workspace": ["workspaceFolders": true, "configuration": true],
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

        guard let method = message["method"] as? String, let id = message["id"] else { return }
        switch method {
        case "workspace/configuration":
            let items = ((message["params"] as? [String: Any])?["items"] as? [Any]) ?? []
            sendResponse(id: id, result: items.map { _ in NSNull() })
        default:
            sendResponse(id: id, result: NSNull())
        }
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
}
