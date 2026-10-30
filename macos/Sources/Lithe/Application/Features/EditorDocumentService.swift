import Foundation
import LitheCoreContracts

/// Host-internal document and editor access for plugin API-09 and API-10.
///
/// Every call names its window/workspace scope and document. The service never
/// substitutes the frontmost window, and it reads the live buffer (including
/// unsaved edits), never the disk. Authorization, public error codes and
/// capability negotiation belong to the plugin dispatch layer in front of it.
@MainActor
protocol EditorDocumentServicing: AnyObject {
    /// Open documents in tab order, then transient previews.
    func listDocuments(scope: EditorDocumentScope) throws -> [EditorDocumentSummary]
    func snapshot(scope: EditorDocumentScope, documentID: UUID) throws -> EditorDocumentSnapshot
    /// The window's active text document, or `nil` when none is selected.
    func activeDocument(scope: EditorDocumentScope) throws -> EditorDocumentSummary?
    func selections(scope: EditorDocumentScope, documentID: UUID) async throws -> EditorSelectionsSnapshot
    /// Validates the whole batch against `expectedVersion`, then applies it as one undo step.
    func applyEdits(scope: EditorDocumentScope, documentID: UUID, expectedVersion: UInt64,
                    edits: [EditorTextEdit]) async throws -> EditorDocumentEditResult
    /// Replaces previously read selections; `replacements` has one entry per
    /// selection, or a single entry used for every selection.
    func replaceSelections(scope: EditorDocumentScope, selections: EditorSelectionsSnapshot,
                           replacements: [String]) async throws -> EditorDocumentEditResult
    func insertText(scope: EditorDocumentScope, documentID: UUID, expectedVersion: UInt64,
                    at position: EditorTextPosition, text: String) async throws -> EditorDocumentEditResult
}

/// Selections reported by an editor surface, in one-based Monaco coordinates.
struct EditorSurfaceSelections: Sendable {
    /// Unsorted, as the editor reports them; the first is the primary caret.
    let selections: [EditorSelection]
    /// Content version these selections belong to.
    let version: UInt64
}

/// Edit batch handed to the surface after full validation.
struct EditorSurfaceEditRequest: Sendable {
    let expectedVersion: UInt64
    /// Sorted, non-overlapping; ranges are one-based and `normalizedText` uses LF.
    let edits: [PlannedEditorTextEdit]
    /// Separator the document mirror must use for inserted line breaks.
    let lineSeparator: String
}

/// Port implemented by the editor adapter that owns a document's live buffer
/// (the Monaco session that drains its edits before save/close).
@MainActor
protocol EditorDocumentSurface: AnyObject {
    func readSelections(of document: EditorDocument) async throws -> EditorSurfaceSelections
    /// Applies the batch as one undo step only if the editor has no unacknowledged
    /// input since `expectedVersion` and no active composition. Returns the
    /// content version produced by exactly this batch.
    func apply(_ request: EditorSurfaceEditRequest, to document: EditorDocument) async throws -> UInt64
}

@MainActor
final class EditorDocumentService: EditorDocumentServicing {
    private let windowID: UUID
    private let workspaceURL: @MainActor () -> URL?
    private let documents: @MainActor () -> [EditorDocument]
    private let activeDocumentID: @MainActor () -> UUID?
    private let languageIdentifier: @MainActor (URL) -> String?

    init(
        windowID: UUID,
        workspaceURL: @escaping @MainActor () -> URL?,
        documents: @escaping @MainActor () -> [EditorDocument],
        activeDocumentID: @escaping @MainActor () -> UUID?,
        languageIdentifier: @escaping @MainActor (URL) -> String?
    ) {
        self.windowID = windowID
        self.workspaceURL = workspaceURL
        self.documents = documents
        self.activeDocumentID = activeDocumentID
        self.languageIdentifier = languageIdentifier
    }

    func listDocuments(scope: EditorDocumentScope) throws -> [EditorDocumentSummary] {
        try validate(scope)
        return documents().map { summary(of: $0, index: EditorTextLineIndex($0.text)) }
    }

    func snapshot(scope: EditorDocumentScope, documentID: UUID) throws -> EditorDocumentSnapshot {
        let document = try resolve(scope, documentID)
        // Text and version are read together on the main actor, so they always
        // describe the same buffer state. Keystrokes still crossing the editor
        // bridge appear in a later version and make edits based on this one fail.
        return EditorDocumentSnapshot(summary: summary(of: document, index: EditorTextLineIndex(document.text)),
                                      text: document.text)
    }

    func activeDocument(scope: EditorDocumentScope) throws -> EditorDocumentSummary? {
        try validate(scope)
        guard let id = activeDocumentID(), let document = documents().first(where: { $0.id == id }) else { return nil }
        return summary(of: document, index: EditorTextLineIndex(document.text))
    }

