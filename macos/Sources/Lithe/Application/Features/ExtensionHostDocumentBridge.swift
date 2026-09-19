import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Projects the editor's authoritative buffers into one host generation. The cache
/// records only the last wire snapshot; it never supplies content for an edit/save.
@MainActor
final class ExtensionHostDocumentBridge {
    private struct DocumentState {
        let id: UUID
        let uri: String
        let language: String
        let revision: UInt64
        let text: String
        let isDirty: Bool
    }
    private enum Event {
        case changed(DocumentState), saved(DocumentState), closed(DocumentState)
    }
    private struct Snapshot {
        let documentID: UUID
        let revision: UInt64
        let text: String
        let isDirty: Bool
        let version: Int
    }
    private struct URIParams: Decodable { let uri: String }
    private struct EditParams: Decodable { let edits: [Edit] }
    private struct Edit: Decodable {
        let uri: String
        let range: EditRange
        let text: String
        let expectedVersion: Int?
    }
    private struct EditRange: Decodable {
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
    }

    private let connection: ExtensionHostConnection
    private let find: (URL) -> EditorDocument?
    private let open: (URL) async -> EditorDocument?
    private let save: (EditorDocument) async throws -> Void
    private let changed: (EditorDocument) -> Void
    private let languageID: (URL) -> String
    private var snapshots: [String: Snapshot] = [:]
    private var savedVersions: [String: Int] = [:]
    private var observation: AnyCancellable?
    private var deliveries: [UUID: Task<ToolingJSONValue, Error>] = [:]
    private var tail: Task<ToolingJSONValue, Error>?
    private var stopped = false

    init(
        connection: ExtensionHostConnection,
        find: @escaping (URL) -> EditorDocument?,
        open: @escaping (URL) async -> EditorDocument?,
        save: @escaping (EditorDocument) async throws -> Void,
        changed: @escaping (EditorDocument) -> Void,
        languageID: @escaping (URL) -> String
    ) {
        self.connection = connection
        self.find = find
        self.open = open
        self.save = save
        self.changed = changed
        self.languageID = languageID
        let previousClose = connection.onClosed
        connection.onClosed = { [weak self] in
            previousClose?()
            self?.stop()
        }
    }

