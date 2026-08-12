import Combine
import Foundation

/// Owns editor document lifecycle and persistence-facing state. Java services,
/// local history, and UI notifications are supplied as callbacks by AppModel.
@MainActor
final class DocumentFeatureModel: ObservableObject {
    @Published private(set) var openDocuments: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    @Published private(set) var pendingCloseDocument: EditorDocument?
    @Published private(set) var isPendingProjectClose = false

    private let operations: any WorkspaceOperations
    private let fileOperations: any WorkspaceFileOperations
    private let fileStorage: any FileStorage
    private let binaryFileViewerRegistry: BinaryFileViewerRegistry
    private var workspaceURLProvider: (@MainActor () -> URL?)?
    private var autoSaveEnabledProvider: (@MainActor () -> Bool)?
    private var autoSaveDelayProvider: (@MainActor () -> TimeInterval)?
    private var notify: (@MainActor (String) -> Void)?
    private var onDocumentOpened: (@MainActor (EditorDocument) -> Void)?
    private var onDocumentChanged: (@MainActor (EditorDocument) -> Void)?
    private var onDocumentClosed: (@MainActor (EditorDocument) -> Void)?
    private var onRecordSave: (@MainActor (EditorDocument, String) -> Void)?
    private var onRecordDiscard: (@MainActor (EditorDocument) -> Void)?
    private var onRecordExternalChanges: (@MainActor ([URL]) -> Void)?
    private var onDocumentCollectionChanged: (@MainActor () -> Void)?
    private var onProjectCloseReady: (@MainActor () -> Void)?
    private var autoSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileOpenRequests: [String: UUID] = [:]
    private var latestFileOpenRequestID: UUID?
    private var pendingCloseQueue: [EditorDocument] = []
    private var pendingClosePreferredDocumentID: UUID?

    init(
        operations: any WorkspaceOperations,
        fileOperations: any WorkspaceFileOperations,
        fileStorage: any FileStorage,
        binaryFileViewerRegistry: BinaryFileViewerRegistry
    ) {
        self.operations = operations
        self.fileOperations = fileOperations
        self.fileStorage = fileStorage
        self.binaryFileViewerRegistry = binaryFileViewerRegistry
    }

    func configure(
        workspaceURLProvider: @escaping @MainActor () -> URL?,
        autoSaveEnabledProvider: @escaping @MainActor () -> Bool,
        autoSaveDelayProvider: @escaping @MainActor () -> TimeInterval,
        notify: @escaping @MainActor (String) -> Void,
        onDocumentOpened: @escaping @MainActor (EditorDocument) -> Void,
        onDocumentChanged: @escaping @MainActor (EditorDocument) -> Void,
        onDocumentClosed: @escaping @MainActor (EditorDocument) -> Void,
        onRecordSave: @escaping @MainActor (EditorDocument, String) -> Void,
        onRecordDiscard: @escaping @MainActor (EditorDocument) -> Void,
        onRecordExternalChanges: @escaping @MainActor ([URL]) -> Void,
        onDocumentCollectionChanged: @escaping @MainActor () -> Void,
        onProjectCloseReady: @escaping @MainActor () -> Void
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.autoSaveEnabledProvider = autoSaveEnabledProvider
        self.autoSaveDelayProvider = autoSaveDelayProvider
        self.notify = notify
        self.onDocumentOpened = onDocumentOpened
        self.onDocumentChanged = onDocumentChanged
        self.onDocumentClosed = onDocumentClosed
        self.onRecordSave = onRecordSave
        self.onRecordDiscard = onRecordDiscard
        self.onRecordExternalChanges = onRecordExternalChanges
        self.onDocumentCollectionChanged = onDocumentCollectionChanged
        self.onProjectCloseReady = onProjectCloseReady
    }

    var activeDocument: EditorDocument? {
        guard let activeDocumentID else { return nil }
        return openDocuments.first { $0.id == activeDocumentID }
    }

    var hasUnsavedDocuments: Bool {
        openDocuments.contains(where: \.isDirty)
    }

    func reset() {
        autoSaveTasks.values.forEach { $0.cancel() }
        autoSaveTasks.removeAll()
        pendingFileOpenRequests.removeAll()
        latestFileOpenRequestID = nil
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        isPendingProjectClose = false
        openDocuments = []
        activeDocumentID = nil
    }

