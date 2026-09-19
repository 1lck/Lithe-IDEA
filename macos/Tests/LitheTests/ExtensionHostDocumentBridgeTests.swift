import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
@testable import Lithe
import Testing

@MainActor
struct ExtensionHostDocumentBridgeTests {
    @Test func documentEventsCaptureOrderedSnapshotsAndDeduplicateSavedNotifications() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        let events = PassthroughSubject<DocumentFeatureEvent, Never>()
        harness.bridge.observe(events.eraseToAnyPublisher())
        events.send(.opened(harness.first))
        harness.first.text = "edited"
        events.send(.changed(harness.first))
        harness.first.markSavedWithoutWriting()
        events.send(.saved(harness.first))
        events.send(.saved(harness.first))
        events.send(.closed(harness.first))
        // None of the asynchronous writes have run yet; mutable documents now
        // contain newer state, but every event must retain its original bytes.
        harness.first.text = "unpublished"
        try await harness.bridge.waitForPendingEvents()
        #expect(harness.transport.methods == ["host/documentOpened", "host/documentChanged",
            "host/documentChanged", "host/documentSaved", "host/documentClosed"])
        #expect(harness.transport.params[0]["text"] == .string("first\n"))
        #expect(harness.transport.params[1]["isDirty"] == .bool(true))
        #expect(harness.transport.params[2]["isDirty"] == .bool(false))
        #expect(harness.transport.params[2]["version"] == .integer(3))
    }

    @Test func stoppingUnsubscribesAndCancelsQueuedDocumentEvents() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        let events = PassthroughSubject<DocumentFeatureEvent, Never>()
        harness.bridge.observe(events.eraseToAnyPublisher())
        events.send(.opened(harness.first))
        harness.bridge.stop()
        events.send(.changed(harness.first))
        await #expect(throws: (any Error).self) { try await harness.bridge.waitForPendingEvents() }
        #expect(harness.transport.methods.isEmpty)
    }

    @Test func reopeningSameURIRejectsLateCloseFromPreviousDocument() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        let events = PassthroughSubject<DocumentFeatureEvent, Never>()
        harness.bridge.observe(events.eraseToAnyPublisher())
        events.send(.opened(harness.first))
        let reopened = EditorDocument(url: harness.first.url, text: "reopened", modificationDate: nil)
        events.send(.opened(reopened))
        events.send(.closed(harness.first))
        try await harness.bridge.waitForPendingEvents()
        #expect(harness.transport.methods == ["host/documentOpened", "host/documentClosed", "host/documentOpened"])
        #expect(harness.transport.params.last?["text"] == .string("reopened"))
        events.send(.closed(reopened))
        try await harness.bridge.waitForPendingEvents()
        #expect(harness.transport.methods.last == "host/documentClosed")
    }

    @Test func staleVersionRejectsEntireWorkspaceEdit() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        _ = try await harness.bridge.synchronize(harness.first)
        _ = try await harness.bridge.synchronize(harness.second)
        harness.second.text = "newer edit"
        let result = try await harness.bridge.handle("lithe/applyWorkspaceEdit", params: .object([
            "edits": .array([harness.edit(harness.first), harness.edit(harness.second)])
        ]))
        #expect(result == .object(["applied": .bool(false)]))
        #expect(harness.first.text == "first\n")
        #expect(harness.second.text == "newer edit")
    }

    @Test func editAndSavePublishChangesBeforeSuccess() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        _ = try await harness.bridge.synchronize(harness.first)
        let edited = try await harness.bridge.handle("lithe/applyWorkspaceEdit", params: .object([
            "edits": .array([harness.edit(harness.first)])
        ]))
        #expect(edited == .object(["applied": .bool(true)]))
        #expect(harness.first.text == "prefix first\n")
        #expect(harness.first.isDirty)
        #expect(harness.transport.methods == ["host/documentOpened", "host/documentChanged"])
        let saved = try await harness.bridge.handle("lithe/saveDocument", params: .object([
            "uri": .string(harness.first.url.absoluteString)
        ]))
        #expect(saved == .object(["saved": .bool(true)]))
        #expect(!harness.first.isDirty)
        #expect(harness.transport.methods.suffix(2) == ["host/documentChanged", "host/documentSaved"])
    }

    @Test func invalidRangeDoesNotMutateAnyDocument() async throws {
        let harness = DocumentBridgeHarness()
        defer { harness.stop() }
        _ = try await harness.bridge.synchronize(harness.first)
        do {
            _ = try await harness.bridge.handle("lithe/applyWorkspaceEdit", params: .object([
                "edits": .array([harness.edit(harness.first, column: 999)])
            ]))
            Issue.record("Invalid range was accepted")
        } catch let error as ExtensionHostFailure { #expect(error.code == "invalidParams") }
        #expect(harness.first.text == "first\n")
    }
}

@MainActor
private final class DocumentBridgeHarness {
    let first = EditorDocument(url: URL(fileURLWithPath: "/workspace/first.java"), text: "first\n", modificationDate: nil)
    let second = EditorDocument(url: URL(fileURLWithPath: "/workspace/second.java"), text: "second\n", modificationDate: nil)
    let transport = DocumentRecordingTransport()
    let connection: ExtensionHostConnection
    lazy var bridge = ExtensionHostDocumentBridge(connection: connection,
        find: { [weak self] url in self?.document(url) }, open: { [weak self] url in self?.document(url) },
        save: { $0.markSavedWithoutWriting() }, changed: { _ in }, languageID: { _ in "java" })

    init() { connection = ExtensionHostConnection(transport: transport) }
    func stop() { bridge.stop(); connection.close() }
    func document(_ url: URL) -> EditorDocument? { [first, second].first { $0.url == url } }
    func edit(_ document: EditorDocument, column: Int = 1) -> ToolingJSONValue {
        .object(["uri": .string(document.url.absoluteString), "expectedVersion": .integer(1), "text": .string("prefix "),
                 "range": .object(["startLine": .integer(1), "startColumn": .integer(column),
                                   "endLine": .integer(1), "endColumn": .integer(column)])])
    }
}

@MainActor
final class DocumentRecordingTransport: ExtensionHostTransport {
    var methods: [String] = []
    var params: [[String: ToolingJSONValue]] = []
    func send(_ data: Data) async throws {
        let message = try JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
        if case .string(let method) = message["method"] {
            methods.append(method)
            if case .object(let value) = message["params"] { params.append(value) }
        }
    }
}
