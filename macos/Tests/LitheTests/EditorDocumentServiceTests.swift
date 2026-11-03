import Foundation
import Testing
@testable import Lithe

private func at(_ line: Int, _ column: Int) -> EditorTextPosition { EditorTextPosition(line: line, column: column) }

/// In-memory editor surface: applies validated batches to the document the way
/// the Monaco adapter does, as one step, and can simulate editor refusals.
@MainActor
private final class FakeEditorSurface: EditorDocumentSurface {
    var selections: [EditorSelection] = []
    var failure: EditorDocumentServiceError?
    private(set) var requests: [EditorSurfaceEditRequest] = []
    private(set) var undoStack: [String] = []

    func readSelections(of document: EditorDocument) async throws -> EditorSurfaceSelections {
        if let failure { throw failure }
        return EditorSurfaceSelections(selections: selections, version: document.contentVersion)
    }

    func apply(_ request: EditorSurfaceEditRequest, to document: EditorDocument) async throws -> UInt64 {
        requests.append(request)
        if let failure { throw failure }
        guard document.contentVersion == request.expectedVersion else {
            throw EditorDocumentServiceError.versionConflict(expected: request.expectedVersion, actual: document.contentVersion)
        }
        undoStack.append(document.text)
        document.text = EditorTextEditPlanner.apply(request.edits, to: document.text)
        return document.contentVersion
    }

    func undo(_ document: EditorDocument) { if let previous = undoStack.popLast() { document.text = previous } }
}

