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
    @Published private(set) var openDocuments: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    @Published private(set) var standaloneFileLoadState: StandaloneFileLoadState = .idle
    @Published private(set) var pendingCloseDocument: EditorDocument?
    @Published private(set) var isPendingProjectClose = false
    @Published private(set) var projectTreeRevealRequest: ProjectTreeRevealRequest?

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
    private var autoSaveTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingFileOpenRequests: [String: UUID] = [:]
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
        binaryFileViewerRegistry: BinaryFileViewerRegistry
    ) {
        self.operations = operations
        self.documentLifecycleDecider = documentLifecycleDecider
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
        standaloneOpenTask?.cancel()
        standaloneOpenTask = nil
        standaloneOpenRequestID = nil
        autoSaveTasks.values.forEach { $0.cancel() }
        autoSaveTasks.removeAll()
        pendingFileOpenRequests.removeAll()
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
        }) {
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
        activateWhenReady: Bool
    ) async {
        let normalizedURL = url.standardizedFileURL
        let filePath = normalizedURL.path

        if let existing = openDocuments.first(where: {
            $0.url.standardizedFileURL.path == filePath
        }) {
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
        if let pendingRequestID = pendingFileOpenRequests[filePath] {
            if activateWhenReady {
                latestFileOpenRequestID = pendingRequestID
            }
            return
        }
        pendingFileOpenRequests[filePath] = requestID
        if activateWhenReady {
            latestFileOpenRequestID = requestID
        }
        defer {
            if pendingFileOpenRequests[filePath] == requestID {
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
                  pendingFileOpenRequests[filePath] == requestID else { return }
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
        guard workspaceURLProvider() == openingWorkspaceURL else { return }

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
        let operationID = UUID().uuidString
        do {
            let decision = try documentLifecycleDecider.decide(
                state: document.lifecycleState,
                event: .loadDisk,
                operationID: operationID
            )
            guard decision.action == .reloadFromDisk else { return }
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
        let operationID = UUID().uuidString
        do {
            let decision = try documentLifecycleDecider.decide(
                state: document.lifecycleState,
                event: .keepEditor,
                operationID: operationID
            )
            document.applyLifecycleState(decision.state)
            document.acknowledgeExternalModification()
            notify?("Kept editor version")
        } catch {
            notify?("Could not resolve the external file change")
        }
    }

    @discardableResult
    func processExternalChanges(_ urls: [URL]) -> Bool {
        let changedPathSet = Set(urls.map { $0.standardizedFileURL.path })
        var conflictDetected = false
        for document in openDocuments where changedPathSet.contains(document.url.standardizedFileURL.path) {
            guard document.hasPossibleExternalChange() else { continue }
            let operationID = UUID().uuidString
            do {
                let decision = try documentLifecycleDecider.decide(
                    state: document.lifecycleState,
                    event: .externalChanged,
                    operationID: operationID
                )
                document.applyLifecycleState(decision.state)
                switch decision.action {
                case .reloadFromDisk:
                    try document.reloadFromDisk()
                case .showConflict:
                    conflictDetected = true
                case .none, .writeToDisk, .reportSaveFailure, .ignoreStaleResult:
                    break
                }
                onDocumentChanged?(document)
            } catch {
                notify?("Could not process an external change to \(document.url.lastPathComponent)")
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

        do {
            if let workspaceURLProvider,
               let workspaceURL = workspaceURLProvider(),
               let relativePath = workspaceRelativePath(for: document.url, root: workspaceURL),
               operations.writeFile(document.text, at: workspaceURL, relativePath: relativePath) {
                try completeSave(document, operationID: operationID)
                return
            }
            try fileOperations.writeText(document.text, to: document.url)
            try completeSave(document, operationID: operationID)
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

    private func completeSave(_ document: EditorDocument, operationID: String) throws {
        let completed = try documentLifecycleDecider.decide(
            state: document.lifecycleState,
            event: .saveSucceeded(operationID: operationID),
            operationID: operationID
        )
        document.markSavedWithoutWriting(state: completed.state)
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
