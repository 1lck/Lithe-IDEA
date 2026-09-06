import Combine
import Foundation
import LitheCoreContracts

package enum WorkspaceRebuildResult: Sendable {
    case loaded(WorkspaceSnapshot)
    case unavailable
    case stale
}

/// Owns the workspace snapshot and delegates scanning and text reads to Core.
@MainActor
package final class WorkspaceFeatureModel: ObservableObject {
    package private(set) var workspaceGeneration = 0
    package private(set) var appliedSnapshot: WorkspaceSnapshot?
    @Published package private(set) var rootNode: FileNode?
    @Published package private(set) var projectFiles: [URL] = []
    @Published package private(set) var isLoadingWorkspace = false
    @Published package private(set) var isRefreshingWorkspace = false
    @Published package private(set) var loadErrorMessage: String?
    @Published package private(set) var directoryMarks: [String: WorkspaceDirectoryMark] = [:]
    @Published package var projectItemEditRequest: ProjectItemEditRequest?
    @Published package var pendingProjectItemDeletion: ProjectItemDeletionRequest?
    @Published package private(set) var isPerformingProjectItemOperation = false
    package private(set) var gitOperationFreezeDepth = 0

    private let operations: any WorkspaceOperations
    private let fileOperations: any WorkspaceFileOperations
    private let gitWatchContextProvider: any GitWatchContextProviding
    private let directoryWatcherFactory: any DirectoryWatcherFactory
    private let observationDelay: @Sendable (Duration) async throws -> Void
    private let workspaceSessionStore: any WorkspaceSessionStoring
    private let directoryMarkStore: any WorkspaceDirectoryMarkStoring
    private let directoryMarkPersistence: WorkspaceDirectoryMarkPersistence
    private var workspaceURL: URL?
    private var visibilityRules = FileVisibilityRules.default
    private var directoryMarkRevision = 0
    private var watchConfiguration: DirectoryWatchConfiguration?
    private var directoryWatcher: (any DirectoryChangeSource)?
    private var refreshTask: Task<Void, Never>?
    private var gitRefreshTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var visibilityRulesRefreshTask: Task<Void, Never>?
    private var pendingExternalPaths: Set<String> = []
    private var pendingGitRefresh = false
    private var pendingFullRescan = false
    private var pendingWatchRootsChanged = false
    private var isGitRefreshRunning = false
    private var externalRefreshGeneration = 0
    private var gitRefreshGeneration = 0
    private var workspaceSessionPersistenceTask: Task<Void, Never>?
    private var hasRestoredWorkspaceSession = false

    private var documentsProvider: (@MainActor () -> [WorkspaceDocumentState])?
    private var activeDocumentProvider: (@MainActor () -> WorkspaceDocumentState?)?
    private var selectedSidebarProvider: (@MainActor () -> String)?
    private var setSelectedSidebar: (@MainActor (String) -> Void)?
    private var restoreSession: (@MainActor (WorkspaceSession, [URL]) async -> Void)?
    private var openFile: (@MainActor (URL) -> Void)?
    private var notify: (@MainActor (String) -> Void)?
    private var recordHistory: (@MainActor (URL, LocalHistoryReason) async -> Void)?
    private var relocateHistory: (@MainActor (URL, URL) async -> Void)?
    private var relocateOpenDocuments: (@MainActor (URL, URL) -> Void)?
    private var closeDocuments: (@MainActor (URL) -> Void)?
    private var processExternalChanges: (@MainActor ([URL]) -> Bool)?
    private var notifyWorkspaceFileChanges: (@MainActor ([WorkspaceFileChange]) -> Void)?
    private var reloadProjectServices: (@MainActor () async -> Void)?
    private var refreshGit: (@MainActor () async -> Void)?
    private var updateHistoryVisibilityRules: (@MainActor (FileVisibilityRules) async -> Void)?
    private var onSnapshotLoaded: (@MainActor (WorkspaceSnapshot, Bool) async -> Void)?
    private var warmSearchIndex: (@MainActor (URL, FileVisibilityRules) -> Void)?
    private var updateSearchIndex: (@MainActor (URL, [String], FileVisibilityRules) async -> Void)?
    private var invalidateSearchIndex: (@MainActor (URL, FileVisibilityRules) -> Void)?

    package init(
        operations: any WorkspaceOperations,
        fileOperations: any WorkspaceFileOperations,
        gitWatchContextProvider: any GitWatchContextProviding,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        workspaceSessionStore: any WorkspaceSessionStoring,
        directoryMarkStore: any WorkspaceDirectoryMarkStoring = EmptyWorkspaceDirectoryMarkStore(),
        observationDelay: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.operations = operations
        self.fileOperations = fileOperations
        self.gitWatchContextProvider = gitWatchContextProvider
        self.directoryWatcherFactory = directoryWatcherFactory
        self.observationDelay = observationDelay ?? { try await Task.sleep(for: $0) }
        self.workspaceSessionStore = workspaceSessionStore
        self.directoryMarkStore = directoryMarkStore
        self.directoryMarkPersistence = WorkspaceDirectoryMarkPersistence(store: directoryMarkStore)
    }

    package func configureProjection(
        documentsProvider: @escaping @MainActor () -> [WorkspaceDocumentState],
        activeDocumentProvider: @escaping @MainActor () -> WorkspaceDocumentState?,
        selectedSidebarProvider: @escaping @MainActor () -> String,
        setSelectedSidebar: @escaping @MainActor (String) -> Void,
        restoreSession: @escaping @MainActor (WorkspaceSession, [URL]) async -> Void,
        openFile: @escaping @MainActor (URL) -> Void,
        notify: @escaping @MainActor (String) -> Void,
        recordHistory: @escaping @MainActor (URL, LocalHistoryReason) async -> Void,
        relocateHistory: @escaping @MainActor (URL, URL) async -> Void,
        relocateOpenDocuments: @escaping @MainActor (URL, URL) -> Void,
        closeDocuments: @escaping @MainActor (URL) -> Void,
        processExternalChanges: @escaping @MainActor ([URL]) -> Bool,
        notifyWorkspaceFileChanges: @escaping @MainActor ([WorkspaceFileChange]) -> Void = { _ in },
        reloadProjectServices: @escaping @MainActor () async -> Void,
        refreshGit: @escaping @MainActor () async -> Void,
        updateHistoryVisibilityRules: @escaping @MainActor (FileVisibilityRules) async -> Void,
        onSnapshotLoaded: @escaping @MainActor (WorkspaceSnapshot, Bool) async -> Void,
        warmSearchIndex: @escaping @MainActor (URL, FileVisibilityRules) -> Void,
        updateSearchIndex: @escaping @MainActor (URL, [String], FileVisibilityRules) async -> Void,
        invalidateSearchIndex: @escaping @MainActor (URL, FileVisibilityRules) -> Void
    ) {
        self.documentsProvider = documentsProvider
        self.activeDocumentProvider = activeDocumentProvider
        self.selectedSidebarProvider = selectedSidebarProvider
        self.setSelectedSidebar = setSelectedSidebar
        self.restoreSession = restoreSession
        self.openFile = openFile
        self.notify = notify
        self.recordHistory = recordHistory
        self.relocateHistory = relocateHistory
        self.relocateOpenDocuments = relocateOpenDocuments
        self.closeDocuments = closeDocuments
        self.processExternalChanges = processExternalChanges
        self.notifyWorkspaceFileChanges = notifyWorkspaceFileChanges
        self.reloadProjectServices = reloadProjectServices
        self.refreshGit = refreshGit
        self.updateHistoryVisibilityRules = updateHistoryVisibilityRules
        self.onSnapshotLoaded = onSnapshotLoaded
        self.warmSearchIndex = warmSearchIndex
        self.updateSearchIndex = updateSearchIndex
        self.invalidateSearchIndex = invalidateSearchIndex
    }

    package var hasSnapshot: Bool {
        rootNode != nil || !projectFiles.isEmpty
    }

    package var hasActiveModuleResources: Bool {
        directoryWatcher != nil
            || refreshTask != nil
            || gitRefreshTask != nil
            || recoveryTask != nil
            || visibilityRulesRefreshTask != nil
            || workspaceSessionPersistenceTask != nil
    }

    package func prepareForModuleRelease() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        watchConfiguration = nil
        refreshTask?.cancel()
        refreshTask = nil
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        visibilityRulesRefreshTask?.cancel()
        visibilityRulesRefreshTask = nil
        workspaceSessionPersistenceTask?.cancel()
        workspaceSessionPersistenceTask = nil
        pendingExternalPaths.removeAll()
        pendingGitRefresh = false
        pendingFullRescan = false
        pendingWatchRootsChanged = false
        isGitRefreshRunning = false
        externalRefreshGeneration += 1
        gitRefreshGeneration += 1
        gitOperationFreezeDepth = 0
    }

    package func reset() {
        workspaceGeneration &+= 1
        directoryMarkRevision &+= 1
        if let workspaceURL {
            scheduleSearchIndexInvalidation(at: workspaceURL, rules: visibilityRules)
        }
        directoryWatcher?.stop()
        directoryWatcher = nil
        watchConfiguration = nil
        refreshTask?.cancel()
        gitRefreshTask?.cancel()
        recoveryTask?.cancel()
        visibilityRulesRefreshTask?.cancel()
        workspaceSessionPersistenceTask?.cancel()
        pendingExternalPaths.removeAll()
        pendingGitRefresh = false
        pendingFullRescan = false
        pendingWatchRootsChanged = false
        isGitRefreshRunning = false
        externalRefreshGeneration += 1
        gitRefreshGeneration += 1
        gitOperationFreezeDepth = 0
        workspaceURL = nil
        hasRestoredWorkspaceSession = false
        rootNode = nil
        directoryMarks = [:]
        projectFiles = []
        appliedSnapshot = nil
        isLoadingWorkspace = false
        isRefreshingWorkspace = false
        loadErrorMessage = nil
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
    }

    deinit {
        directoryWatcher?.stop()
        refreshTask?.cancel()
        gitRefreshTask?.cancel()
        recoveryTask?.cancel()
        visibilityRulesRefreshTask?.cancel()
        workspaceSessionPersistenceTask?.cancel()
    }

    package func beginWorkspace(at url: URL, visibilityRules: FileVisibilityRules) {
        workspaceGeneration &+= 1
        directoryMarkRevision &+= 1
        workspaceURL = url.standardizedFileURL
        do {
            directoryMarks = try directoryMarkStore.loadDirectoryMarks(for: url)
        } catch {
            directoryMarks = [:]
            notify?("Could not read directory marks: \(error.localizedDescription)")
        }
        self.visibilityRules = visibilityRules
        hasRestoredWorkspaceSession = false
        pendingExternalPaths.removeAll()
        pendingGitRefresh = false
        pendingFullRescan = false
        pendingWatchRootsChanged = false
        externalRefreshGeneration += 1
        gitRefreshGeneration += 1
        startWatching(
            DirectoryWatchConfiguration(workspaceRoot: url, gitContext: nil),
            visibilityRules: visibilityRules
        )
    }

    /// Temporarily prevents FSEvents callbacks from making the workspace observe
    /// Git's intermediate index/worktree states. Nested calls are supported so a
    /// high-level workflow can contain several Git commands safely.
    package func beginGitOperationFreeze() {
        gitOperationFreezeDepth += 1
        refreshTask?.cancel()
        refreshTask = nil
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        externalRefreshGeneration += 1
        gitRefreshGeneration += 1
    }

    /// Flushes accumulated workspace and Git events after the outermost Git operation.
    package func endGitOperationFreeze() async {
        guard gitOperationFreezeDepth > 0 else { return }
        gitOperationFreezeDepth -= 1
        guard gitOperationFreezeDepth == 0, let workspaceURL else { return }

        if pendingWatchRootsChanged || pendingFullRescan {
            await applyPendingRecovery(at: workspaceURL)
            return
        }
        if !pendingExternalPaths.isEmpty {
            let changedPaths = Array(pendingExternalPaths)
            pendingExternalPaths.removeAll()
            externalRefreshGeneration += 1
            await applyExternalRefresh(changedPaths, at: workspaceURL)
            return
        }
        if pendingGitRefresh {
            await drainGitRefreshes()
        }
    }

    package func rebuild(
        at workspaceURL: URL,
        rules: FileVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> WorkspaceRebuildResult {
        let isInitialLoad = !hasSnapshot
        if isInitialLoad {
            isLoadingWorkspace = true
            loadErrorMessage = nil
        } else {
            isRefreshingWorkspace = true
        }

        let operations = self.operations
        let snapshot = await Task.detached(priority: .userInitiated) {
            operations.snapshot(at: workspaceURL, visibilityRules: rules)
        }.value

        guard isCurrent() else {
            if isInitialLoad {
                isLoadingWorkspace = false
            } else {
                isRefreshingWorkspace = false
            }
            return .stale
        }
        guard let snapshot else {
            if isInitialLoad {
                isLoadingWorkspace = false
            } else {
                isRefreshingWorkspace = false
            }
            if isInitialLoad {
                loadErrorMessage = "Could not read the project folder. Check that it still exists and that Lithe has permission to access it."
            }
            return .unavailable
        }
        loadErrorMessage = nil
        rootNode = snapshot.root
        projectFiles = snapshot.files
        appliedSnapshot = snapshot
        scheduleSearchIndexWarm(at: workspaceURL, rules: rules)

        // The tree is usable as soon as the shared snapshot is ready. Service
        // preparation below may involve Git, Java, and local history work.
        if isInitialLoad {
            isLoadingWorkspace = false
        } else {
            isRefreshingWorkspace = false
        }

        if !hasRestoredWorkspaceSession {
            if let restoreSession, let session = workspaceSessionStore.load(for: workspaceURL) {
                await restoreSession(session, snapshot.files)
            }
            guard isCurrent() else { return .stale }
            hasRestoredWorkspaceSession = true
        }
        guard isCurrent() else { return .stale }
        await updateWatchConfiguration()
        guard isCurrent() else { return .stale }
        await onSnapshotLoaded?(snapshot, isInitialLoad)
        guard isCurrent() else { return .stale }
        await requestGitRefreshNow()
        if pendingFullRescan || pendingWatchRootsChanged {
            scheduleRecovery()
        }
        return .loaded(snapshot)
    }

    package func refreshCurrent() async {
        guard let workspaceURL, !isLoadingWorkspace, !isRefreshingWorkspace else { return }
        refreshTask?.cancel()
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        let generation = workspaceGeneration
        _ = await rebuild(
            at: workspaceURL,
            rules: visibilityRules,
            isCurrent: { [weak self] in
                self?.workspaceURL == workspaceURL && self?.workspaceGeneration == generation
            }
        )
    }

    package func markDirectory(_ url: URL, as mark: WorkspaceDirectoryMark) async {
        guard !isPerformingProjectItemOperation,
              let workspaceURL,
              let relativePath = Self.relativePath(for: url, in: workspaceURL) else { return }
        let workspaceGeneration = self.workspaceGeneration
        let previousMarks = directoryMarks
        var updatedMarks = directoryMarks
        updatedMarks[relativePath] = mark
        guard updatedMarks != previousMarks else { return }

        directoryMarkRevision &+= 1
        let revision = directoryMarkRevision
        directoryMarks = updatedMarks

        let saveError = await directoryMarkPersistence.save(updatedMarks, for: workspaceURL)
        guard self.workspaceURL == workspaceURL,
              self.workspaceGeneration == workspaceGeneration else { return }
        if let saveError {
            if directoryMarkRevision == revision {
                directoryMarks = previousMarks
            }
            notify?("Could not update directory mark: \(saveError)")
        }
    }

    private static func relativePath(for url: URL, in workspaceURL: URL) -> String? {
        let rootPath = workspaceURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        if targetPath == rootPath { return "." }
        guard targetPath.hasPrefix(rootPath + "/") else { return nil }
        return String(targetPath.dropFirst(rootPath.count + 1))
    }

    package func startWatchingCurrent() {
        guard let workspaceURL else { return }
        startWatching(
            watchConfiguration ?? DirectoryWatchConfiguration(workspaceRoot: workspaceURL, gitContext: nil),
            visibilityRules: visibilityRules
        )
    }

    package func resumeObservationAfterActivation() async {
        guard workspaceURL != nil else { return }
        await updateWatchConfiguration(forceRebuild: true)
        await requestGitRefreshNow()
    }

    package func contains(_ url: URL) -> Bool {
        isWorkspaceURL(url)
    }

    package func fileExists(at url: URL) -> Bool {
        fileOperations.fileExists(at: url)
    }

    package func updateVisibilityRules(_ rules: FileVisibilityRules) {
        visibilityRulesRefreshTask?.cancel()
        refreshTask?.cancel()
        guard let workspaceURL else { return }
        visibilityRules = rules
        visibilityRulesRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isLoadingWorkspace, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.workspaceURL == workspaceURL else { return }
            await self.updateHistoryVisibilityRules?(rules)
            _ = await self.rebuild(
                at: workspaceURL,
                rules: rules,
                isCurrent: { [weak self] in self?.workspaceURL == workspaceURL }
            )
        }
    }

    package func persistWorkspaceSession(for explicitWorkspaceURL: URL? = nil) {
        guard let targetURL = explicitWorkspaceURL ?? workspaceURL,
              let documentsProvider,
              let activeDocumentProvider,
              let selectedSidebarProvider else { return }
        workspaceSessionStore.save(
            WorkspaceSession(
                openPaths: documentsProvider()
                    .filter { $0.url.isFileURL }
                    .map { $0.url.standardizedFileURL.path },
                activePath: activeDocumentProvider().flatMap {
                    $0.url.isFileURL ? $0.url.standardizedFileURL.path : nil
                },
                selectedSidebar: selectedSidebarProvider()
            ),
            for: targetURL
        )
    }

    package func scheduleWorkspaceSessionPersistence() {
        workspaceSessionPersistenceTask?.cancel()
        workspaceSessionPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.persistWorkspaceSession()
        }
    }

    package func requestCreateFile(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createFile, targetURL: directory)
    }

    package func requestCreateDirectory(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createDirectory, targetURL: directory)
    }

    package func requestRenameProjectItem(at url: URL) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .rename, targetURL: url)
    }

    package func cancelProjectItemEdit() {
        projectItemEditRequest = nil
    }

    package func performProjectItemEdit(named rawName: String) async {
        guard let request = projectItemEditRequest else { return }
        guard let operationWorkspaceURL = workspaceURL else { return }
        let operationWorkspaceGeneration = workspaceGeneration
        let operationDirectoryMarks = directoryMarks
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProjectItemName(name) else {
            notify?("Use a valid file or directory name")
            return
        }
        projectItemEditRequest = nil
        isPerformingProjectItemOperation = true
        let destination: URL
        switch request.kind {
        case .createFile, .createDirectory:
            destination = request.targetURL.appendingPathComponent(name)
        case .rename:
            destination = request.targetURL.deletingLastPathComponent().appendingPathComponent(name)
        }

        var relocatedHistoryFiles: [(URL, URL)] = []
        if request.kind == .rename {
            let sourcePath = request.targetURL.standardizedFileURL.path
            await recordHistory?(request.targetURL, .beforeRename)
            relocatedHistoryFiles = projectFiles
                .filter { urlContains(request.targetURL, child: $0) }
                .map { source in
                    let suffix = String(source.standardizedFileURL.path.dropFirst(sourcePath.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return (source, suffix.isEmpty ? destination : destination.appendingPathComponent(suffix))
                }
        }

        let fileOperations = self.fileOperations
        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            guard !fileOperations.fileExists(at: destination) else {
                return "An item named '\(name)' already exists"
            }
            do {
                switch request.kind {
                case .createFile:
                    try fileOperations.createFile(at: destination)
                case .createDirectory:
                    try fileOperations.createDirectory(at: destination, withIntermediateDirectories: false)
                case .rename:
                    try fileOperations.moveItem(at: request.targetURL, to: destination)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        isPerformingProjectItemOperation = false
        if let errorMessage {
            notify?(errorMessage)
            return
        }
        if request.kind == .rename {
            let marksToMigrate: [String: WorkspaceDirectoryMark]
            if workspaceURL == operationWorkspaceURL,
               workspaceGeneration == operationWorkspaceGeneration {
                marksToMigrate = directoryMarks
            } else {
                marksToMigrate = operationDirectoryMarks
            }
            let migratedMarks = Self.directoryMarks(
                marksToMigrate,
                moving: request.targetURL,
                to: destination,
                in: operationWorkspaceURL
            )
            await persistDirectoryMarksAfterFileOperation(
                migratedMarks,
                previousMarks: marksToMigrate,
                workspaceURL: operationWorkspaceURL,
                workspaceGeneration: operationWorkspaceGeneration
            )
            guard workspaceURL == operationWorkspaceURL,
                  workspaceGeneration == operationWorkspaceGeneration else { return }
            for (source, destination) in relocatedHistoryFiles {
                await relocateHistory?(source, destination)
            }
            relocateOpenDocuments?(request.targetURL, destination)
            notify?("Renamed to \(name)")
        } else if request.kind == .createFile {
            guard workspaceURL == operationWorkspaceURL,
                  workspaceGeneration == operationWorkspaceGeneration else { return }
            notify?("Created \(name)")
        } else {
            guard workspaceURL == operationWorkspaceURL,
                  workspaceGeneration == operationWorkspaceGeneration else { return }
            notify?("Created directory \(name)")
        }
        await refreshCurrent()
        if request.kind == .createFile { openFile?(destination) }
    }

    package func duplicateProjectItem(at sourceURL: URL) async {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(sourceURL),
              sourceURL.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        isPerformingProjectItemOperation = true
        let destination = availableDuplicateURL(for: sourceURL)
        let fileOperations = self.fileOperations
        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try fileOperations.copyItem(at: sourceURL, to: destination)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        isPerformingProjectItemOperation = false
        if let errorMessage {
            notify?(errorMessage)
        } else {
            notify?("Duplicated \(sourceURL.lastPathComponent)")
            await refreshCurrent()
        }
    }

    package func requestDeleteProjectItem(at url: URL, isDirectory: Bool) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        if documentsProvider?().contains(where: { $0.isDirty && urlContains(url, child: $0.url) }) == true {
            notify?("Save or discard unsaved files before deleting this item")
            return
        }
        pendingProjectItemDeletion = ProjectItemDeletionRequest(url: url, isDirectory: isDirectory)
    }

    package func cancelProjectItemDeletion() {
        pendingProjectItemDeletion = nil
    }

    package func confirmProjectItemDeletion(_ request: ProjectItemDeletionRequest) async {
        if pendingProjectItemDeletion?.id == request.id {
            pendingProjectItemDeletion = nil
        }
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(request.url),
              request.url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        guard let operationWorkspaceURL = workspaceURL else { return }
        let operationWorkspaceGeneration = workspaceGeneration
        let operationDirectoryMarks = directoryMarks
        isPerformingProjectItemOperation = true
        // Update the visible tree before waiting for the native Trash operation.
        // A failed operation reloads the disk snapshot below to restore the item.
        removeProjectItemFromSnapshot(request.url)
        // The system Trash is the recovery boundary. Recording every descendant
        // first would make deleting a directory scale with its entire file tree.
        let fileOperations = self.fileOperations
        let errorMessage = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let errorMessage: String?
                do {
                    try fileOperations.trashItem(at: request.url)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                continuation.resume(returning: errorMessage)
            }
        }
        isPerformingProjectItemOperation = false
        if let errorMessage {
            notify?(errorMessage)
            await refreshCurrent()
            return
        }
        if request.isDirectory {
            let marksToRemoveFrom: [String: WorkspaceDirectoryMark]
            if workspaceURL == operationWorkspaceURL,
               workspaceGeneration == operationWorkspaceGeneration {
                marksToRemoveFrom = directoryMarks
            } else {
                marksToRemoveFrom = operationDirectoryMarks
            }
            let remainingMarks = Self.directoryMarks(
                marksToRemoveFrom,
                removing: request.url,
                in: operationWorkspaceURL
            )
            await persistDirectoryMarksAfterFileOperation(
                remainingMarks,
                previousMarks: marksToRemoveFrom,
                workspaceURL: operationWorkspaceURL,
                workspaceGeneration: operationWorkspaceGeneration
            )
        }
        guard workspaceURL == operationWorkspaceURL,
              workspaceGeneration == operationWorkspaceGeneration else { return }
        closeDocuments?(request.url)
        notify?("Moved \(request.url.lastPathComponent) to Trash")
        await refreshCurrent()
    }

    package func readFile(at workspaceURL: URL, relativePath: String) async -> String? {
        let operations = self.operations
        return await Task.detached(priority: .userInitiated) {
            operations.readFile(at: workspaceURL, relativePath: relativePath)
        }.value
    }

    private func persistDirectoryMarksAfterFileOperation(
        _ updatedMarks: [String: WorkspaceDirectoryMark],
        previousMarks: [String: WorkspaceDirectoryMark],
        workspaceURL: URL,
        workspaceGeneration: Int
    ) async {
        guard updatedMarks != previousMarks else { return }
        let isCurrentWorkspace = self.workspaceURL == workspaceURL
            && self.workspaceGeneration == workspaceGeneration
        if isCurrentWorkspace {
            directoryMarkRevision &+= 1
            directoryMarks = updatedMarks
        }

        let saveError = await directoryMarkPersistence.save(updatedMarks, for: workspaceURL)
        guard let saveError,
              self.workspaceURL == workspaceURL,
              self.workspaceGeneration == workspaceGeneration else { return }
        // The filesystem operation has already succeeded, so rolling the UI back
        // would restore paths that no longer exist. Keep the in-memory state and
        // surface that only preference persistence failed.
        notify?("Could not update directory marks after the file operation: \(saveError)")
    }

    private static func directoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        moving sourceURL: URL,
        to destinationURL: URL,
        in workspaceURL: URL
    ) -> [String: WorkspaceDirectoryMark] {
        guard let sourcePath = relativePath(for: sourceURL, in: workspaceURL),
              let destinationPath = relativePath(for: destinationURL, in: workspaceURL) else {
            return marks
        }
        let sourcePrefix = sourcePath + "/"
        var updatedMarks = marks.filter { key, _ in
            key != sourcePath && !key.hasPrefix(sourcePrefix)
        }
        for (key, mark) in marks where key == sourcePath || key.hasPrefix(sourcePrefix) {
            let suffix = String(key.dropFirst(sourcePath.count))
            updatedMarks[destinationPath + suffix] = mark
        }
        return updatedMarks
    }

    private static func directoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        removing targetURL: URL,
        in workspaceURL: URL
    ) -> [String: WorkspaceDirectoryMark] {
        guard let targetPath = relativePath(for: targetURL, in: workspaceURL) else { return marks }
        let targetPrefix = targetPath + "/"
        return marks.filter { key, _ in
            key != targetPath && !key.hasPrefix(targetPrefix)
        }
    }

    private func startWatching(
        _ configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules
    ) {
        directoryWatcher?.stop()
        watchConfiguration = configuration
        directoryWatcher = directoryWatcherFactory.make(
            configuration: configuration,
            visibilityRules: visibilityRules
        ) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.scheduleDirectoryChange(batch)
            }
        }
        directoryWatcher?.start()
    }

    private func updateWatchConfiguration(forceRebuild: Bool = false) async {
        guard let workspaceURL else { return }
        let generation = workspaceGeneration
        let context = await gitWatchContextProvider.watchContext(for: workspaceURL)
        guard self.workspaceURL == workspaceURL,
              self.workspaceGeneration == generation else { return }
        let configuration = DirectoryWatchConfiguration(
            workspaceRoot: workspaceURL,
            gitContext: context
        )
        guard forceRebuild || configuration != watchConfiguration || directoryWatcher == nil else {
            return
        }
        startWatching(configuration, visibilityRules: visibilityRules)
    }

    private func scheduleDirectoryChange(_ batch: DirectoryChangeBatch) {
        guard !batch.isEmpty else { return }
        if !batch.workspacePaths.isEmpty {
            pendingExternalPaths.formUnion(batch.workspacePaths)
            externalRefreshGeneration += 1
        }
        if batch.watchRootsChanged || batch.requiresFullRescan {
            pendingWatchRootsChanged = pendingWatchRootsChanged || batch.watchRootsChanged
            pendingFullRescan = pendingFullRescan || batch.requiresFullRescan
            pendingGitRefresh = true
            refreshTask?.cancel()
            refreshTask = nil
            gitRefreshTask?.cancel()
            gitRefreshTask = nil
            scheduleRecovery()
            return
        }

        if !batch.workspacePaths.isEmpty {
            if batch.gitStateMayHaveChanged { pendingGitRefresh = true }
            schedulePendingExternalRefresh()
        } else if batch.gitStateMayHaveChanged {
            scheduleGitRefresh()
        }
    }

    private func scheduleRecovery() {
        guard gitOperationFreezeDepth == 0 else {
            recoveryTask?.cancel()
            recoveryTask = nil
            return
        }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self, observationDelay] in
            do { try await observationDelay(.milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled, let self, let workspaceURL = self.workspaceURL else { return }
            await self.applyPendingRecovery(at: workspaceURL)
        }
    }

    private func applyPendingRecovery(at workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL else { return }
        guard gitOperationFreezeDepth == 0 else { return }
        if isLoadingWorkspace || isRefreshingWorkspace {
            scheduleRecovery()
            return
        }

        let rootsChanged = pendingWatchRootsChanged
        let fullRescan = pendingFullRescan
        pendingWatchRootsChanged = false
        pendingFullRescan = false
        if rootsChanged {
            await updateWatchConfiguration(forceRebuild: true)
        }
        if fullRescan {
            await refreshCurrent()
        } else if !pendingExternalPaths.isEmpty {
            let changedPaths = Array(pendingExternalPaths)
            pendingExternalPaths.removeAll()
            externalRefreshGeneration += 1
            refreshTask?.cancel()
            refreshTask = nil
            await applyExternalRefresh(changedPaths, at: workspaceURL)
        }
        if pendingGitRefresh {
            await drainGitRefreshes()
        }
    }

    private func scheduleExternalRefresh(paths: [String]) {
        guard !paths.isEmpty else { return }
        pendingExternalPaths.formUnion(paths)
        externalRefreshGeneration += 1
        schedulePendingExternalRefresh()
    }

    private func schedulePendingExternalRefresh() {
        guard !pendingExternalPaths.isEmpty else { return }
        guard gitOperationFreezeDepth == 0 else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        let generation = externalRefreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self, observationDelay] in
            do { try await observationDelay(.milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled,
                  let self,
                  self.externalRefreshGeneration == generation,
                  let workspaceURL = self.workspaceURL else { return }
            let changedPaths = Array(self.pendingExternalPaths)
            self.pendingExternalPaths.removeAll()
            await self.applyExternalRefresh(changedPaths, at: workspaceURL)
        }
    }

    private func scheduleGitRefresh() {
        pendingGitRefresh = true
        gitRefreshGeneration += 1
        guard gitOperationFreezeDepth == 0, !isGitRefreshRunning else { return }
        let generation = gitRefreshGeneration
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { @MainActor [weak self, observationDelay] in
            do { try await observationDelay(.milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled,
                  let self,
                  self.gitRefreshGeneration == generation else { return }
            await self.drainGitRefreshes()
        }
    }

    private func requestGitRefreshNow() async {
        pendingGitRefresh = true
        gitRefreshGeneration += 1
        gitRefreshTask?.cancel()
        gitRefreshTask = nil
        await drainGitRefreshes()
    }

    private func drainGitRefreshes() async {
        guard gitOperationFreezeDepth == 0, !isGitRefreshRunning else { return }
        isGitRefreshRunning = true
        while pendingGitRefresh, gitOperationFreezeDepth == 0 {
            pendingGitRefresh = false
            await refreshGit?()
        }
        isGitRefreshRunning = false
    }

    private func applyExternalRefresh(_ paths: [String], at workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL else { return }
        guard gitOperationFreezeDepth == 0 else {
            pendingExternalPaths.formUnion(paths)
            pendingGitRefresh = true
            return
        }
        if isLoadingWorkspace || isRefreshingWorkspace {
            scheduleExternalRefresh(paths: paths)
            return
        }
        let changedURLs = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter(isWorkspaceURL)
            .reduce(into: [URL]()) { values, url in
                if !values.contains(url) { values.append(url) }
            }
            .sorted { $0.path < $1.path }
        let conflictDetected = processExternalChanges?(changedURLs) ?? false
        if conflictDetected { notify?("External edits conflict with unsaved changes") }

        let knownPaths = Set(projectFiles.map { $0.standardizedFileURL.path })
        let fileChanges = changedURLs.compactMap { url -> WorkspaceFileChange? in
            let wasKnown = knownPaths.contains(url.path)
            if fileOperations.fileExists(at: url) {
                return WorkspaceFileChange(
                    fileURL: url,
                    kind: wasKnown ? .changed : .created
                )
            }
            return wasKnown ? WorkspaceFileChange(fileURL: url, kind: .deleted) : nil
        }
        if !fileChanges.isEmpty {
            notifyWorkspaceFileChanges?(fileChanges)
        }

        let requiresWorkspaceSnapshot = changedURLs.contains { url in
            let wasKnownFile = projectFiles.contains { $0.standardizedFileURL.path == url.path }
            guard fileOperations.fileExists(at: url) else { return wasKnownFile }
            return fileOperations.isDirectory(at: url) || !wasKnownFile
        }
        if requiresWorkspaceSnapshot {
            await refreshCurrent()
            return
        }
        await updateSearchIndex(
            at: workspaceURL,
            changedPaths: changedURLs.map(\.path),
            rules: visibilityRules
        )
        let requiresProjectServiceReload = changedURLs.contains { url in
            let name = url.lastPathComponent.lowercased()
            let isLitheConfiguration = url.pathExtension.lowercased() == "json"
                && url.path.hasPrefix(workspaceURL.appendingPathComponent(".lithe").path + "/")
            return isLitheConfiguration
                || name == "pom.xml" || name == "build.gradle" || name == "build.gradle.kts"
        }
        if requiresProjectServiceReload { await reloadProjectServices?() }
        await requestGitRefreshNow()
    }

    private func scheduleSearchIndexWarm(at workspaceURL: URL, rules: FileVisibilityRules) {
        warmSearchIndex?(workspaceURL, rules)
    }

    private func scheduleSearchIndexInvalidation(at workspaceURL: URL, rules: FileVisibilityRules) {
        invalidateSearchIndex?(workspaceURL, rules)
    }

    private func updateSearchIndex(
        at workspaceURL: URL,
        changedPaths: [String],
        rules: FileVisibilityRules
    ) async {
        guard !changedPaths.isEmpty else { return }
        await updateSearchIndex?(workspaceURL, changedPaths, rules)
    }

    private func isWorkspaceURL(_ url: URL) -> Bool {
        guard let workspaceURL else { return false }
        return urlContains(workspaceURL, child: url)
    }

    private func urlContains(_ parent: URL, child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private func removeProjectItemFromSnapshot(_ targetURL: URL) {
        projectFiles.removeAll { urlContains(targetURL, child: $0) }
        rootNode = rootNode.flatMap { removingProjectItem(targetURL, from: $0) }
    }

    private func removingProjectItem(_ targetURL: URL, from node: FileNode) -> FileNode? {
        guard node.url.standardizedFileURL != targetURL.standardizedFileURL else { return nil }
        guard let children = node.children else { return node }
        return FileNode(
            url: node.url,
            isDirectory: node.isDirectory,
            children: children.compactMap { removingProjectItem(targetURL, from: $0) },
            collapsedAncestorPaths: node.collapsedAncestorPaths,
            isInsideSourceRoot: node.isInsideSourceRoot
        )
    }

    private func availableDuplicateURL(for sourceURL: URL) -> URL {
        let parent = sourceURL.deletingLastPathComponent()
        let fileExtension = sourceURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? sourceURL.lastPathComponent
            : sourceURL.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = fileExtension.isEmpty
                ? "\(baseName)\(suffix)"
                : "\(baseName)\(suffix).\(fileExtension)"
            let candidate = parent.appendingPathComponent(name)
            if !fileOperations.fileExists(at: candidate) { return candidate }
            index += 1
        }
    }

    private func isValidProjectItemName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":")
    }
}

/// Serializes preference writes without blocking the cooperative executor.
private final class WorkspaceDirectoryMarkPersistence: @unchecked Sendable {
    private let store: any WorkspaceDirectoryMarkStoring
    private let queue = DispatchQueue(label: "dev.lithe.workspace-directory-marks")

    init(store: any WorkspaceDirectoryMarkStoring) {
        self.store = store
    }

    func save(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [store] in
                do {
                    try store.saveDirectoryMarks(marks, for: workspaceURL)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        }
    }
}
