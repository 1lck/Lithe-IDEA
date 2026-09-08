import Foundation
import LitheCoreContracts

@MainActor
final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    enum DocumentError: LocalizedError {
        case readOnly

        var errorDescription: String? {
            switch self {
            case .readOnly:
                "This document is read-only"
            }
        }
    }

    let id = UUID()
    private(set) var url: URL
    let isReadOnly: Bool
    let displayPath: String?
    private var storedText: String
    var text: String {
        get { storedText }
        set { replaceText(newValue, publish: true) }
    }
    @Published private(set) var savedText: String
    private(set) var lifecycleState: DocumentLifecycleState
    private(set) var lastKnownModificationDate: Date?
    private var pendingLanguageServerChanges: [LanguageServerDocumentChange] = []

    init(
        url: URL,
        text: String,
        modificationDate: Date?,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        self.url = url
        self.isReadOnly = isReadOnly
        self.displayPath = displayPath
        self.storedText = text
        self.savedText = text
        self.lifecycleState = .clean(revision: 0)
        self.lastKnownModificationDate = modificationDate
    }

    var displayName: String {
        displayPath?.split(separator: "/").last.map(String.init) ?? url.lastPathComponent
    }

    var isDirty: Bool { lifecycleState.hasUnpersistedText }
    var hasExternalConflict: Bool { lifecycleState.status == .conflict }

    /// Keep the live NSTextView buffer in sync without waking SwiftUI on every
    /// already-dirty keystroke. The first edit still publishes so the tab dirty
    /// mark can appear.
    func applyLiveEditorText(_ newText: String) {
        let remainsUnpersisted = lifecycleState.status == .saving
            || lifecycleState.status == .conflict
            || newText != savedText
        replaceText(newText, publish: isDirty != remainsUnpersisted)
    }

    /// Applies the editor's latest change without asking the NSTextView for a
    /// full document snapshot. The editor and document model stay in lockstep
    /// through the same UTF-16 range used by NSTextView.
    func applyLiveEditorEdit(replacedRange: NSRange, replacement: String) {
        let source = storedText as NSString
        guard replacedRange.location != NSNotFound,
              replacedRange.location >= 0,
              replacedRange.length >= 0,
              replacedRange.location <= source.length,
              replacedRange.length <= source.length - replacedRange.location else {
            return
        }
        let start = Self.position(at: replacedRange.location, in: source)
        let end = Self.position(at: NSMaxRange(replacedRange), in: source)
        pendingLanguageServerChanges.append(
            LanguageServerDocumentChange(
                start: start,
                end: end,
                text: replacement
            )
        )
        let nextText = source.replacingCharacters(in: replacedRange, with: replacement)
        applyLiveEditorText(nextText)
    }

    func takePendingLanguageServerChanges() -> [LanguageServerDocumentChange] {
        defer { pendingLanguageServerChanges.removeAll(keepingCapacity: true) }
        return pendingLanguageServerChanges
    }

    private static func position(
        at offset: Int,
        in source: NSString
    ) -> LanguageServerDocumentPosition {
        let safeOffset = min(max(offset, 0), source.length)
        let lineRange = source.lineRange(
            for: NSRange(location: safeOffset, length: 0)
        )
        return LanguageServerDocumentPosition(
            line: source.substring(with: NSRange(location: 0, length: lineRange.location))
                .split(separator: "\n", omittingEmptySubsequences: false).count - 1,
            utf16Column: safeOffset - lineRange.location
        )
    }

    private func replaceText(_ newText: String, publish: Bool) {
        guard storedText != newText else { return }
        let nextRevision = lifecycleState.revision + 1
        let nextLifecycle: DocumentLifecycleState
        switch lifecycleState.status {
        case .saving, .conflict:
            nextLifecycle = DocumentLifecycleState(
                status: lifecycleState.status,
                revision: nextRevision,
                savedRevision: lifecycleState.savedRevision,
                saveRevision: lifecycleState.saveRevision,
                operationId: lifecycleState.operationId
            )
        case .clean, .dirty:
            if newText == savedText {
                nextLifecycle = .clean(revision: nextRevision)
            } else {
                nextLifecycle = .dirty(
                    revision: nextRevision,
                    savedRevision: lifecycleState.savedRevision ?? lifecycleState.revision
                )
            }
        }
        if publish {
            objectWillChange.send()
        }
        storedText = newText
        lifecycleState = nextLifecycle
    }

    func save() throws {
        guard !isReadOnly else { throw DocumentError.readOnly }
        try text.write(to: url, atomically: true, encoding: .utf8)
        markSavedWithoutWriting()
    }

    func reloadFromDisk() throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        storedText = contents
        savedText = contents
        lifecycleState = .clean(revision: lifecycleState.revision + 1)
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func keepEditorVersion() {
        acknowledgeExternalModification()
        lifecycleState = .dirty(
            revision: lifecycleState.revision,
            savedRevision: lifecycleState.savedRevision ?? 0
        )
        objectWillChange.send()
    }

    func acknowledgeExternalModification() {
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func hasPossibleExternalChange() -> Bool {
        let currentDate = Self.modificationDate(for: url)
        return currentDate != lastKnownModificationDate
    }

    func applyLifecycleState(_ state: DocumentLifecycleState) {
        let statusChanged = lifecycleState.status != state.status
        if statusChanged {
            objectWillChange.send()
        }
        lifecycleState = state
    }

    func markSavedWithoutWriting(state: DocumentLifecycleState? = nil) {
        savedText = text
        lifecycleState = state ?? .clean(revision: lifecycleState.revision)
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func relocate(to newURL: URL) {
        objectWillChange.send()
        url = newURL.standardizedFileURL
        lastKnownModificationDate = Self.modificationDate(for: newURL)
    }

    static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