    func openFile(
        _ url: URL,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        let normalizedURL = url.standardizedFileURL

        // Switching to an already-open document does not require file I/O.
        // Apply that state change synchronously so repeated tree clicks feel immediate.
        if let existing = openDocuments.first(where: { $0.url == normalizedURL }) {
            latestFileOpenRequestID = UUID()
            activeDocumentID = existing.id
            if !isReadOnly {
                onDocumentOpened?(existing)
            }
            return
        }

        Task { await openFileAsync(
            normalizedURL,
            isReadOnly: isReadOnly,
            displayPath: displayPath,
            activateWhenReady: true
        ) }
    }

    func openFileAsync(
        _ normalizedURL: URL,
        isReadOnly: Bool,
        displayPath: String?,
        activateWhenReady: Bool
    ) async {
        if let existing = openDocuments.first(where: { $0.url == normalizedURL }) {
            if activateWhenReady {
                let requestID = UUID()
                latestFileOpenRequestID = requestID
                activeDocumentID = existing.id
            }
            if !isReadOnly {
                onDocumentOpened?(existing)
            }
            return
        }

        let requestID = UUID()
        guard pendingFileOpenRequests[normalizedURL.path] == nil else { return }
        pendingFileOpenRequests[normalizedURL.path] = requestID
        if activateWhenReady {
            latestFileOpenRequestID = requestID
        }
        defer {
            if pendingFileOpenRequests[normalizedURL.path] == requestID {
                pendingFileOpenRequests[normalizedURL.path] = nil
            }
        }

        guard let workspaceURLProvider,
              let openingWorkspaceURL = workspaceURLProvider(),
              let relativePath = workspaceRelativePath(for: normalizedURL, root: openingWorkspaceURL) else {
            notify?("This file is outside the current workspace")
            return
        }

        let operations = self.operations
        let text = await Task.detached(priority: .userInitiated) {
            operations.readFile(at: openingWorkspaceURL, relativePath: relativePath)
        }.value
        guard let text else {
            // `file.read` accepts plain text regardless of suffix and rejects
            // binary content. Only after that path fails do we probe a small
            // header for an explicitly registered binary viewer. With the
            // default empty registry this falls through to the rejection below.
            let fileStorage = self.fileStorage
            let header = await Task.detached(priority: .userInitiated) {
                try? fileStorage.readPrefix(
                    from: normalizedURL,
                    byteCount: BinaryFileViewerRegistry.headerByteCount
                )
            }.value
            if let header,
               await binaryFileViewerRegistry.openIfSupported(
                   url: normalizedURL,
                   header: header
               ) {
                return
            }
            notify?("This file cannot be displayed as text")
            return
        }
        guard workspaceURLProvider() == openingWorkspaceURL else { return }

        let document = EditorDocument(
            url: normalizedURL,
            text: text,
            modificationDate: EditorDocument.modificationDate(for: normalizedURL),
            isReadOnly: isReadOnly,
            displayPath: displayPath
        )
        guard !openDocuments.contains(where: { $0.url == normalizedURL }) else { return }
        openDocuments.append(document)
        if activateWhenReady, latestFileOpenRequestID == requestID {
            activeDocumentID = document.id
        }
        onDocumentCollectionChanged?()
        onDocumentOpened?(document)
    }

    func openVirtualDocument(
        _ url: URL,
        text: String,
        displayPath: String?
    ) {
        guard !url.isFileURL else { return }
        if let existing = openDocuments.first(where: { $0.url == url }) {
            activeDocumentID = existing.id
            return
        }
        let document = EditorDocument(
            url: url,
            text: text,
            modificationDate: nil,
            isReadOnly: true,
            displayPath: displayPath
        )
        openDocuments.append(document)
        activeDocumentID = document.id
        onDocumentCollectionChanged?()
        onDocumentOpened?(document)
    }

    func moveDocument(_ documentID: UUID, before targetDocumentID: UUID) {
        guard documentID != targetDocumentID,
              let sourceIndex = openDocuments.firstIndex(where: { $0.id == documentID }),
              openDocuments.contains(where: { $0.id == targetDocumentID }) else { return }
        var next = openDocuments
        let document = next.remove(at: sourceIndex)
        guard let targetIndex = next.firstIndex(where: { $0.id == targetDocumentID }) else { return }
        next.insert(document, at: targetIndex)
        guard next.map(\.id) != openDocuments.map(\.id) else { return }
        openDocuments = next
        onDocumentCollectionChanged?()
    }

