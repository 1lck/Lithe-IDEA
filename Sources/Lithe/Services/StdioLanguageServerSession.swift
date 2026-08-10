import Foundation

protocol LspClientCore: Sendable {
    func lspClientInitialize(rootURL: URL) -> RustCoreBridge.LspClientResponsePayload?
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
    func lspClientRequest(
        state: ToolingJSONValue,
        fileURL: URL,
        method: String,
        position: LanguageServerPosition?,
        newName: String?
    ) -> RustCoreBridge.LspClientResponsePayload?
    func lspClientApplyServerMessage(
        state: ToolingJSONValue,
        message: String
    ) -> RustCoreBridge.LspClientResponsePayload?
}

extension RustCoreBridge: LspClientCore {}

@MainActor
final class StdioLanguageServerSession: LanguageServerSession {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let process: any RawProcessSession
    private let core: any LspClientCore
    private var state: ToolingJSONValue?
    private var readBuffer = Data()
    private var openedDocumentURIs: Set<String> = []
    private var pendingDocuments: [String: PendingDocument] = [:]
    private var responseHandlers: [String: (RustCoreBridge.LspClientEventPayload) -> Void] = [:]
    private var isInitialized = false

    var onDiagnostics: ((URL, [LanguageServerDiagnostic]) -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        process: any RawProcessSession,
        core: any LspClientCore = RustCoreBridge()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.process = process
        self.core = core
        process.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.resetTransientState() }
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
        guard let response = core.lspClientInitialize(rootURL: rootURL) else { return }
        apply(response)
    }

    func synchronize(fileURL: URL, text: String, languageID: String) throws {
        guard let state else { return }
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
        let response: RustCoreBridge.LspClientResponsePayload?
        if openedDocumentURIs.contains(uri) {
            response = core.lspClientChangeDocument(state: state, fileURL: standardizedURL, text: text)
        } else {
            response = core.lspClientOpenDocument(
                state: state,
                fileURL: standardizedURL,
                languageID: languageID,
                text: text
            )
            openedDocumentURIs.insert(uri)
        }
        if let response { apply(response) }
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
        ) { event in
            completion(Self.decodeEventResult(event, as: RustCoreBridge.BuiltinCompletionPayload.self)
                .map { $0.makeModels() })
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
        ) { event in
            completion(Self.decodeEventResult(event, as: RustCoreBridge.BuiltinHoverPayload.self)
                .map { $0.hover?.makeModel() })
        }
    }

    func navigate(
        method: String,
        fileURL: URL,
        position: LanguageServerPosition,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        try requestFeature(method: method, fileURL: fileURL, position: position) { event in
            completion(Self.decodeEventResult(event, as: RustCoreBridge.BuiltinNavigationPayload.self)
                .map { $0.makeModels() })
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
        ) { event in
            completion(Self.decodeEventResult(event, as: RustCoreBridge.LspWorkspaceEditPayload.self)
                .map { $0.makeModel() })
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
        ) { event in
            completion(Self.decodeEventResult(event, as: RustCoreBridge.LspFormattingPayload.self)
                .map { $0.makeModels() })
        }
    }

    func stop() {
        process.stop()
        resetTransientState()
    }

    private func apply(_ response: RustCoreBridge.LspClientResponsePayload) {
        state = response.state
        response.messages.forEach(sendRawJSON)
        handle(response.events)
    }

    private func handle(_ events: [RustCoreBridge.LspClientEventPayload]) {
        for event in events {
            if let requestID = event.requestId,
               let handler = responseHandlers.removeValue(forKey: requestID) {
                handler(event)
            }
            if event.method == "initialize", event.kind == "response" {
                isInitialized = true
                flushPendingDocuments()
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
        completion: @escaping (RustCoreBridge.LspClientEventPayload) -> Void
    ) throws {
        guard let state, isInitialized else {
            throw StdioLanguageServerSessionError.notReady
        }
        guard openedDocumentURIs.contains(fileURL.standardizedFileURL.absoluteString) else {
            throw StdioLanguageServerSessionError.documentNotOpen
        }
        guard let response = core.lspClientRequest(
            state: state,
            fileURL: fileURL,
            method: method,
            position: position,
            newName: newName
        ) else {
            throw StdioLanguageServerSessionError.requestRejected
        }
        self.state = response.state
        for message in response.messages {
            if let requestID = Self.requestID(from: message) {
                responseHandlers[requestID] = completion
            }
            sendRawJSON(message)
        }
        handle(response.events)
    }

    private func flushPendingDocuments() {
        let documents = pendingDocuments.values
        pendingDocuments.removeAll()
        for document in documents {
            try? synchronize(
                fileURL: document.fileURL,
                text: document.text,
                languageID: document.languageID
            )
        }
    }

    private func sendRawJSON(_ message: String) {
        guard let body = message.data(using: .utf8) else { return }
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
            guard let message = String(data: body, encoding: .utf8),
                  let state else { continue }
            if let response = core.lspClientApplyServerMessage(state: state, message: message) {
                apply(response)
            }
        }
    }

    private func resetTransientState() {
        state = nil
        readBuffer = Data()
        openedDocumentURIs = []
        pendingDocuments = [:]
        responseHandlers = [:]
        isInitialized = false
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

    private enum StdioLanguageServerSessionError: LocalizedError {
        case notReady
        case documentNotOpen
        case requestRejected
        case missingResult
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                "Language server is not ready."
            case .documentNotOpen:
                "Document is not open in the language server."
            case .requestRejected:
                "Language server request was rejected by Rust core."
            case .missingResult:
                "Language server response did not include a result."
            case .serverError(let message):
                message
            }
        }
    }
}