@MainActor
@Suite("Plugin document and editor service")
struct EditorDocumentServiceTests {
    private let windowID = UUID()
    private let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)

    private struct Fixture {
        let service: EditorDocumentService
        let document: EditorDocument
        let surface: FakeEditorSurface
        let scope: EditorDocumentScope
    }

    private func fixture(_ text: String, readOnly: Bool = false, attachSurface: Bool = true) -> Fixture {
        let document = EditorDocument(url: workspace.appendingPathComponent("src/Main.swift"), text: text,
                                      modificationDate: nil, isReadOnly: readOnly)
        let surface = FakeEditorSurface()
        if attachSurface { document.editorSurface = surface }
        let workspace = self.workspace
        let service = EditorDocumentService(
            windowID: windowID, workspaceURL: { workspace }, documents: { [document] },
            activeDocumentID: { document.id }, languageIdentifier: { _ in "swift" })
        return Fixture(service: service, document: document, surface: surface,
                       scope: EditorDocumentScope(windowID: windowID, workspaceURL: workspace))
    }

    @Test func snapshotReturnsUnsavedTextAndMetadata() throws {
        let f = fixture("let a = 1\r\n")
        f.document.text = "let a = 2\r\n"
        let snapshot = try f.service.snapshot(scope: f.scope, documentID: f.document.id)
        #expect(snapshot.text == "let a = 2\r\n")
        #expect(snapshot.summary.isDirty)
        #expect(snapshot.summary.version == f.document.contentVersion)
        #expect(snapshot.summary.lineEnding == .crlf)
        #expect(snapshot.summary.workspaceRelativePath == "src/Main.swift")
        #expect(snapshot.summary.languageID == "swift")
        #expect(try f.service.activeDocument(scope: f.scope)?.documentID == f.document.id)
        #expect(try f.service.listDocuments(scope: f.scope).map(\.documentID) == [f.document.id])
    }

    @Test func contentVersionChangesOnlyWithText() {
        let f = fixture("a")
        let initial = f.document.contentVersion
        f.document.text = "a"
        #expect(f.document.contentVersion == initial)
        f.document.text = "b"
        f.document.text = "a"
        #expect(f.document.contentVersion == initial + 2)
    }

    @Test func rejectsOtherWindowsWorkspacesAndUnknownDocuments() {
        let f = fixture("a")
        #expect(throws: EditorDocumentServiceError.contextMismatch) {
            try f.service.snapshot(scope: EditorDocumentScope(windowID: UUID(), workspaceURL: workspace), documentID: f.document.id)
        }
        #expect(throws: EditorDocumentServiceError.contextMismatch) {
            try f.service.listDocuments(scope: EditorDocumentScope(windowID: windowID, workspaceURL: nil))
        }
        #expect(throws: EditorDocumentServiceError.documentNotFound) {
            try f.service.snapshot(scope: f.scope, documentID: UUID())
        }
    }

    @Test func selectionsAreSortedAndKeepThePrimaryCaret() async throws {
        let f = fixture("one\ntwo\nthree")
        let primary = EditorSelection(anchor: at(3, 6), active: at(3, 1))
        f.surface.selections = [primary, EditorSelection(anchor: at(1, 1), active: at(1, 4)),
                                EditorSelection(anchor: at(2, 2), active: at(2, 2))]
        let snapshot = try await f.service.selections(scope: f.scope, documentID: f.document.id)
        #expect(snapshot.selections.map(\.range.start) == [at(1, 1), at(2, 2), at(3, 1)])
        #expect(snapshot.primaryIndex == 2)
        #expect(snapshot.selections[2].isReversed)
        #expect(snapshot.selections[1].isEmpty)
        #expect(snapshot.version == f.document.contentVersion)
    }

    /// Plan §7 selection transformer: read dirty selections, compute, then
    /// replace them in one undoable step guarded by the version.
    @Test func selectionTransformerRoundTripUndoesInOneStep() async throws {
        let f = fixture("foo 😀 bar\r\n中文 baz")
        f.document.text = "foo 😀 bar\r\n中文 qux"
        f.surface.selections = [EditorSelection(anchor: at(2, 1), active: at(2, 3)),
                                EditorSelection(anchor: at(1, 1), active: at(1, 4))]
        let selections = try await f.service.selections(scope: f.scope, documentID: f.document.id)
        let snapshot = try f.service.snapshot(scope: f.scope, documentID: f.document.id)
        let index = EditorTextLineIndex(snapshot.text)
        let replacements = selections.selections.map { selection -> String in
            let start = index.offset(of: selection.range.start)!, end = index.offset(of: selection.range.end)!
            return String(utf16CodeUnits: Array(index.units[start..<end]), count: end - start).uppercased() + "\n!"
        }
        let result = try await f.service.replaceSelections(scope: f.scope, selections: selections, replacements: replacements)
        #expect(result.applied)
        #expect(result.version == f.document.contentVersion)
        #expect(f.document.text == "FOO\r\n! 😀 bar\r\n中文\r\n! qux")
        #expect(f.surface.requests.count == 1)
        #expect(f.surface.requests.first?.lineSeparator == "\r\n")
        f.surface.undo(f.document)
        #expect(f.document.text == "foo 😀 bar\r\n中文 qux")
    }

    @Test func staleResultIsRejectedAfterUserInput() async throws {
        let f = fixture("abc")
        f.surface.selections = [EditorSelection(anchor: at(1, 1), active: at(1, 4))]
        let selections = try await f.service.selections(scope: f.scope, documentID: f.document.id)
        f.document.text = "abcd"
        await #expect(throws: EditorDocumentServiceError.versionConflict(expected: selections.version,
                                                                          actual: f.document.contentVersion)) {
            try await f.service.replaceSelections(scope: f.scope, selections: selections, replacements: ["X"])
        }
        #expect(f.document.text == "abcd")
        #expect(f.surface.requests.isEmpty)
    }

    @Test func readOnlyDocumentsRejectEdits() async {
        let f = fixture("abc", readOnly: true)
        await #expect(throws: EditorDocumentServiceError.readOnly) {
            try await f.service.insertText(scope: f.scope, documentID: f.document.id,
                                           expectedVersion: f.document.contentVersion, at: at(1, 1), text: "x")
        }
        #expect(f.surface.requests.isEmpty)
    }

    @Test func invalidBatchIsRejectedBeforeReachingTheEditor() async {
        let f = fixture("abcdef")
        let version = f.document.contentVersion
        await #expect(throws: EditorDocumentServiceError.overlappingRanges(editIndex: 0, otherEditIndex: 1)) {
            try await f.service.applyEdits(scope: f.scope, documentID: f.document.id, expectedVersion: version, edits: [
                EditorTextEdit(range: EditorTextRange(start: at(1, 1), end: at(1, 4)), text: "x"),
                EditorTextEdit(range: EditorTextRange(start: at(1, 3), end: at(1, 5)), text: "y"),
            ])
        }
        await #expect(throws: EditorDocumentServiceError.rangeOutOfBounds(editIndex: 1)) {
            try await f.service.applyEdits(scope: f.scope, documentID: f.document.id, expectedVersion: version, edits: [
                EditorTextEdit(range: EditorTextRange(start: at(1, 1), end: at(1, 2)), text: "x"),
                EditorTextEdit(range: EditorTextRange(start: at(2, 1), end: at(2, 1)), text: "y"),
            ])
        }
        #expect(f.surface.requests.isEmpty)
        #expect(f.document.text == "abcdef")
    }

    @Test func compositionRefusalLeavesTextUntouched() async {
        let f = fixture("abc")
        f.surface.failure = .compositionInProgress
        await #expect(throws: EditorDocumentServiceError.compositionInProgress) {
            try await f.service.insertText(scope: f.scope, documentID: f.document.id,
                                           expectedVersion: f.document.contentVersion, at: at(1, 4), text: "d")
        }
        #expect(f.document.text == "abc")
    }

    @Test func missingEditorAndReplacementCountsAreReported() async throws {
        let f = fixture("ab", attachSurface: false)
        await #expect(throws: EditorDocumentServiceError.editorUnavailable) {
            try await f.service.insertText(scope: f.scope, documentID: f.document.id,
                                           expectedVersion: f.document.contentVersion, at: at(1, 1), text: "x")
        }
        let selections = EditorSelectionsSnapshot(
            documentID: f.document.id, version: f.document.contentVersion,
            selections: [EditorSelection(anchor: at(1, 1), active: at(1, 1)), EditorSelection(anchor: at(1, 2), active: at(1, 2))],
            primaryIndex: 0)
        await #expect(throws: EditorDocumentServiceError.replacementCountMismatch(selections: 2, replacements: 3)) {
            try await f.service.replaceSelections(scope: f.scope, selections: selections, replacements: ["a", "b", "c"])
        }
        let empty = try await f.service.applyEdits(scope: f.scope, documentID: f.document.id,
                                                   expectedVersion: f.document.contentVersion, edits: [])
        #expect(!empty.applied)
    }
}