    func moveDocument(_ documentID: UUID, after targetDocumentID: UUID) {
        guard documentID != targetDocumentID,
              let sourceIndex = openDocuments.firstIndex(where: { $0.id == documentID }),
              openDocuments.contains(where: { $0.id == targetDocumentID }) else { return }
        var next = openDocuments
        let document = next.remove(at: sourceIndex)
        guard let targetIndex = next.firstIndex(where: { $0.id == targetDocumentID }) else { return }
        next.insert(document, at: targetIndex + 1)
        guard next.map(\.id) != openDocuments.map(\.id) else { return }
        openDocuments = next
        onDocumentCollectionChanged?()
    }

    func reorderDocuments(orderedPaths: [String]) {
        let order = Dictionary(uniqueKeysWithValues: orderedPaths.enumerated().map { ($1, $0) })
        let next = openDocuments.sorted { left, right in
            let leftIndex = order[left.url.standardizedFileURL.path] ?? Int.max
            let rightIndex = order[right.url.standardizedFileURL.path] ?? Int.max
            return leftIndex < rightIndex
        }
        guard next.map(\.id) != openDocuments.map(\.id) else { return }
        openDocuments = next
        onDocumentCollectionChanged?()
    }

    func requestCloseDocument(_ document: EditorDocument) {
        isPendingProjectClose = false
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        if document.isDirty {
            pendingCloseDocument = document
        } else {
            closeDocument(document)
        }
    }

    func requestCloseDocuments(
        _ documents: [EditorDocument],
        preferredDocumentID: UUID? = nil
    ) {
        let openIDs = Set(openDocuments.map(\.id))
        let targets = documents.filter { openIDs.contains($0.id) }
        guard !targets.isEmpty else { return }

        isPendingProjectClose = false
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = preferredDocumentID
        let dirtyDocuments = targets.filter(\.isDirty)
        targets.filter { !$0.isDirty }.forEach(closeDocument)

        if let firstDirty = dirtyDocuments.first {
            pendingCloseQueue = Array(dirtyDocuments.dropFirst())
            pendingCloseDocument = firstDirty
        } else {
            activatePreferredDocumentIfPossible()
        }
    }

    /// Returns true when the caller must wait for the save/discard dialog.
    @discardableResult
    func beginProjectClose() -> Bool {
        guard !openDocuments.filter(\.isDirty).isEmpty else { return false }
        isPendingProjectClose = true
        pendingCloseQueue = Array(openDocuments.filter(\.isDirty).dropFirst())
        pendingClosePreferredDocumentID = nil
        pendingCloseDocument = openDocuments.first(where: \.isDirty)
        return true
    }

    func closePendingDocument(discardingChanges: Bool) {
        guard let document = pendingCloseDocument else { return }
        if discardingChanges {
            onRecordDiscard?(document)
        } else {
            do {
                let previousText = document.savedText
                try saveDocument(document)
                onRecordSave?(document, previousText)
            } catch {
                notify?("Could not save \(document.url.lastPathComponent)")
                return
            }
        }

        pendingCloseDocument = nil
        closeDocument(document)
        if let nextDocument = pendingCloseQueue.first {
            pendingCloseQueue.removeFirst()
            pendingCloseDocument = nextDocument
        } else if isPendingProjectClose {
            isPendingProjectClose = false
            pendingClosePreferredDocumentID = nil
            onProjectCloseReady?()
        } else {
            activatePreferredDocumentIfPossible()
        }
    }

    func cancelPendingClose() {
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        isPendingProjectClose = false
    }

    @discardableResult
    func saveAllDocuments() -> Bool {
        for document in openDocuments where document.isDirty {
            do {
                let previousText = document.savedText
                try saveDocument(document)
                onRecordSave?(document, previousText)
            } catch {
                return false
            }
        }
        return true
    }