    func selections(scope: EditorDocumentScope, documentID: UUID) async throws -> EditorSelectionsSnapshot {
        let document = try resolve(scope, documentID)
        guard let surface = document.editorSurface else { throw EditorDocumentServiceError.editorUnavailable }
        let reported = try await surface.readSelections(of: document)
        let current = try resolve(scope, documentID)
        guard current === document else { throw EditorDocumentServiceError.documentNotFound }
        guard reported.version == document.contentVersion else {
            throw EditorDocumentServiceError.versionConflict(expected: reported.version, actual: document.contentVersion)
        }
        let index = EditorTextLineIndex(document.text)
        guard reported.selections.allSatisfy({ index.offset(of: $0.anchor) != nil && index.offset(of: $0.active) != nil }) else {
            throw EditorDocumentServiceError.editorUnavailable
        }
        let primary = reported.selections.first
        let sorted = reported.selections.sorted {
            ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end)
        }
        return EditorSelectionsSnapshot(documentID: documentID, version: reported.version, selections: sorted,
                                        primaryIndex: primary.flatMap { sorted.firstIndex(of: $0) })
    }

    func applyEdits(scope: EditorDocumentScope, documentID: UUID, expectedVersion: UInt64,
                    edits: [EditorTextEdit]) async throws -> EditorDocumentEditResult {
        try Task.checkCancellation()
        let document = try resolve(scope, documentID)
        guard !document.isReadOnly else { throw EditorDocumentServiceError.readOnly }
        guard document.contentVersion == expectedVersion else {
            throw EditorDocumentServiceError.versionConflict(expected: expectedVersion, actual: document.contentVersion)
        }
        let index = EditorTextLineIndex(document.text)
        let plan = try EditorTextEditPlanner.plan(edits, in: index)
        guard !plan.isEmpty else {
            return EditorDocumentEditResult(documentID: documentID, version: expectedVersion, applied: false)
        }
        guard let surface = document.editorSurface else { throw EditorDocumentServiceError.editorUnavailable }
        // No suspension between the checks above and this call: the surface
        // compares the editor's own revision against the same instant.
        let version = try await surface.apply(
            EditorSurfaceEditRequest(expectedVersion: expectedVersion, edits: plan,
                                     lineSeparator: index.insertionSeparator),
            to: document)
        return EditorDocumentEditResult(documentID: documentID, version: version, applied: true)
    }

    func replaceSelections(scope: EditorDocumentScope, selections: EditorSelectionsSnapshot,
                           replacements: [String]) async throws -> EditorDocumentEditResult {
        let count = selections.selections.count
        guard replacements.count == count || (replacements.count == 1 && count > 0) else {
            throw EditorDocumentServiceError.replacementCountMismatch(selections: count, replacements: replacements.count)
        }
        let edits = selections.selections.enumerated().map { offset, selection in
            EditorTextEdit(range: selection.range, text: replacements.count == 1 ? replacements[0] : replacements[offset])
        }
        return try await applyEdits(scope: scope, documentID: selections.documentID,
                                    expectedVersion: selections.version, edits: edits)
    }

    func insertText(scope: EditorDocumentScope, documentID: UUID, expectedVersion: UInt64,
                    at position: EditorTextPosition, text: String) async throws -> EditorDocumentEditResult {
        try await applyEdits(scope: scope, documentID: documentID, expectedVersion: expectedVersion,
                             edits: [EditorTextEdit(range: EditorTextRange(start: position, end: position), text: text)])
    }

    private func validate(_ scope: EditorDocumentScope) throws {
        guard scope.windowID == windowID,
              scope.workspaceURL?.standardizedFileURL == workspaceURL()?.standardizedFileURL else {
            throw EditorDocumentServiceError.contextMismatch
        }
    }

    private func resolve(_ scope: EditorDocumentScope, _ documentID: UUID) throws -> EditorDocument {
        try validate(scope)
        guard let document = documents().first(where: { $0.id == documentID }) else {
            throw EditorDocumentServiceError.documentNotFound
        }
        return document
    }

    private func summary(of document: EditorDocument, index: EditorTextLineIndex) -> EditorDocumentSummary {
        EditorDocumentSummary(
            documentID: document.id, version: document.contentVersion,
            workspaceRelativePath: relativePath(of: document.url), languageID: languageIdentifier(document.url),
            isReadOnly: document.isReadOnly, isDirty: document.isDirty, encoding: document.readEncoding,
            lineEnding: index.lineEnding)
    }

    private func relativePath(of url: URL) -> String? {
        guard let root = workspaceURL()?.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
