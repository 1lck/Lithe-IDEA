import Combine
import Foundation

enum WorkspaceRebuildResult: Sendable {
    case loaded(WorkspaceSnapshot)
    case unavailable
    case stale
}

/// Owns the workspace snapshot and delegates scanning and text reads to Core.
@MainActor
final class WorkspaceFeatureModel: ObservableObject {
    @Published private(set) var rootNode: FileNode?
    @Published private(set) var projectFiles: [URL] = []
    @Published private(set) var isLoadingWorkspace = false
    @Published private(set) var isRefreshingWorkspace = false
    @Published var projectItemEditRequest: ProjectItemEditRequest?
    @Published var pendingProjectItemDeletion: ProjectItemDeletionRequest?
    @Published private(set) var isPerformingProjectItemOperation = false
    private(set) var gitOperationFreezeDepth = 0

    private let operations: any WorkspaceOperations
    private let fileOperations: any WorkspaceFileOperations
    private let directoryWatcherFactory: any DirectoryWatcherFactory
    private let workspaceSessionStore: WorkspaceSessionStore
    private var workspaceURL: URL?
    private var visibilityRules = FileVisibilityRules.default
    private var directoryWatcher: (any DirectoryChangeSource)?
    private var refreshTask: Task<Void, Never>?
    private var visibilityRulesRefreshTask: Task<Void, Never>?
    private var pendingExternalPaths: Set<String> = []
    private var externalRefreshGeneration = 0
    private var workspaceSessionPersistenceTask: Task<Void, Never>?
    private var hasRestoredWorkspaceSession = false

    private var documentsProvider: (@MainActor () -> [EditorDocument])?
    private var activeDocumentProvider: (@MainActor () -> EditorDocument?)?
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
    private var reloadProjectServices: (@MainActor () async -> Void)?
    private var refreshGit: (@MainActor () async -> Void)?
    private var updateHistoryVisibilityRules: (@MainActor (FileVisibilityRules) async -> Void)?
    private var onSnapshotLoaded: (@MainActor (WorkspaceSnapshot, Bool) async -> Void)?

    init(
        operations: any WorkspaceOperations,
        fileOperations: any WorkspaceFileOperations,
        directoryWatcherFactory: any DirectoryWatcherFactory,
        workspaceSessionStore: WorkspaceSessionStore
    ) {
        self.operations = operations
        self.fileOperations = fileOperations
        self.directoryWatcherFactory = directoryWatcherFactory
        self.workspaceSessionStore = workspaceSessionStore
    }

    func configure(
        documentsProvider: @escaping @MainActor () -> [EditorDocument],
        activeDocumentProvider: @escaping @MainActor () -> EditorDocument?,
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
        reloadProjectServices: @escaping @MainActor () async -> Void,
        refreshGit: @escaping @MainActor () async -> Void,
        updateHistoryVisibilityRules: @escaping @MainActor (FileVisibilityRules) async -> Void,
        onSnapshotLoaded: @escaping @MainActor (WorkspaceSnapshot, Bool) async -> Void
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
        self.reloadProjectServices = reloadProjectServices
        self.refreshGit = refreshGit
        self.updateHistoryVisibilityRules = updateHistoryVisibilityRules
        self.onSnapshotLoaded = onSnapshotLoaded
    }

    var hasSnapshot: Bool {
        rootNode != nil || !projectFiles.isEmpty
    }