    func saveActiveDocument() {
        guard let document = activeDocument else { return }
        guard !document.isReadOnly else {
            notify?("This document is read-only")
            return
        }
        do {
            let previousText = document.savedText
            try saveDocument(document)
            onRecordSave?(document, previousText)
            notify?("Saved \(document.url.lastPathComponent)")
        } catch {
            notify?("Could not save \(document.url.lastPathComponent)")
        }
    }

    func save(_ document: EditorDocument) throws {
        try saveDocument(document)
    }

    func documentDidChange(_ document: EditorDocument) {
        onDocumentChanged?(document)
        autoSaveTasks[document.id]?.cancel()
        guard autoSaveEnabledProvider?() == true else { return }
        let delay = autoSaveDelayProvider?() ?? 0
        autoSaveTasks[document.id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let document, document.isDirty else { return }
            do {
                let previousText = document.savedText
                try self.saveDocument(document)
                self.onRecordSave?(document, previousText)
            } catch {
                self.notify?("Could not auto-save \(document.url.lastPathComponent)")
            }
            self.autoSaveTasks[document.id] = nil
        }
    }

    func loadExternalVersion(of document: EditorDocument) {
        do {
            if document.isDirty {
                onRecordDiscard?(document)
            }
            try document.reloadFromDisk()
            onDocumentChanged?(document)
            notify?("Loaded file-system version")
        } catch {
            notify?("Could not reload \(document.url.lastPathComponent)")
        }
    }

    func keepEditorVersion(of document: EditorDocument) {
        document.keepEditorVersion()
        notify?("Kept editor version")
    }

    @discardableResult
    func processExternalChanges(_ urls: [URL]) -> Bool {
        let changedPathSet = Set(urls.map { $0.standardizedFileURL.path })
        var conflictDetected = false
        for document in openDocuments where changedPathSet.contains(document.url.standardizedFileURL.path) {
            if document.processPossibleExternalChange() {
                onDocumentChanged?(document)
                if document.hasExternalConflict {
                    conflictDetected = true
                }
            }
        }
        onRecordExternalChanges?(urls)
        return conflictDetected
    }

    func closeDocuments(containedIn url: URL) {
        let documents = openDocuments.filter { urlContains(url, child: $0.url) }
        for document in documents {
            closeDocument(document)
        }
    }

    func relocateOpenDocuments(from sourceURL: URL, to destinationURL: URL) {
        let sourcePath = sourceURL.standardizedFileURL.path
        for document in openDocuments where urlContains(sourceURL, child: document.url) {
            let documentPath = document.url.standardizedFileURL.path
            let suffix = String(documentPath.dropFirst(sourcePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relocatedURL = suffix.isEmpty
                ? destinationURL
                : destinationURL.appendingPathComponent(suffix)
            document.relocate(to: relocatedURL)
        }
        onDocumentCollectionChanged?()
    }

    private func closeDocument(_ document: EditorDocument) {
        guard let index = openDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        autoSaveTasks[document.id]?.cancel()
        autoSaveTasks[document.id] = nil
        onDocumentClosed?(document)
        let wasActive = activeDocumentID == document.id
        openDocuments.remove(at: index)
        if wasActive {
            if openDocuments.indices.contains(index) {
                activeDocumentID = openDocuments[index].id
            } else {
                activeDocumentID = openDocuments.last?.id
            }
        }
        onDocumentCollectionChanged?()
    }

    private func activatePreferredDocumentIfPossible() {
        defer { pendingClosePreferredDocumentID = nil }
        guard let preferredDocumentID = pendingClosePreferredDocumentID,
              openDocuments.contains(where: { $0.id == preferredDocumentID }) else { return }
        activeDocumentID = preferredDocumentID
    }

    private func saveDocument(_ document: EditorDocument) throws {
        guard !document.isReadOnly else { throw EditorDocument.DocumentError.readOnly }
        if let workspaceURLProvider,
           let workspaceURL = workspaceURLProvider(),
           let relativePath = workspaceRelativePath(for: document.url, root: workspaceURL),
           operations.writeFile(document.text, at: workspaceURL, relativePath: relativePath) {
            document.markSavedWithoutWriting()
            return
        }
        try fileOperations.writeText(document.text, to: document.url)
        document.markSavedWithoutWriting()
    }

    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let normalizedRoot = root.standardizedFileURL.path
        let normalizedPath = url.standardizedFileURL.path
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return nil }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }

    private func urlContains(_ parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}
