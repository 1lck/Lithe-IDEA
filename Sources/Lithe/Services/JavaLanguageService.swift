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
    private let runtimeService: ProjectRuntimeService

    init(runtimeService: ProjectRuntimeService) {
        self.runtimeService = runtimeService
    }

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
                        let locations = Self.parseLocations(value)
                        if locations.isEmpty, method == "textDocument/definition" {
                            self.resolveMissingJDKDefinition(
                                document: document,
                                line: line,
                                utf16Column: utf16Column,
                                parameters: parameters,
                                completion: completion
                            )
                        } else {
                            self.resolveExternalLocations(locations, completion: completion)
                        }
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
        if isReady, !document.isReadOnly {
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
        if let javaExecutable = runtimeService.javaExecutableURL() {
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

    private func executeCommand(
        command: String,
        arguments: [Any],
        completion: @escaping (Result<Any, Error>) -> Void
    ) {
        ensureReady(for: projectURL ?? FileManager.default.homeDirectoryForCurrentUser) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.sendRequest(method: "workspace/executeCommand", parameters: [
                    "command": command,
                    "arguments": arguments
                ], completion: completion)
            }
        }
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

    private static func dataDirectory(for root: URL) -> URL {
        let key = String(root.path.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Lithe/jdtls", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func resolveExternalLocations(
        _ locations: [JavaNavigationLocation],
        completion: @escaping (Result<[JavaNavigationLocation], Error>) -> Void
    ) {
        func resolveNext(
            at index: Int,
            resolved: [JavaNavigationLocation]
        ) {
            guard index < locations.count else {
                completion(.success(resolved))
                return
            }

            let location = locations[index]
            guard location.url.scheme?.lowercased() != "file" else {
                resolveNext(at: index + 1, resolved: resolved + [location])
                return
            }

            if let source = jdkSource(for: location.url),
               let sourceURL = Self.materializeLibrarySource(source, for: location.url) {
                let materialized = JavaNavigationLocation(
                    url: sourceURL,
                    line: location.line,
                    utf16Column: location.utf16Column,
                    isReadOnly: true,
                    displayPath: Self.displayPath(for: location.url)
                )
                resolveNext(at: index + 1, resolved: resolved + [materialized])
                return
            }

            executeCommand(command: "java.decompile", arguments: [location.url.absoluteString]) { result in
                switch result {
                case .success(let value) where value is String:
                    let content = value as! String
                    if let sourceURL = Self.materializeLibrarySource(content, for: location.url) {
                        let materialized = JavaNavigationLocation(
                            url: sourceURL,
                            line: location.line,
                            utf16Column: location.utf16Column,
                            isReadOnly: true,
                            displayPath: Self.displayPath(for: location.url)
                        )
                        resolveNext(at: index + 1, resolved: resolved + [materialized])
                    } else {
                        resolveNext(at: index + 1, resolved: resolved)
                    }
                case .success, .failure:
                    resolveNext(at: index + 1, resolved: resolved)
                }
            }
        }

        resolveNext(at: 0, resolved: [])
    }

    private func resolveMissingJDKDefinition(
        document: EditorDocument,
        line: Int,
        utf16Column: Int,
        parameters: [String: Any],
        completion: @escaping (Result<[JavaNavigationLocation], Error>) -> Void
    ) {
        let finish: (String?) -> Void = { qualifiedName in
            guard let qualifiedName,
                  let symbol = Self.identifier(at: line, utf16Column: utf16Column, in: document.text),
                  let location = self.jdkDefinitionLocation(
                      for: qualifiedName,
                      symbol: symbol
                  ) else {
                completion(.success([]))
                return
            }
            completion(.success([location]))
        }

        executeCommand(command: "java.getFullyQualifiedName", arguments: [parameters]) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result,
               let qualifiedName = value as? String,
               !qualifiedName.isEmpty {
                finish(qualifiedName)
                return
            }

            self.sendRequest(method: "textDocument/hover", parameters: parameters) { hoverResult in
                switch hoverResult {
                case .success(let value):
                    finish(Self.qualifiedName(fromHover: value, symbol: Self.identifier(
                        at: line,
                        utf16Column: utf16Column,
                        in: document.text
                    )))
                case .failure:
                    completion(.success([]))
                }
            }
        }
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
                (object["targetSelectionRange"] as? [String: Any]) ??
                (object["targetRange"] as? [String: Any])
            let start = range?["start"] as? [String: Any]
            guard let uri, let url = URL(string: uri),
                  let line = start?["line"] as? Int,
                  let column = start?["character"] as? Int else { return nil }
            return JavaNavigationLocation(url: url, line: line, utf16Column: column)
        }
    }

    private func javaHomeURL() -> URL? {
        guard let javaExecutable = runtimeService.javaExecutableURL() else { return nil }
        return javaExecutable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private func jdkSource(for uri: URL) -> String? {
        guard uri.scheme?.lowercased() == "jdt",
              let entry = Self.jdkSourceEntry(for: uri),
              let javaHome = javaHomeURL() else { return nil }

        let archives = [
            javaHome.appendingPathComponent("lib/src.zip"),
            javaHome.appendingPathComponent("src.zip")
        ]
        let entries = [entry, entry.hasPrefix("java.base/") ? String(entry.dropFirst("java.base/".count)) : "java.base/\(entry)"]
        for archive in archives where FileManager.default.fileExists(atPath: archive.path) {
            for candidate in entries where !candidate.isEmpty {
                if let source = Self.readZipEntry(candidate, from: archive), !source.isEmpty {
                    return source
                }
            }
        }
        return nil
    }

    private static func jdkSourceEntry(for uri: URL) -> String? {
        let components = uri.path
            .split(separator: "/")
            .map(String.init)
        guard let last = components.last,
              last.hasSuffix(".class") else { return nil }
        var sourceComponents = components
        sourceComponents[sourceComponents.count - 1] = String(last.dropLast(".class".count)) + ".java"
        return sourceComponents.joined(separator: "/")
    }

    private static func readZipEntry(_ entry: String, from archive: URL) -> String? {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, entry]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func materializeLibrarySource(_ content: String, for uri: URL) -> URL? {
        guard !content.isEmpty else { return nil }
        let key = String(uri.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }, radix: 16)
        let baseName = uri.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_$-]", with: "_", options: .regularExpression)
        let fileName = "\(baseName.isEmpty ? "JavaLibrary" : baseName)-\(key).java"
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Lithe/java-sources", isDirectory: true)
        let destination = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            return nil
        }
    }

    private static func displayPath(for uri: URL) -> String {
        let components = uri.path.split(separator: "/").map(String.init)
        guard let last = components.last else { return uri.lastPathComponent }
        var displayComponents = components
        if last.hasSuffix(".class") {
            displayComponents[displayComponents.count - 1] = String(last.dropLast(".class".count)) + ".java"
        }
        return displayComponents.joined(separator: "/")
    }

    private static func identifier(at line: Int, utf16Column: Int, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.indices.contains(line) else { return nil }
        let units = Array(lines[line].utf16)
        guard !units.isEmpty else { return nil }
        var index = min(max(0, utf16Column), units.count - 1)
        if !isJavaIdentifierUnit(units[index]), index > 0,
           isJavaIdentifierUnit(units[index - 1]) {
            index -= 1
        }
        guard isJavaIdentifierUnit(units[index]) else { return nil }
        var start = index
        while start > 0, isJavaIdentifierUnit(units[start - 1]) { start -= 1 }
        var end = index + 1
        while end < units.count, isJavaIdentifierUnit(units[end]) { end += 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func isJavaIdentifierUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) ||
            (unit >= 65 && unit <= 90) ||
            (unit >= 97 && unit <= 122) ||
            unit == 95 || unit == 36
    }

    private static func qualifiedName(fromHover value: Any, symbol: String?) -> String? {
        guard let object = value as? [String: Any],
              let contents = object["contents"] as? [Any] else { return nil }
        let text = contents.compactMap { item -> String? in
            if let string = item as? String { return string }
            return (item as? [String: Any])?["value"] as? String
        }.joined(separator: "\n")
        guard !text.isEmpty,
              let expression = try? NSRegularExpression(
                  pattern: "\\b(?:java|javax|jdk|sun)\\.[A-Za-z0-9_$.]+"
              ) else { return nil }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let matches = expression.matches(in: text, range: fullRange).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        guard !matches.isEmpty else { return nil }
        if let symbol {
            if let matching = matches.last(where: { $0.split(separator: ".").last.map(String.init) == symbol }) {
                return matching
            }
        }
        return matches.first
    }

    private func jdkDefinitionLocation(
        for qualifiedName: String,
        symbol: String
    ) -> JavaNavigationLocation? {
        let parts = qualifiedName.split(separator: ".").map(String.init)
        guard parts.count >= 2,
              ["java", "javax", "jdk", "sun"].contains(parts[0]) else { return nil }

        guard let typeIndex = parts.firstIndex(where: { part in
            guard let first = part.first else { return false }
            return first.isUppercase || part.contains("$")
        }), typeIndex > 0 else { return nil }

        let packageParts = Array(parts[..<typeIndex])
        let typeParts = Array(parts[typeIndex...])
        guard let primaryType = typeParts.first else { return nil }
        let sourcePath = (packageParts + [primaryType]).joined(separator: "/") + ".class"
        guard let uri = URL(string: "jdt://contents/java.base/\(sourcePath)"),
              let source = jdkSource(for: uri),
              let sourceURL = Self.materializeLibrarySource(source, for: uri) else { return nil }

        let declarationName: String
        let memberName: String?
        if typeParts.count == 1 {
            declarationName = primaryType
            memberName = nil
        } else if typeParts.last == primaryType || typeParts.last == symbol {
            declarationName = primaryType
            memberName = typeParts.last
        } else if typeParts.last?.first?.isLowercase == true {
            declarationName = primaryType
            memberName = typeParts.last
        } else {
            declarationName = typeParts.last ?? primaryType
            memberName = nil
        }

        let position = Self.sourceDefinitionPosition(
            in: source,
            declarationName: declarationName,
            memberName: memberName
        ) ?? (0, 0)
        return JavaNavigationLocation(
            url: sourceURL,
            line: position.0,
            utf16Column: position.1,
            isReadOnly: true,
            displayPath: Self.displayPath(for: uri)
        )
    }

    private static func sourceDefinitionPosition(
        in source: String,
        declarationName: String,
        memberName: String?
    ) -> (Int, Int)? {
        let lines = source.components(separatedBy: .newlines)
        if let memberName {
            let escapedMember = NSRegularExpression.escapedPattern(for: memberName)
            let methodPattern = "\\b\(escapedMember)\\s*\\("
            if let expression = try? NSRegularExpression(pattern: methodPattern) {
                for (lineNumber, line) in lines.enumerated() {
                    let range = NSRange(location: 0, length: (line as NSString).length)
                    guard let match = expression.firstMatch(in: line, range: range) else { continue }
                    let prefix = (line as NSString).substring(to: match.range.location)
                    let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.hasPrefix("*") && !trimmed.hasPrefix("//"),
                          !trimmed.contains("#"),
                          !trimmed.hasSuffix(".") else { continue }
                    return (lineNumber, match.range.location)
                }
            }

            let fieldPattern = "\\b\(escapedMember)\\s*(?:=|;)"
            if let expression = try? NSRegularExpression(pattern: fieldPattern) {
                for (lineNumber, line) in lines.enumerated() {
                    let range = NSRange(location: 0, length: (line as NSString).length)
                    if let match = expression.firstMatch(in: line, range: range) {
                        return (lineNumber, match.range.location)
                    }
                }
            }
        }

        let declarationPattern = "\\b(?:class|interface|enum|record)\\s+\(NSRegularExpression.escapedPattern(for: declarationName))\\b"
        if let expression = try? NSRegularExpression(pattern: declarationPattern) {
            for (lineNumber, line) in lines.enumerated() {
                let range = NSRange(location: 0, length: (line as NSString).length)
                guard expression.firstMatch(in: line, range: range) != nil else { continue }
                let nameRange = (line as NSString).range(of: declarationName)
                if nameRange.location != NSNotFound {
                    return (lineNumber, nameRange.location)
                }
            }
        }
        return nil
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
