import Combine
import Foundation
import LitheCoreContracts

@MainActor
final class EditorDocument: ObservableObject, Identifiable, @unchecked Sendable {
    enum DocumentError: LocalizedError {
        case readOnly
        case editorNotSynchronized

        var errorDescription: String? {
            switch self {
            case .readOnly:
                "This document is read-only"
            case .editorNotSynchronized:
                "Wait for the editor to synchronize before saving"
            }
        }
    }

    let id = UUID()
    private(set) var url: URL
    /// Invalidates asynchronous requests even after a rename away and back.
    private(set) var locationRevision: UInt64 = 0
    private let isProductReadOnly: Bool
    @Published private(set) var isReadOnly: Bool
    let displayPath: String?
    /// Preview subscribers receive live edits without invalidating the editor hierarchy.
    let textDidChange = PassthroughSubject<Void, Never>()
    /// A remote editor establishes a revision barrier and drains its edit queue
    /// around a native action. Input arriving after that snapshot remains a newer
    /// dirty revision. The adapter must complete or fail locally.
    var synchronizeEditor: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    typealias EditorRelease = @MainActor () -> Void
    /// Keeps remote input read-only across an asynchronous close/confirmation flow.
    var holdEditorForClose: ((@escaping (Result<EditorRelease, Error>) -> Void) -> Void)?
    private var pendingSynchronizedActions: [(Result<Void, Error>) -> Void]?
    private var synchronizationID: UUID?
    private var isPerformingSynchronizedEditorAction = false
    var needsEditorSynchronization: Bool { synchronizeEditor != nil && !isPerformingSynchronizedEditorAction }

    func withSynchronizedEditor(_ action: @escaping (Result<Void, Error>) -> Void) {
        guard let synchronizeEditor, !isPerformingSynchronizedEditorAction else {
            action(.success(()))
            return
        }
        if pendingSynchronizedActions != nil {
            pendingSynchronizedActions?.append(action)
            return
        }
        pendingSynchronizedActions = [action]
        let operationID = UUID()
        synchronizationID = operationID
        synchronizeEditor { [weak self] result in
            guard let self else { action(.failure(DocumentError.editorNotSynchronized)); return }
            // A delayed duplicate acknowledgment must not release a newer drain.
            guard self.synchronizationID == operationID,
                  let actions = self.pendingSynchronizedActions else { return }
            self.synchronizationID = nil
            self.pendingSynchronizedActions = nil
            if case .failure = result { actions.forEach { $0(result) }; return }
            let previous = self.isPerformingSynchronizedEditorAction
            self.isPerformingSynchronizedEditorAction = true
            defer { self.isPerformingSynchronizedEditorAction = previous }
            actions.forEach { $0(result) }
        }
    }
    private var storedText: String
    var text: String {
        get { storedText }
        set { replaceText(newValue, publish: true) }
    }
    @Published private(set) var savedText: String
    private(set) var lifecycleState: DocumentLifecycleState
    private(set) var lastKnownModificationDate: Date?
    private(set) var acknowledgedDiskContent: String?
    private(set) var hasAcknowledgedDiskContent = false
    private(set) var externalDiskContent: String?
    private(set) var hasObservedDiskConflict = false
    var expectedDiskContent: String? { hasAcknowledgedDiskContent ? acknowledgedDiskContent : savedText }
    var externalFileMissing: Bool { hasObservedDiskConflict && externalDiskContent == nil }

    func observeDiskConflict(_ content: String?) {
        objectWillChange.send()
        externalDiskContent = content
        hasObservedDiskConflict = true
    }

    func acknowledgeObservedDiskContent() {
        guard hasObservedDiskConflict else { return }
        acknowledgedDiskContent = externalDiskContent
        hasAcknowledgedDiskContent = true
        hasObservedDiskConflict = false
    }

    private var pendingLanguageServerChanges: [LanguageServerDocumentChange] = []

    init(
        url: URL,
        text: String,
        modificationDate: Date?,
        isReadOnly: Bool = false,
        isFileWritable: Bool = true,
        displayPath: String? = nil
    ) {
        self.url = url
        self.isProductReadOnly = isReadOnly
        self.isReadOnly = isReadOnly || !isFileWritable
        self.displayPath = displayPath
        self.storedText = text
        self.savedText = text
        self.lifecycleState = .clean(revision: 0)
        self.lastKnownModificationDate = modificationDate
    }

    func updateFileSystemWritable(_ isWritable: Bool) {
        let next = isProductReadOnly || !isWritable
        guard isReadOnly != next else { return }
        isReadOnly = next
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
        var line = 0
        var lineStart = 0
        var index = 0
        // LSP counts CR, LF and CRLF as line separators, matching Monaco.
        while index < safeOffset {
            let unit = source.character(at: index)
            index += 1
            if unit == 13 {
                if index < safeOffset, source.character(at: index) == 10 { index += 1 }
                line += 1
                lineStart = index
            } else if unit == 10 {
                line += 1
                lineStart = index
            }
        }
        return LanguageServerDocumentPosition(line: line, utf16Column: safeOffset - lineStart)
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
        textDidChange.send()
    }

    func save() throws {
        guard !needsEditorSynchronization else { throw DocumentError.editorNotSynchronized }
        guard !isReadOnly else { throw DocumentError.readOnly }
        try text.write(to: url, atomically: true, encoding: .utf8)
        markSavedWithoutWriting()
    }

    func reloadFromDisk() throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        replaceWithDiskContent(contents)
    }

    func replaceWithDiskContent(_ contents: String) {
        storedText = contents
        textDidChange.send()
        savedText = contents
        hasAcknowledgedDiskContent = false
        hasObservedDiskConflict = false
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

    func markSavedWithoutWriting(state: DocumentLifecycleState? = nil, savedContent: String? = nil) {
        savedText = savedContent ?? text
        hasAcknowledgedDiskContent = false
        hasObservedDiskConflict = false
        lifecycleState = state ?? .clean(revision: lifecycleState.revision)
        lastKnownModificationDate = Self.modificationDate(for: url)
    }

    func relocate(to newURL: URL) {
        objectWillChange.send()
        if url != newURL.standardizedFileURL { locationRevision += 1 }
        url = newURL.standardizedFileURL
        lastKnownModificationDate = Self.modificationDate(for: newURL)
    }

    static func modificationDate(for url: URL) -> Date? {
        // URL resource values are cached; freshness checks must read the current disk metadata.
        var freshURL = url
        freshURL.removeCachedResourceValue(forKey: .contentModificationDateKey)
        return try? freshURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
