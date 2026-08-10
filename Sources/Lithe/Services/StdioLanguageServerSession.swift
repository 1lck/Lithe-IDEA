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

    func stop() {
        process.stop()
        resetTransientState()
    }

    private func apply(_ response: RustCoreBridge.LspClientResponsePayload) {
        state = response.state
        response.messages.forEach(sendRawJSON)
        for event in response.events {
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
        isInitialized = false
    }

    private struct PendingDocument {
        let fileURL: URL
        let text: String
        let languageID: String
    }
}
