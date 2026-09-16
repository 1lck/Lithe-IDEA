import Combine
import Foundation

enum StandaloneFileOpenFailure: Error, Equatable {
    case unavailable
    case directory
    case tooLarge
    case notText
    case readFailed

    var title: String {
        switch self {
        case .unavailable: "File is not available"
        case .directory: "Folders cannot be opened as text"
        case .tooLarge: "File is too large to open"
        case .notText: "This file cannot be displayed as text"
        case .readFailed: "Could not read this file"
        }
    }

    var detail: String {
        switch self {
        case .unavailable:
            "The file no longer exists or Lithe does not have access to it."
        case .directory:
            "Open a text file instead of a folder."
        case .tooLarge:
            "Standalone text files are limited to 32 MB."
        case .notText:
            "Only UTF-8 text files are supported in the standalone editor."
        case .readFailed:
            "The file could not be read. Check its permissions and try again."
        }
    }
}

enum StandaloneFileLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(StandaloneFileOpenFailure)
}

/// Owns editor document lifecycle and persistence-facing state. Java services,
/// local history, and UI notifications are supplied by application composition.
@MainActor
final class DocumentFeatureModel: ObservableObject {
    @Published private(set) var openDocuments: [EditorDocument] = [] {
        didSet { updateDocumentObservation() }
    }
    @Published var activeDocumentID: UUID? {
        didSet { focusedEditorDocumentID = activeDocumentID }
    }
    private var focusedEditorDocumentID: UUID?

    func editorDidFocus(_ document: EditorDocument) {
        guard openDocuments.contains(where: { $0 === document }) else { return }
        focusedEditorDocumentID = document.id
    }
    @Published private(set) var standaloneFileLoadState: StandaloneFileLoadState = .idle
    @Published private(set) var pendingCloseDocument: EditorDocument? {
        didSet { pendingCloseConfirmationID = pendingCloseDocument.map { _ in UUID() } }
    }
    private(set) var pendingCloseConfirmationID: UUID?
    private var previewDiscardID: UUID?
    private var groupCloseTask: Task<Void, Never>?
    private var groupCloseID: UUID?
    private var pendingClosePreparation: EditorClosingPreparation?
    private var closeRequestID = UUID()
    private var pendingCloseTask: Task<Void, Never>?
    var hasPendingDocumentClose: Bool { pendingCloseDocument != nil || pendingCloseTask != nil || groupCloseTask != nil }
    @Published private(set) var isPendingProjectClose = false
    @Published private(set) var projectTreeRevealRequest: ProjectTreeRevealRequest?

    enum SaveProgress: Error { case newerRevisionPending }
    private var persistenceGeneration = UUID()
    private var saveTasks: [UUID: Task<Void, Error>] = [:]
    private var externalChangeTasks: [UUID: Task<Void, Never>] = [:]
    private var externalChangeIDs: [UUID: UUID] = [:]
    private var manualSaveTask: Task<Void, Never>?
    private var documentObservation: (any DocumentFileObservation)?
    private var observedDocumentPaths: [String] = []
    private var observationID = UUID()