    convenience init(connection: ExtensionHostConnection, documents: DocumentFeatureModel,
                     languageID: @escaping (URL) -> String) {
        self.init(connection: connection,
            find: { [weak documents] url in
                documents?.editorDocuments.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            }, open: { [weak documents] url in
                guard let documents else { return nil }
                await documents.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: false)
                return documents.editorDocuments.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            }, save: { [weak documents] document in
                guard let documents else { throw CancellationError() }
                try await documents.save(document)
            }, changed: { [weak documents] document in
                documents?.documentDidChange(document)
            }, languageID: languageID)
        observe(documents.documentEvents)
        for document in documents.editorDocuments {
            _ = enqueue(.changed(capture(document)))
        }
    }

    func stop() {
        stopped = true
        observation?.cancel()
        observation = nil
        deliveries.values.forEach { $0.cancel() }
        snapshots.removeAll()
        savedVersions.removeAll()
    }

    /// Subscribe after host initialization, before sending activation events.
    func observe(_ events: AnyPublisher<DocumentFeatureEvent, Never>) {
        observation?.cancel()
        observation = events.sink { [weak self] event in
            guard let self, !self.stopped else { return }
            switch event {
            case .opened(let document), .changed(let document):
                _ = self.enqueue(.changed(self.capture(document)))
            case .saved(let document):
                _ = self.enqueue(.saved(self.capture(document)))
            case .closed(let document):
                _ = self.enqueue(.closed(self.capture(document)))
            }
        }
    }

    func waitForPendingEvents() async throws { _ = try await tail?.value }

    private func capture(_ document: EditorDocument) -> DocumentState {
        DocumentState(id: document.id, uri: document.url.standardizedFileURL.absoluteString,
            language: languageID(document.url), revision: document.lifecycleState.revision,
            text: document.text, isDirty: document.isDirty)
    }

    private func enqueue(_ event: Event) -> Task<ToolingJSONValue, Error> {
        let id = UUID()
        let previous = tail
        let task = Task { @MainActor [weak self] () throws -> ToolingJSONValue in
            guard let self else { throw CancellationError() }
            defer { self.deliveries.removeValue(forKey: id) }
            do {
                if let previous { _ = try await previous.value }
                try self.checkActive()
                switch event {
                case .changed(let document): return try await self.synchronize(document)
                case .saved(let document):
                    let value = try await self.synchronize(document)
                    guard !document.isDirty else { return value }
                    let version = self.snapshots[document.uri]?.version
                    if self.savedVersions[document.uri] != version {
                        try await self.connection.notify("host/documentSaved", params: .object(["uri": .string(document.uri)]))
                        self.savedVersions[document.uri] = version
                    }
                    return value
                case .closed(let document):
                    guard self.snapshots[document.uri]?.documentID == document.id else { return .null }
                    self.snapshots.removeValue(forKey: document.uri)
                    self.savedVersions.removeValue(forKey: document.uri)
                    try await self.connection.notify("host/documentClosed", params: .object(["uri": .string(document.uri)]))
                    return .null
                }
            } catch {
                if !self.stopped {
                    self.connection.onDiagnostic?("Document synchronization failed: \(error.localizedDescription)")
                    self.stop()
                    self.connection.close()
                }
                throw error
            }
        }
        deliveries[id] = task
        tail = task
        return task
    }

    /// Returns nil only for methods owned by a different Lithe service adapter.
    func handle(_ method: String, params: ToolingJSONValue) async throws -> ToolingJSONValue? {
        try checkActive()
        switch method {
        case "lithe/openDocument":
            let url = try parseURL(decode(URIParams.self, params).uri)
            guard let document = await open(url) else {
                throw ExtensionHostFailure("documentNotFound", "Could not open the requested document.")
            }
            try await synchronizeEditor(document)
            try checkActive()
            return try await synchronize(document)
        case "lithe/applyWorkspaceEdit":
            return try await apply(decode(EditParams.self, params).edits)
        case "lithe/saveDocument":
            let url = try parseURL(decode(URIParams.self, params).uri)
            guard let document = find(url) else {
                throw ExtensionHostFailure("documentNotFound", "The document is no longer open.")
            }
            try await save(document)
            try checkActive()
            guard find(url) === document, !document.isDirty else {
                return .object(["saved": .bool(false)])
            }
            _ = try await enqueue(.saved(capture(document))).value
            return .object(["saved": .bool(true)])
        default: return nil
        }
    }

    /// Must be awaited before returning a successful edit/save response to the host.
    @discardableResult
    func synchronize(_ document: EditorDocument) async throws -> ToolingJSONValue {
        try checkActive()
        return try await enqueue(.changed(capture(document))).value
    }

    private func synchronize(_ document: DocumentState) async throws -> ToolingJSONValue {
        try checkActive()
        let uri = document.uri
        if let existing = snapshots[uri], existing.documentID != document.id {
            snapshots.removeValue(forKey: uri)
            savedVersions.removeValue(forKey: uri)
            try await connection.notify("host/documentClosed", params: .object(["uri": .string(uri)]))
        }
        let old = snapshots[uri]
        let changed = old?.documentID != document.id || old?.revision != document.revision
            || old?.text != document.text || old?.isDirty != document.isDirty
        let snapshot = Snapshot(documentID: document.id, revision: document.revision,
            text: document.text, isDirty: document.isDirty,
            version: (old?.version ?? 0) + (changed ? 1 : 0))
        let value: ToolingJSONValue = .object([
            "uri": .string(uri), "languageId": .string(document.language),
            "version": .integer(snapshot.version), "text": .string(snapshot.text), "isDirty": .bool(snapshot.isDirty)
        ])
        // Reserve the version before suspending on I/O so concurrent events cannot reuse it.
        snapshots[uri] = snapshot
        if let old, changed {
            let end = Self.endPosition(old.text)
            let changes: [ToolingJSONValue] = old.text == snapshot.text ? [] : [.object([
                "range": .object(["startLine": .integer(1), "startColumn": .integer(1),
                                  "endLine": .integer(end.line), "endColumn": .integer(end.column)]),
                "rangeOffset": .integer(0), "rangeLength": .integer(old.text.utf16.count), "text": .string(snapshot.text)
            ])]
            try await connection.notify("host/documentChanged", params: .object([
                "uri": .string(uri), "version": .integer(snapshot.version),
                "changes": .array(changes), "isDirty": .bool(snapshot.isDirty)
            ]))
        } else if old == nil {
            try await connection.notify("host/documentOpened", params: value)
        }
        return value
    }

    func close(_ document: EditorDocument) async throws {
        try checkActive()
        _ = try await enqueue(.closed(capture(document))).value
    }

    deinit { deliveries.values.forEach { $0.cancel() } }

    private func apply(_ edits: [Edit]) async throws -> ToolingJSONValue {
        var targets: [String: EditorDocument] = [:]
        for edit in edits {
            let url = try parseURL(edit.uri)
            let key = url.absoluteString
            if targets[key] == nil {
                let existing = find(url)
                let loaded = existing == nil ? await open(url) : existing
                guard let document = loaded else {
                    return .object(["applied": .bool(false)])
                }
                targets[key] = document
            }
        }
        let ordered = targets.keys.sorted()
        let preparation = try await EditorClosingPreparation.acquire(ordered.compactMap { targets[$0] })
        defer { preparation.release() }
        for key in ordered { try await synchronizeEditor(targets[key]!) }
        try checkActive()
        var replacements: [(EditorDocument, String)] = []
        // Validate every document and compute all replacements before the first mutation.
        for key in ordered {
            let document = targets[key]!
            guard find(document.url) === document, document.url.standardizedFileURL.absoluteString == key,
                  !document.isReadOnly else { return .object(["applied": .bool(false)]) }
            let selected = try edits.filter { try parseURL($0.uri).absoluteString == key }
            let snapshot = snapshots[key]
            for edit in selected where edit.expectedVersion != nil {
                guard snapshot?.version == edit.expectedVersion, snapshot?.documentID == document.id,
                      snapshot?.revision == document.lifecycleState.revision, snapshot?.text == document.text else {
                    return .object(["applied": .bool(false)])
                }
            }
            let normalized = try selected.map { edit -> LanguageServerTextEdit in
                let range = edit.range
                guard Self.offset(line: range.startLine, column: range.startColumn, in: document.text) != nil,
                      Self.offset(line: range.endLine, column: range.endColumn, in: document.text) != nil else {
                    throw ExtensionHostFailure("invalidParams", "Workspace edit range is outside the document.")
                }
                return LanguageServerTextEdit(range: LanguageServerRange(
                    start: LanguageServerPosition(line: range.startLine - 1, utf16Column: range.startColumn - 1),
                    end: LanguageServerPosition(line: range.endLine - 1, utf16Column: range.endColumn - 1)
                ), newText: edit.text)
            }
            replacements.append((document, try LanguageServerTextEditApplicator.apply(normalized, to: document.text)))
        }
        try checkActive()
        for (document, text) in replacements { document.text = text; changed(document) }
        for (document, _) in replacements { _ = try await synchronize(document) }
        return .object(["applied": .bool(true)])
    }

    private func synchronizeEditor(_ document: EditorDocument) async throws {
        try checkActive()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.withSynchronizedEditor { continuation.resume(with: $0) }
        }
        try checkActive()
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        if stopped { throw ExtensionHostFailure("shuttingDown", "Document bridge is stopped.") }
    }

    private func parseURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.isFileURL else {
            throw ExtensionHostFailure("unsupportedApi", "Only file documents are supported by this adapter.")
        }
        return url.standardizedFileURL
    }

    private func decode<T: Decodable>(_ type: T.Type, _ params: ToolingJSONValue) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(params)) }
        catch { throw ExtensionHostFailure("invalidParams", "Invalid document request parameters.") }
    }

    private static func endPosition(_ text: String) -> (line: Int, column: Int) {
        let units = Array(text.utf16)
        var line = 1, column = 1, index = 0
        while index < units.count {
            let unit = units[index]
            if unit == 13 || unit == 10 {
                if unit == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                line += 1; column = 1
            } else { column += 1 }
            index += 1
        }
        return (line, column)
    }

    private static func offset(line: Int, column: Int, in text: String) -> Int? {
        guard line > 0, column > 0 else { return nil }
        let units = Array(text.utf16)
        var currentLine = 1, currentColumn = 1, index = 0
        while index < units.count {
            if currentLine == line, currentColumn == column { return index }
            let unit = units[index]
            if unit == 13 || unit == 10 {
                if unit == 13, index + 1 < units.count, units[index + 1] == 10 { index += 1 }
                currentLine += 1; currentColumn = 1
            } else { currentColumn += 1 }
            index += 1
        }
        return currentLine == line && currentColumn == column ? index : nil
    }
}