    func reset() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        refreshTask?.cancel()
        visibilityRulesRefreshTask?.cancel()
        workspaceSessionPersistenceTask?.cancel()
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        gitOperationFreezeDepth = 0
        workspaceURL = nil
        hasRestoredWorkspaceSession = false
        rootNode = nil
        projectFiles = []
        isLoadingWorkspace = false
        isRefreshingWorkspace = false
        projectItemEditRequest = nil
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = false
    }

    deinit {
        directoryWatcher?.stop()
        refreshTask?.cancel()
        visibilityRulesRefreshTask?.cancel()
        workspaceSessionPersistenceTask?.cancel()
    }

    func beginWorkspace(at url: URL, visibilityRules: FileVisibilityRules) {
        workspaceURL = url.standardizedFileURL
        self.visibilityRules = visibilityRules
        hasRestoredWorkspaceSession = false
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
    }

    /// Temporarily prevents FSEvents callbacks from making the workspace observe
    /// Git's intermediate index/worktree states. Nested calls are supported so a
    /// high-level workflow can contain several Git commands safely.
    func beginGitOperationFreeze() {
        gitOperationFreezeDepth += 1
        refreshTask?.cancel()
        refreshTask = nil
        externalRefreshGeneration += 1
    }

    /// Flushes all watcher paths once the outermost Git operation completes.
    /// The flush is intentionally immediate: GitFeatureModel has already
    /// refreshed its own status, so this is the one place where the editor,
    /// workspace tree, history, and project services catch up together.
    func endGitOperationFreeze() async {
        guard gitOperationFreezeDepth > 0 else { return }
        gitOperationFreezeDepth -= 1
        guard gitOperationFreezeDepth == 0,
              let workspaceURL,
              !pendingExternalPaths.isEmpty else { return }
        let changedPaths = Array(pendingExternalPaths)
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        await applyExternalRefresh(changedPaths, at: workspaceURL)
    }

    func rebuild(
        at workspaceURL: URL,
        rules: FileVisibilityRules,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> WorkspaceRebuildResult {
        let isInitialLoad = !hasSnapshot
        if isInitialLoad {
            isLoadingWorkspace = true
        } else {
            isRefreshingWorkspace = true
        }

        let operations = self.operations
        let snapshot = await Task.detached(priority: .userInitiated) {
            operations.snapshot(at: workspaceURL, visibilityRules: rules)
        }.value

        guard isCurrent() else { return .stale }
        guard let snapshot else {
            if isInitialLoad {
                isLoadingWorkspace = false
            } else {
                isRefreshingWorkspace = false
            }
            return .unavailable
        }
        rootNode = snapshot.root
        projectFiles = snapshot.files

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
            hasRestoredWorkspaceSession = true
        }
        await onSnapshotLoaded?(snapshot, isInitialLoad)
        if self.visibilityRules == rules {
            startWatching(workspaceURL, visibilityRules: rules)
        }
        return .loaded(snapshot)
    }

    func refreshCurrent() async {
        guard let workspaceURL, !isLoadingWorkspace, !isRefreshingWorkspace else { return }
        refreshTask?.cancel()
        pendingExternalPaths.removeAll()
        externalRefreshGeneration += 1
        _ = await rebuild(
            at: workspaceURL,
            rules: visibilityRules,
            isCurrent: { [weak self] in self?.workspaceURL == workspaceURL }
        )
    }

    func startWatchingCurrent() {
        guard let workspaceURL else { return }
        startWatching(workspaceURL, visibilityRules: visibilityRules)
    }

    func contains(_ url: URL) -> Bool {
        isWorkspaceURL(url)
    }

    func fileExists(at url: URL) -> Bool {
        fileOperations.fileExists(at: url)
    }

    func updateVisibilityRules(_ rules: FileVisibilityRules) {
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

    func persistWorkspaceSession(for explicitWorkspaceURL: URL? = nil) {
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

    func scheduleWorkspaceSessionPersistence() {
        workspaceSessionPersistenceTask?.cancel()
        workspaceSessionPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.persistWorkspaceSession()
        }
    }

    func requestCreateFile(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createFile, targetURL: directory)
    }

    func requestCreateDirectory(in directory: URL) {
        guard !isPerformingProjectItemOperation, isWorkspaceURL(directory) else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .createDirectory, targetURL: directory)
    }

    func requestRenameProjectItem(at url: URL) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        projectItemEditRequest = ProjectItemEditRequest(kind: .rename, targetURL: url)
    }

    func cancelProjectItemEdit() {
        projectItemEditRequest = nil
    }

    func performProjectItemEdit(named rawName: String) async {
        guard let request = projectItemEditRequest else { return }
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
            for (source, destination) in relocatedHistoryFiles {
                await relocateHistory?(source, destination)
            }
            relocateOpenDocuments?(request.targetURL, destination)
            notify?("Renamed to \(name)")
        } else if request.kind == .createFile {
            notify?("Created \(name)")
        } else {
            notify?("Created directory \(name)")
        }
        await refreshCurrent()
        if request.kind == .createFile { openFile?(destination) }
    }

    func duplicateProjectItem(at sourceURL: URL) async {
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

    func requestDeleteProjectItem(at url: URL, isDirectory: Bool) {
        guard !isPerformingProjectItemOperation,
              isWorkspaceURL(url),
              url.standardizedFileURL != workspaceURL?.standardizedFileURL else { return }
        if documentsProvider?().contains(where: { $0.isDirty && urlContains(url, child: $0.url) }) == true {
            notify?("Save or discard unsaved files before deleting this item")
            return
        }
        pendingProjectItemDeletion = ProjectItemDeletionRequest(url: url, isDirectory: isDirectory)
    }

    func cancelProjectItemDeletion() {
        pendingProjectItemDeletion = nil
    }

    func confirmProjectItemDeletion() async {
        guard let request = pendingProjectItemDeletion else { return }
        pendingProjectItemDeletion = nil
        isPerformingProjectItemOperation = true
        await recordHistory?(request.url, .beforeDelete)
        let fileOperations = self.fileOperations
        let errorMessage = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try fileOperations.trashItem(at: request.url)
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
        closeDocuments?(request.url)
        notify?("Moved \(request.url.lastPathComponent) to Trash")
        await refreshCurrent()
    }

    func readFile(at workspaceURL: URL, relativePath: String) async -> String? {
        let operations = self.operations
        return await Task.detached(priority: .userInitiated) {
            operations.readFile(at: workspaceURL, relativePath: relativePath)
        }.value
    }

    private func startWatching(_ url: URL, visibilityRules: FileVisibilityRules) {
        directoryWatcher?.stop()
        directoryWatcher = directoryWatcherFactory.make(
            root: url,
            visibilityRules: visibilityRules
        ) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.scheduleExternalRefresh(paths: paths)
            }
        }
        directoryWatcher?.start()
    }

    private func scheduleExternalRefresh(paths: [String]) {
        guard !paths.isEmpty else { return }
        pendingExternalPaths.formUnion(paths)
        externalRefreshGeneration += 1
        guard gitOperationFreezeDepth == 0 else {
            refreshTask?.cancel()
            refreshTask = nil
            return
        }
        let generation = externalRefreshGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled,
                  let self,
                  self.externalRefreshGeneration == generation,
                  let workspaceURL = self.workspaceURL else { return }
            let changedPaths = Array(self.pendingExternalPaths)
            self.pendingExternalPaths.removeAll()
            await self.applyExternalRefresh(changedPaths, at: workspaceURL)
        }
    }

    private func applyExternalRefresh(_ paths: [String], at workspaceURL: URL) async {
        guard self.workspaceURL == workspaceURL else { return }
        guard gitOperationFreezeDepth == 0 else {
            pendingExternalPaths.formUnion(paths)
            return
        }
        if isLoadingWorkspace || isRefreshingWorkspace {
            scheduleExternalRefresh(paths: paths)
            return
        }
        let changedURLs = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter(isWorkspaceURL)
        let conflictDetected = processExternalChanges?(changedURLs) ?? false
        if conflictDetected { notify?("External edits conflict with unsaved changes") }

        let requiresWorkspaceSnapshot = changedURLs.contains { url in
            let wasKnownFile = projectFiles.contains { $0.standardizedFileURL.path == url.path }
            guard fileOperations.fileExists(at: url) else { return wasKnownFile }
            return fileOperations.isDirectory(at: url) || !wasKnownFile
        }
        if requiresWorkspaceSnapshot {
            await refreshCurrent()
            return
        }
        let requiresProjectServiceReload = changedURLs.contains { url in
            let name = url.lastPathComponent.lowercased()
            let isLitheConfiguration = url.pathExtension.lowercased() == "json"
                && url.path.hasPrefix(workspaceURL.appendingPathComponent(".lithe").path + "/")
            return isLitheConfiguration
                || name == "pom.xml" || name == "build.gradle" || name == "build.gradle.kts"
                || url.pathExtension.lowercased() == "java"
        }
        if requiresProjectServiceReload { await reloadProjectServices?() }
        await refreshGit?()
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