    private func updateDocumentObservation() {
        let urls = observedDocuments.filter { !$0.isReadOnly }.map(\.url).sorted { $0.path < $1.path }
        let paths = urls.map(\.path)
        guard paths != observedDocumentPaths else { return }
        observedDocumentPaths = paths
        observationID = UUID()
        let id = observationID
        documentObservation?.cancel()
        documentObservation = nil
        guard !urls.isEmpty else { return }
        documentObservation = fileOperations.observeDocuments(at: urls) { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.observationID == id else { return }
                self.processExternalChanges(changes)
            }
        }
    }

    deinit {
        documentObservation?.cancel()
        for task in saveTasks.values { task.cancel() }
        for task in externalChangeTasks.values { task.cancel() }
        manualSaveTask?.cancel()
        pendingCloseTask?.cancel()
        for entry in autoSaveTasks.values { entry.task.cancel() }
    }

    /// Clean previews stay outside the tab collection until opened or edited.
    func previewDocument(at url: URL) async -> EditorDocument? {
        previewDiscardID = nil
        await openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: false, asPreview: true)
        guard !Task.isCancelled else { return nil }
        return openDocuments.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? previewDocuments[url.standardizedFileURL.path]
    }

    func promotePreviewDocument(_ document: EditorDocument) {
        let path = document.url.standardizedFileURL.path
        guard previewDocuments[path] === document else { return }
        openDocuments.append(document)
        previewDocuments[path] = nil
        processExternalChanges([document.url])
        onDocumentCollectionChanged?()
        onDocumentOpened?(document)
    }

    /// Includes transient source previews, which still own live editor buffers.
    var editorDocuments: [EditorDocument] {
        openDocuments + previewDocuments.values.sorted { $0.url.path < $1.url.path }
    }

    func discardPreviewDocuments() {
        let discardID = UUID()
        previewDiscardID = discardID
        pendingFileOpenRequests = pendingFileOpenRequests.filter { !$0.value.isPreview }
        for document in Array(previewDocuments.values) {
            document.withSynchronizedEditor { [weak self, weak document] result in
                guard let self, let document, self.previewDiscardID == discardID,
                      self.previewDocuments[document.url.standardizedFileURL.path] === document else { return }
                switch result {
                case .success:
                    if document.isDirty { self.promotePreviewDocument(document) }
                    else {
                        self.objectWillChange.send()
                        self.externalChangeTasks.removeValue(forKey: document.id)?.cancel()
                        self.externalChangeIDs.removeValue(forKey: document.id)
                        self.previewDocuments[document.url.standardizedFileURL.path] = nil
                        self.onDocumentCollectionChanged?()
                    }
                case .failure(let error):
                    // A failed drain may hide unsent input; keep the document reachable.
                    self.promotePreviewDocument(document)
                    self.notify?(error.localizedDescription)
                }
            }
        }
    }

    private let operations: any WorkspaceOperations
    private let documentLifecycleDecider: any DocumentLifecycleDeciding
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
    private var onCloseFailed: (@MainActor () -> Void)?
    private var autoSaveTasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private let autoSaveDelay: @Sendable (Duration) async throws -> Void
    private var pendingFileOpenRequests: [String: (id: UUID, task: Task<Void, Never>, isPreview: Bool)] = [:]
    private var previewDocuments: [String: EditorDocument] = [:] {
        didSet { updateDocumentObservation() }
    }

    private var observedDocuments: [EditorDocument] {
        let openIDs = Set(openDocuments.map(\.id))
        return openDocuments + previewDocuments.values.filter { !openIDs.contains($0.id) }
            .sorted { $0.url.path < $1.url.path }
    }
    private var latestFileOpenRequestID: UUID?
    private var pendingCloseQueue: [EditorDocument] = []
    private var pendingClosePreferredDocumentID: UUID?
    private var standaloneOpenRequestID: UUID?
    private var standaloneOpenTask: Task<Void, Never>?

    init(
        operations: any WorkspaceOperations,
        documentLifecycleDecider: any DocumentLifecycleDeciding,
        fileOperations: any WorkspaceFileOperations,
        fileStorage: any FileStorage,
        binaryFileViewerRegistry: BinaryFileViewerRegistry,
        autoSaveDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.operations = operations
        self.documentLifecycleDecider = documentLifecycleDecider
        self.fileOperations = fileOperations
        self.fileStorage = fileStorage
        self.binaryFileViewerRegistry = binaryFileViewerRegistry
        self.autoSaveDelay = autoSaveDelay
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
        onProjectCloseReady: @escaping @MainActor () -> Void,
        onCloseFailed: @escaping @MainActor () -> Void = {}
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
        self.onCloseFailed = onCloseFailed
    }

    var activeDocument: EditorDocument? {
        guard let activeDocumentID else { return nil }
        return openDocuments.first { $0.id == activeDocumentID }
    }

    /// Menu commands follow the last focused editor surface, while tab selection
    /// remains independently owned by activeDocumentID.
    var focusedEditorDocument: EditorDocument? {
        openDocuments.first { $0.id == focusedEditorDocumentID } ?? activeDocument
    }

    var hasUnsavedDocuments: Bool {
        openDocuments.contains { $0.isDirty || $0.needsEditorSynchronization }
    }

    func reset() {
        cancelPendingClose()
        previewDiscardID = nil
        persistenceGeneration = UUID()
        for task in externalChangeTasks.values { task.cancel() }
        externalChangeTasks.removeAll()
        externalChangeIDs.removeAll()
        manualSaveTask?.cancel()
        manualSaveTask = nil
        standaloneOpenTask?.cancel()
        standaloneOpenTask = nil
        standaloneOpenRequestID = nil
        autoSaveTasks.values.forEach { $0.task.cancel() }
        autoSaveTasks.removeAll()
        pendingFileOpenRequests.removeAll()
        previewDocuments.removeAll()
        latestFileOpenRequestID = nil
        pendingCloseDocument = nil
        projectTreeRevealRequest = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        isPendingProjectClose = false
        openDocuments = []
        activeDocumentID = nil
        standaloneFileLoadState = .idle
    }

    func openFile(
        _ url: URL,
        isReadOnly: Bool = false,
        displayPath: String? = nil
    ) {
        let normalizedURL = url.standardizedFileURL
        let filePath = normalizedURL.path

        // Switching to an already-open document does not require file I/O.
        // Apply that state change synchronously so repeated tree clicks feel immediate.
        if let existing = openDocuments.first(where: {
            $0.url.standardizedFileURL.path == filePath
        }) ?? previewDocuments[filePath] {
            let wasPreview = previewDocuments[filePath] === existing
            promotePreviewDocument(existing)
            latestFileOpenRequestID = UUID()
            activeDocumentID = existing.id
            if !isReadOnly && !wasPreview {
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

    func openStandaloneFile(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        if let existing = openDocuments.first(where: { $0.url == normalizedURL }) {
            activeDocumentID = existing.id
            standaloneFileLoadState = .loaded
            return
        }

        standaloneOpenTask?.cancel()
        let requestID = UUID()
        standaloneOpenRequestID = requestID
        standaloneFileLoadState = .loading
        openDocuments = []
        activeDocumentID = nil
        let fileStorage = self.fileStorage
        standaloneOpenTask = Task { [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.readStandaloneFile(at: normalizedURL, using: fileStorage)
            }.value

            guard self.standaloneOpenRequestID == requestID else { return }
            self.standaloneOpenTask = nil

            guard case let .success(text) = result else {
                if case let .failure(failure) = result {
                    self.standaloneFileLoadState = .failed(failure)
                }
                return
            }

            let document = EditorDocument(
                url: normalizedURL,
                text: text,
                modificationDate: EditorDocument.modificationDate(for: normalizedURL),
                isReadOnly: false
            )
            self.openDocuments = [document]
            self.activeDocumentID = document.id
            self.standaloneFileLoadState = .loaded
            self.onDocumentCollectionChanged?()
            self.onDocumentOpened?(document)
        }
    }

    nonisolated private static func readStandaloneFile(
        at url: URL,
        using fileStorage: any FileStorage
    ) -> Result<String, StandaloneFileOpenFailure> {
        guard let metadata = fileStorage.metadata(for: url) else {
            return .failure(.unavailable)
        }
        guard !metadata.isDirectory else { return .failure(.directory) }
        guard metadata.isRegularFile else { return .failure(.unavailable) }
        if let byteCount = metadata.byteCount,
           byteCount > WorkspaceTextFilePolicy.standaloneFileByteLimit {
            return .failure(.tooLarge)
        }

        let data: Data
        do {
            data = try fileStorage.readData(from: url, options: [])
        } catch {
            return .failure(.readFailed)
        }
        guard data.count <= WorkspaceTextFilePolicy.standaloneFileByteLimit else {
            return .failure(.tooLarge)
        }
        guard let text = String(data: data, encoding: .utf8),
              WorkspaceTextFilePolicy.isPlainText(text) else {
            return .failure(.notText)
        }
        return .success(text)
    }

    func openFileAsync(
        _ url: URL,
        isReadOnly: Bool,
        displayPath: String?,
        activateWhenReady: Bool,
        asPreview: Bool = false
    ) async {
        let normalizedURL = url.standardizedFileURL
        let filePath = normalizedURL.path

        if let existing = openDocuments.first(where: {
            $0.url.standardizedFileURL.path == filePath
        }) ?? previewDocuments[filePath] {
            let wasPreview = previewDocuments[filePath] === existing
            if wasPreview && asPreview {
                await reconcileExternalChanges([existing.url])
            }
            if !asPreview { promotePreviewDocument(existing) }
            if activateWhenReady {
                let requestID = UUID()
                latestFileOpenRequestID = requestID
                activeDocumentID = existing.id
            }
            if !isReadOnly && !asPreview && !wasPreview {
                onDocumentOpened?(existing)
            }
            return
        }

        if let pending = pendingFileOpenRequests[filePath] {
            if !asPreview { pendingFileOpenRequests[filePath]?.isPreview = false }
            if activateWhenReady {
                latestFileOpenRequestID = pending.id
            }
            await pending.task.value
            return
        }
        let requestID = UUID()
        if activateWhenReady {
            latestFileOpenRequestID = requestID
        }
        // One owned load serves every caller; cancelling a preview must not cancel another caller's load.
        let task = Task { @MainActor in
            await loadFile(normalizedURL, isReadOnly: isReadOnly, displayPath: displayPath,
                           activateWhenReady: activateWhenReady, requestID: requestID)
        }
        pendingFileOpenRequests[filePath] = (requestID, task, asPreview)
        await task.value
    }

    private func loadFile(
        _ normalizedURL: URL, isReadOnly: Bool, displayPath: String?,
        activateWhenReady: Bool, requestID: UUID
    ) async {
        let filePath = normalizedURL.path
        defer {
            if pendingFileOpenRequests[filePath]?.id == requestID {
                pendingFileOpenRequests[filePath] = nil
            }
        }

        guard let workspaceURLProvider,
              let openingWorkspaceURL = workspaceURLProvider(),
              let relativePath = workspaceRelativePath(for: normalizedURL, root: openingWorkspaceURL) else {
            notify?("This file is outside the current workspace")
            return
        }

        let operations = self.operations
        let text = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: operations.readFile(
                        at: openingWorkspaceURL,
                        relativePath: relativePath
                    )
                )
            }
        }
        guard let text else {
            if pendingFileOpenRequests[filePath]?.isPreview == true { return }
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
            guard workspaceURLProvider() == openingWorkspaceURL,
                  pendingFileOpenRequests[filePath]?.id == requestID else { return }
            let shouldActivate = activateWhenReady && latestFileOpenRequestID == requestID
            if let header,
               await binaryFileViewerRegistry.openIfSupported(
                   url: normalizedURL,
                   header: header,
                   activateWhenReady: shouldActivate
               ) {
                return
            }
            notify?("This file cannot be displayed as text")
            return
        }
        guard workspaceURLProvider() == openingWorkspaceURL,
              pendingFileOpenRequests[filePath]?.id == requestID else { return }

        let document = EditorDocument(
            url: normalizedURL,
            text: text,
            modificationDate: EditorDocument.modificationDate(for: normalizedURL),
            isReadOnly: isReadOnly,
            displayPath: displayPath
        )
        guard !openDocuments.contains(where: {
            $0.url.standardizedFileURL.path == filePath
        }) else { return }
        if pendingFileOpenRequests[filePath]?.isPreview == true {
            previewDocuments[filePath] = document
            return
        }
        openDocuments.append(document)
        if latestFileOpenRequestID == requestID {
            activeDocumentID = document.id
        }
        onDocumentCollectionChanged?()
        onDocumentOpened?(document)
    }

    func requestProjectTreeReveal(for fileURL: URL, isDirectory: Bool = false) {
        projectTreeRevealRequest = ProjectTreeRevealRequest(
            fileURL: fileURL,
            isDirectory: isDirectory
        )
    }

    func consumeProjectTreeRevealRequest(id: UUID) {
        guard projectTreeRevealRequest?.id == id else { return }
        projectTreeRevealRequest = nil
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

    func reorderDocuments(orderedIDs: [UUID]) {
        let documentsByID = Dictionary(uniqueKeysWithValues: openDocuments.map { ($0.id, $0) })
        var includedIDs: Set<UUID> = []
        var next = orderedIDs.compactMap { id -> EditorDocument? in
            guard includedIDs.insert(id).inserted else { return nil }
            return documentsByID[id]
        }
        next.append(contentsOf: openDocuments.filter { !includedIDs.contains($0.id) })
        guard next.map(\.id) != openDocuments.map(\.id) else { return }
        openDocuments = next
        onDocumentCollectionChanged?()
    }

    func requestCloseDocument(_ document: EditorDocument) {
        cancelPendingClose()
        if document.needsEditorSynchronization {
            closeSynchronizedGroup([document], preferredDocumentID: nil)
            return
        }
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
        cancelPendingClose()
        if targets.contains(where: \.needsEditorSynchronization) {
            closeSynchronizedGroup(targets, preferredDocumentID: preferredDocumentID)
            return
        }

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

    private func cancelGroupClose() {
        groupCloseID = nil
        groupCloseTask?.cancel()
        groupCloseTask = nil
        pendingClosePreparation?.release()
        pendingClosePreparation = nil
    }

    private func closeSynchronizedGroup(
        _ documents: [EditorDocument], preferredDocumentID: UUID?, closingProject: Bool = false
    ) {
        let operationID = UUID()
        groupCloseID = operationID
        isPendingProjectClose = closingProject
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = preferredDocumentID
        groupCloseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.groupCloseID == operationID {
                    self.groupCloseID = nil
                    self.groupCloseTask = nil
                }
            }
            let targets = documents.filter { candidate in self.openDocuments.contains { $0 === candidate } }
            let preparation: EditorClosingPreparation
            do { preparation = try await EditorClosingPreparation.acquire(targets) }
            catch {
                if self.groupCloseID == operationID, !Task.isCancelled {
                    self.notify?("Editor synchronization failed: \(error.localizedDescription)")
                    self.cancelPendingClose()
                }
                return
            }
            var transferred = false
            defer { if !transferred { preparation.release() } }
            var dirtyDocuments: [EditorDocument] = []
            for document in targets {
                guard self.groupCloseID == operationID, !Task.isCancelled else { return }
                guard self.openDocuments.contains(where: { $0 === document }) else { continue }
                let succeeded = await withCheckedContinuation { continuation in
                    document.withSynchronizedEditor { [weak self] result in
                        guard let self, self.groupCloseID == operationID else {
                            continuation.resume(returning: false); return
                        }
                        do {
                            try result.get()
                            if document.isDirty { dirtyDocuments.append(document) }
                            else { self.closeDocument(document) }
                            continuation.resume(returning: true)
                        } catch {
                            self.notify?("Editor synchronization failed: \(error.localizedDescription)")
                            continuation.resume(returning: false)
                        }
                    }
                }
                guard succeeded else {
                    if self.groupCloseID == operationID { self.cancelPendingClose() }
                    return
                }
            }
            guard self.groupCloseID == operationID else { return }
            if !dirtyDocuments.isEmpty {
                self.pendingClosePreparation = preparation
                transferred = true
            }
            self.pendingCloseDocument = dirtyDocuments.first
            self.pendingCloseQueue = Array(dirtyDocuments.dropFirst())
            if dirtyDocuments.isEmpty {
                if closingProject {
                    self.completePendingProjectClose()
                } else {
                    self.activatePreferredDocumentIfPossible()
                }
            }
        }
    }

    /// Returns true when the caller must wait for the save/discard dialog.
    @discardableResult
    func beginProjectClose() -> Bool {
        if isPendingProjectClose { return true }
        cancelPendingClose()
        if openDocuments.contains(where: \.needsEditorSynchronization) {
            closeSynchronizedGroup(openDocuments, preferredDocumentID: nil, closingProject: true)
            return true
        }
        guard !openDocuments.filter(\.isDirty).isEmpty else { return false }
        isPendingProjectClose = true
        pendingCloseQueue = Array(openDocuments.filter(\.isDirty).dropFirst())
        pendingClosePreferredDocumentID = nil
        pendingCloseDocument = openDocuments.first(where: \.isDirty)
        return true
    }

    /// Claim the choice before SwiftUI dismisses its dialog. The save owns a
    /// request token independently of the next visible confirmation.
    @discardableResult
    func closePendingDocument(discardingChanges: Bool) -> Task<Void, Never>? {
        guard pendingCloseTask == nil, let document = pendingCloseDocument else { return nil }
        let requestID = closeRequestID
        pendingCloseDocument = nil
        let task = Task { [weak self] in
            guard let self, self.closeRequestID == requestID, !Task.isCancelled else { return }
            defer {
                if self.closeRequestID == requestID { self.pendingCloseTask = nil }
            }
            if discardingChanges {
                self.onRecordDiscard?(document)
            } else if document.isDirty {
                do {
                    let previousText = document.savedText
                    try await self.saveDocument(document)
                    guard self.closeRequestID == requestID, !Task.isCancelled else { return }
                    self.onRecordSave?(document, previousText)
                } catch {
                    guard self.closeRequestID == requestID, !Task.isCancelled else { return }
                    self.cancelPendingClose()
                    self.onCloseFailed?()
                    self.notify?("Could not save \(document.url.lastPathComponent)")
                    return
                }
            }

            guard self.closeRequestID == requestID,
                  self.openDocuments.contains(where: { $0.id == document.id }),
                  discardingChanges || !document.isDirty else { return }
            self.closeDocument(document)
            self.pendingCloseQueue.removeAll { queued in
                !self.openDocuments.contains(where: { $0.id == queued.id })
            }
            if let nextDocument = self.pendingCloseQueue.first {
                self.pendingCloseQueue.removeFirst()
                self.pendingCloseDocument = nextDocument
            } else if self.isPendingProjectClose {
                // Input or a newly opened document may have arrived during saving.
                self.isPendingProjectClose = false
                self.pendingClosePreferredDocumentID = nil
                if !self.beginProjectClose() { self.onProjectCloseReady?() }
            } else {
                self.pendingClosePreparation?.release()
                self.pendingClosePreparation = nil
                self.activatePreferredDocumentIfPossible()
            }
        }
        pendingCloseTask = task
        return task
    }

    /// A late dismissal from an accepted dialog must not cancel the next one.
    func dismissPendingCloseConfirmation(_ confirmationID: UUID?) {
        guard let confirmationID, confirmationID == pendingCloseConfirmationID else { return }
        cancelPendingClose()
    }

    private func completePendingProjectClose() {
        pendingClosePreparation?.release()
        pendingClosePreparation = nil
        isPendingProjectClose = false
        pendingClosePreferredDocumentID = nil
        if !openDocuments.isEmpty, beginProjectClose() { return }
        onProjectCloseReady?()
    }

    func cancelPendingClose() {
        cancelGroupClose()
        closeRequestID = UUID()
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        pendingCloseDocument = nil
        pendingCloseQueue = []
        pendingClosePreferredDocumentID = nil
        isPendingProjectClose = false
    }

    @discardableResult
    func saveAllDocuments() async -> Bool {
        for document in openDocuments where !document.isReadOnly {
            do {
                let previousText = document.savedText
                try await saveDocument(document)
                if document.savedText != previousText { onRecordSave?(document, previousText) }
            } catch {
                return false
            }
        }
        return !Task.isCancelled && !openDocuments.contains(where: \.isDirty)
    }

    @discardableResult
    func saveActiveDocument() -> Task<Void, Never>? {
        guard let document = focusedEditorDocument else { return nil }
        return saveEditorDocument(document)
    }

    @discardableResult
    func saveEditorDocument(_ document: EditorDocument) -> Task<Void, Never>? {
        guard manualSaveTask == nil, openDocuments.contains(where: { $0 === document }) else { return nil }
        let generation = persistenceGeneration
        manualSaveTask = Task { [weak self] in
            guard let self, self.persistenceGeneration == generation, !Task.isCancelled else { return }
            defer {
                if self.persistenceGeneration == generation { self.manualSaveTask = nil }
            }
            do {
                let previousText = document.savedText
                try await self.saveDocument(document)
                guard self.persistenceGeneration == generation, !Task.isCancelled else { return }
                self.onRecordSave?(document, previousText)
                self.notify?("Saved \(document.url.lastPathComponent)")
            } catch {
                if self.persistenceGeneration == generation, !Task.isCancelled {
                    self.notify?("Could not save \(document.url.lastPathComponent)")
                }
            }
        }
        return manualSaveTask
    }

    func save(_ document: EditorDocument) async throws {
        try await saveDocument(document)
    }

    @discardableResult
    func documentDidChange(_ document: EditorDocument) -> Task<Void, Never>? {
        onDocumentChanged?(document)
        autoSaveTasks[document.id]?.task.cancel()
        guard autoSaveEnabledProvider?() == true else {
            autoSaveTasks.removeValue(forKey: document.id)
            return nil
        }
        let delay = autoSaveDelayProvider?() ?? 0
        let id = UUID()
        let wait = autoSaveDelay
        let task = Task { [weak self, weak document] in
            try? await wait(.seconds(delay))
            guard let self, let document else { return }
            defer {
                if self.autoSaveTasks[document.id]?.id == id {
                    self.autoSaveTasks.removeValue(forKey: document.id)
                }
            }
            guard !Task.isCancelled, self.autoSaveEnabledProvider?() == true, document.isDirty else { return }
            while !Task.isCancelled, self.autoSaveTasks[document.id]?.id == id,
                  self.autoSaveEnabledProvider?() == true, document.isDirty {
                do {
                    let previousText = document.savedText
                    try await self.saveDocument(document)
                    if !Task.isCancelled { self.onRecordSave?(document, previousText) }
                    return
                } catch SaveProgress.newerRevisionPending {
                    // Only a completed write with newer local input may continue.
                    // Conflicts and I/O failures must never become automatic retries.
                    guard self.openDocuments.contains(where: { $0 === document }) else { return }
                } catch {
                    if !Task.isCancelled { self.notify?("Could not auto-save \(document.url.lastPathComponent)") }
                    return
                }
            }
        }
        autoSaveTasks[document.id] = (id, task)
        return task
    }

    func loadExternalVersion(of document: EditorDocument) {
        externalChangeTasks[document.id]?.cancel()
        let id = UUID()
        externalChangeIDs[document.id] = id
        let url = document.url
        let locationRevision = document.locationRevision
        externalChangeTasks[document.id] = Task { [weak self, weak document] in
            guard let self, let document else { return }
            defer {
                if self.externalChangeIDs[document.id] == id {
                    self.externalChangeTasks.removeValue(forKey: document.id)
                    self.externalChangeIDs.removeValue(forKey: document.id)
                }
            }
            do {
                let preparation = try await EditorClosingPreparation.acquire([document])
                defer { preparation.release() }
                try await self.synchronizeEditor(document)
                guard document.url == url, document.locationRevision == locationRevision,
                      document.lifecycleState.status != .saving,
                      self.observedDocuments.contains(where: { $0 === document }) else { return }
                let revision = document.lifecycleState.revision
                guard let content = try await self.fileOperations.readDocumentTextAsync(from: url),
                      !Task.isCancelled, document.url == url,
                      document.locationRevision == locationRevision, document.lifecycleState.status != .saving,
                      document.lifecycleState.revision == revision,
                      self.observedDocuments.contains(where: { $0 === document }) else { return }
                let decision = try self.documentLifecycleDecider.decide(
                    state: document.lifecycleState, event: .loadDisk, operationID: id.uuidString)
                guard decision.action == .reloadFromDisk else { return }
                if document.isDirty { self.onRecordDiscard?(document) }
                document.replaceWithDiskContent(content)
                self.onDocumentChanged?(document)
                self.notify?("Loaded file-system version")
            } catch {
                if !Task.isCancelled { self.notify?("Could not reload \(url.lastPathComponent)") }
            }
        }
    }

    func keepEditorVersion(of document: EditorDocument) {
        guard document.hasObservedDiskConflict else { return }
        let operationID = UUID().uuidString
        do {
            let decision = try documentLifecycleDecider.decide(
                state: document.lifecycleState,
                event: .keepEditor,
                operationID: operationID
            )
            document.applyLifecycleState(decision.state)
            document.acknowledgeObservedDiskContent()
            notify?("Kept editor version")
        } catch {
            notify?("Could not resolve the external file change")
        }
    }

    /// Callers reopening a preview can wait for the same guarded reconciliation
    /// used by watcher notifications without blocking the main actor on disk I/O.
    func reconcileExternalChanges(_ urls: [URL]) async {
        processExternalChanges(urls)
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        // Native events may replace a read while it is suspended. Follow its
        // successor too, but bound the wait during a continuous event burst.
        for _ in 0..<4 {
            let tasks = observedDocuments.filter { paths.contains($0.url.standardizedFileURL.path) }
                .compactMap { externalChangeTasks[$0.id] }
            guard !tasks.isEmpty, !Task.isCancelled else { return }
            for task in tasks { await task.value }
        }
    }

    @discardableResult
    func processExternalChanges(_ urls: [URL]) -> Bool {
        let changedPaths = Set(urls.map { $0.standardizedFileURL.path })
        for document in observedDocuments where changedPaths.contains(document.url.standardizedFileURL.path) {
            externalChangeTasks[document.id]?.cancel()
            let id = UUID()
            externalChangeIDs[document.id] = id
            externalChangeTasks[document.id] = Task { [weak self, weak document] in
                guard let self, let document else { return }
                defer {
                    if self.externalChangeIDs[document.id] == id {
                        self.externalChangeIDs.removeValue(forKey: document.id)
                        self.externalChangeTasks.removeValue(forKey: document.id)
                    }
                }
                guard document.lifecycleState.status != .saving else { return }
                let url = document.url
                let locationRevision = document.locationRevision
                let revision = document.lifecycleState.revision
                let baseline = document.expectedDiskContent.map { Data($0.utf8) }
                do {
                    let content = try await self.fileOperations.readDocumentTextAsync(from: url)
                    guard !Task.isCancelled, document.url == url, document.locationRevision == locationRevision,
                          self.observedDocuments.contains(where: { $0.id == document.id }) else { return }
                    if document.lifecycleState.status == .saving { return }
                    guard baseline == document.expectedDiskContent.map({ Data($0.utf8) }) else {
                        self.processExternalChanges([url]); return
                    }
                    if content.map({ Data($0.utf8) }) == baseline { return }
                    let preparation = try await EditorClosingPreparation.acquire([document])
                    defer { preparation.release() }
                    try await self.synchronizeEditor(document)
                    // Holding and draining the remote editor both suspend. The
                    // disk snapshot must still belong to this exact location.
                    guard document.url == url, document.locationRevision == locationRevision,
                          document.lifecycleState.status != .saving,
                          self.observedDocuments.contains(where: { $0 === document }),
                          baseline == document.expectedDiskContent.map({ Data($0.utf8) }) else { return }
                    // New local input stays owned by the editor. The reducer sees its latest state.
                    let decision = try self.documentLifecycleDecider.decide(state: document.lifecycleState,
                        event: content == nil ? .diskConflict : .externalChanged, operationID: id.uuidString)
                    if decision.action == .reloadFromDisk, document.lifecycleState.revision != revision {
                        self.processExternalChanges([url]); return
                    }
                    document.applyLifecycleState(decision.state)
                    switch decision.action {
                    case .reloadFromDisk:
                        if let content { document.replaceWithDiskContent(content) }
                    case .showConflict:
                        document.observeDiskConflict(content)
                        self.autoSaveTasks.removeValue(forKey: document.id)?.task.cancel()
                    default: break
                    }
                    if self.openDocuments.contains(where: { $0 === document }) {
                        self.onDocumentChanged?(document)
                    }
                } catch {
                    if !Task.isCancelled { self.notify?("Could not process an external change to \(url.lastPathComponent)") }
                }
            }
        }
        onRecordExternalChanges?(urls)
        return false
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
        updateDocumentObservation()
        onDocumentCollectionChanged?()
    }

    private func closeDocument(_ document: EditorDocument) {
        guard let index = openDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        externalChangeTasks.removeValue(forKey: document.id)?.cancel()
        externalChangeIDs.removeValue(forKey: document.id)
        autoSaveTasks[document.id]?.task.cancel()
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

    private func synchronizeEditor(_ document: EditorDocument) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.withSynchronizedEditor { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
    }

    private func saveDocument(_ document: EditorDocument) async throws {
        guard !document.isReadOnly else { throw EditorDocument.DocumentError.readOnly }
        let generation = persistenceGeneration
        let wasOwned = observedDocuments.contains { $0 === document }
        try await synchronizeEditor(document)
        guard persistenceGeneration == generation,
              !wasOwned || observedDocuments.contains(where: { $0 === document }) else { throw CancellationError() }
        guard document.isDirty else { return }
        if let task = saveTasks[document.id] {
            try await task.value
            guard !document.isDirty else { throw SaveProgress.newerRevisionPending }
            return
        }
        try Task.checkCancellation()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            defer {
                self.saveTasks.removeValue(forKey: document.id)
                self.processExternalChanges([document.url])
            }
            try Task.checkCancellation()
            guard self.persistenceGeneration == generation else { throw CancellationError() }
            try await self.performDocumentSave(document, generation: generation)
        }
        saveTasks[document.id] = task
        try await task.value
    }

    private func performDocumentSave(_ document: EditorDocument, generation: UUID) async throws {
        guard !document.isReadOnly else { throw EditorDocument.DocumentError.readOnly }
        let operationID = UUID().uuidString
        let saving = try documentLifecycleDecider.decide(
            state: document.lifecycleState,
            event: .saveStarted(operationID: operationID),
            operationID: operationID
        )
        guard saving.action == .writeToDisk else {
            document.applyLifecycleState(saving.state)
            throw CocoaError(.userCancelled)
        }
        document.applyLifecycleState(saving.state)
        let content = document.text
        let url = document.url
        let expectedContent = document.expectedDiskContent

        do {
            let result = try await fileOperations.writeDocumentTextAsync(content, to: url, expectedContent: expectedContent)
            guard persistenceGeneration == generation, document.url == url else { throw CancellationError() }
            switch result {
            case .saved:
                try completeSave(document, operationID: operationID, savedContent: content)
                guard !document.isDirty else { throw SaveProgress.newerRevisionPending }
            case .conflict(let content):
                let conflict = try documentLifecycleDecider.decide(state: document.lifecycleState, event: .diskConflict, operationID: operationID)
                document.observeDiskConflict(content)
                document.applyLifecycleState(conflict.state)
                autoSaveTasks.removeValue(forKey: document.id)?.task.cancel()
                onDocumentChanged?(document)
                throw CocoaError(.userCancelled)
            }
        } catch SaveProgress.newerRevisionPending {
            throw SaveProgress.newerRevisionPending
        } catch let saveError {
            do {
                let failed = try documentLifecycleDecider.decide(
                    state: document.lifecycleState,
                    event: .saveFailed(operationID: operationID),
                    operationID: operationID
                )
                document.applyLifecycleState(failed.state)
            } catch let recoveryError {
                NSLog(
                    "[document.lifecycle] outcome=failed stage=save-state-recovery operationID=%@ documentID=%@ error=%@",
                    operationID,
                    document.id.uuidString,
                    recoveryError.localizedDescription
                )
            }
            throw saveError
        }
    }

    private func completeSave(_ document: EditorDocument, operationID: String, savedContent: String) throws {
        let completed = try documentLifecycleDecider.decide(
            state: document.lifecycleState,
            event: .saveSucceeded(operationID: operationID),
            operationID: operationID
        )
        document.markSavedWithoutWriting(state: completed.state, savedContent: savedContent)
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
