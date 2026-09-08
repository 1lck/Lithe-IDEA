import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Owns Git state and Git workflows while keeping the UI-specific panel state
/// in AppModel. Git command construction and parsing remain in GitService/Core.
@MainActor
package final class GitFeatureModel: ObservableObject {
    @Published package private(set) var gitChanges: [GitChange] = [] {
        didSet { gitTreeStatus = GitTreeStatusProjection(changes: gitChanges) }
    }
    package private(set) var gitTreeStatus = GitTreeStatusProjection(changes: [])
    @Published private var pendingStagingStates: [GitChange.ID: Bool] = [:]
    @Published package private(set) var gitStashes: [GitStash] = []
    @Published package private(set) var gitShelves: [GitShelfEntry] = []
    @Published package private(set) var gitWorktrees: [GitWorktree] = [] {
        didSet { gitWorktreesVersion = Self.nextGitWorktreesVersion() }
    }
    /// Constant-time key for the worktree list projection task.
    package private(set) var gitWorktreesVersion = 0

    private static var gitWorktreesVersionCounter = 0

    private static func nextGitWorktreesVersion() -> Int {
        gitWorktreesVersionCounter &+= 1
        return gitWorktreesVersionCounter
    }
    @Published package private(set) var gitWorktreeLoadState = GitWorktreeLoadState.idle
    @Published package private(set) var gitWorktreeInspection: GitWorktreeInspection? {
        didSet { gitWorktreeInspectionVersion = Self.nextGitWorktreeInspectionVersion() }
    }
    /// Constant-time key for completed worktree detail publications.
    package private(set) var gitWorktreeInspectionVersion = 0

    private static var gitWorktreeInspectionVersionCounter = 0

    private static func nextGitWorktreeInspectionVersion() -> Int {
        gitWorktreeInspectionVersionCounter &+= 1
        return gitWorktreeInspectionVersionCounter
    }
    @Published package private(set) var gitWorktreeInspectionLoadState = GitWorktreeInspectionLoadState.idle
    @Published package private(set) var isPerformingStashOperation = false
    @Published package private(set) var isPerformingShelfOperation = false
    @Published package private(set) var isPerformingWorktreeOperation = false
    @Published package private(set) var gitRepositoryRoot: URL?
    @Published package private(set) var currentBranch = "No Git"
    @Published package var selectedChange: GitChange?
    @Published package private(set) var selectedDiffPatch = ""
    @Published package private(set) var diffRows: [DiffRow] = []
    @Published package private(set) var diffHunks: [DiffHunk] = []
    @Published package var gitDiffWhitespaceMode = GitDiffWhitespaceMode.doNotIgnore
    @Published package private(set) var isLoadingDiff = false
    @Published package private(set) var isRefreshingGit = false
    @Published package var pendingDiscardChange: GitChange?
    @Published package var pendingDiscardHunk: DiffHunkRequest?
    @Published package var pendingCheckoutConflict: GitCheckoutConflictRequest?
    @Published package var pendingPullStrategy: GitPullStrategyRequest?
    @Published package var pendingIntegrationConflict: GitIntegrationConflictRequest?
    @Published package var pendingConflictRollback: GitConflictRollbackRequest?
    @Published package private(set) var pendingStashRestoreConflict: GitStashRestoreConflictRequest?
    @Published package private(set) var isStashRestoreConflictNoticeVisible = false
    /// The most recently deleted tag, kept in session state so the Git log can
    /// offer a restore. A later tag deletion replaces it on success or clears
    /// it on failure; branch recovery is independent, so both banners may be
    /// visible. Closing the banner or `reset()` clears this session-only state.
    @Published package private(set) var recentlyDeletedTag: GitTagDeletion?
    /// The most recently deleted local branch. Later branch attempts follow the
    /// same replace-or-clear rule without changing tag recovery state.
    @Published package private(set) var recentlyDeletedBranch: GitBranchDeletion?
    @Published package private(set) var gitConflictFilterPaths: Set<String> = []
    @Published package private(set) var requestedStashReference: String?
    /// Set whenever Git is mid-merge, mid-rebase, mid-cherry-pick, or mid-revert.
    @Published package var gitOperationState: GitOperationState?
    @Published package var isResolvingGitOperation = false
    @Published package private(set) var isCommitting = false
    @Published package private(set) var gitBlameLines: [URL: [GitBlameLine]] = [:]
    @Published package private(set) var gitLineChangeMarkers: [URL: [GitLineChangeMarker]] = [:]
    @Published package private(set) var gitReferences: [GitReference] = []
    @Published package private(set) var recentGitReferences: [GitReference] = []
    @Published package private(set) var gitCommits: [GitCommit] = [] {
        didSet { gitCommitsVersion = Self.nextGitCommitsVersion() }
    }
    /// Monotonic token for `gitCommits`, so `.task(id:)` keys and filter
    /// identities compare in constant time instead of hashing a list that
    /// routinely holds thousands of commits.
    ///
    /// Maintained by `didSet` rather than at each assignment, so a future write
    /// site cannot forget to bump it. Not `@Published`: it only ever changes
    /// alongside `gitCommits`, which already publishes, and a second publish
    /// would mean a second invalidation for one logical change.
    package private(set) var gitCommitsVersion = 0

    /// Counts across instances, so reopening a workspace cannot hand a fresh
    /// feature model a version a previous one already used.
    private static var gitCommitsVersionCounter = 0

    private static func nextGitCommitsVersion() -> Int {
        gitCommitsVersionCounter &+= 1
        return gitCommitsVersionCounter
    }
    @Published package private(set) var gitLogMatchedCommitHashes: Set<String>? {
        didSet { gitLogFilterVersion = Self.nextGitLogFilterVersion() }
    }
    /// Monotonic token for completed Git Log filter results. Rendering uses the
    /// token as a task key instead of comparing a potentially large hash set on
    /// every SwiftUI body evaluation.
    ///
    /// Like `gitCommitsVersion`, this changes with the published source value
    /// and therefore does not need a second publication of its own.
    package private(set) var gitLogFilterVersion = 0

    private static var gitLogFilterVersionCounter = 0

    private static func nextGitLogFilterVersion() -> Int {
        gitLogFilterVersionCounter &+= 1
        return gitLogFilterVersionCounter
    }
    @Published package private(set) var isFilteringGitLog = false
    @Published package var gitLogSearchQuery = ""
    @Published package var selectedGitReference: GitReference?
    /// `nil` is the current checkout when this is false, and all references
    /// when this is true. Keeping the mode separate prevents the UI from
    /// highlighting HEAD while the core is actually queried with `--all`.
    @Published package private(set) var isShowingAllGitReferences = false
    @Published package var selectedGitCommit: GitCommit?
    @Published package private(set) var selectedGitCommitFiles: [GitCommitFile] = [] {
        didSet { selectedGitCommitFilesVersion &+= 1 }
    }
    /// Constant-time change key for the commit file tree projection.
    package private(set) var selectedGitCommitFilesVersion = 0

    @Published package private(set) var selectedGitCommitFilesLoadState =
        GitCommitFilesLoadState.idle
    @Published package var selectedGitCommitFile: GitCommitFile?
    @Published package var selectedGitCommitDiffContext: GitCommitDiffContext?
    @Published package private(set) var isLoadingGitHistory = false
    @Published package private(set) var isLoadingMoreGitHistory = false
    @Published package private(set) var canLoadMoreGitHistory = false
    @Published package private(set) var gitConsoleEntries: [GitConsoleEntry] = []
    @Published package private(set) var branchComparison: GitBranchComparison?
    @Published package var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published package private(set) var branchComparisonRows: [DiffRow] = []
    @Published package private(set) var isLoadingBranchComparison = false
    @Published package private(set) var isPerformingBranchOperation = false
    @Published package private(set) var isCloningRepository = false

    private let service: GitService
    private let commitFilesLoader: GitCommitFilesLoader
    private var gitIdentity: GitIdentity?
    private var commitPathsByHash: [String: Set<String>] = [:]
    private var selectedGitCommitFilesGeneration: UInt64 = 0
    private var gitLogFilterGeneration = UUID()
    private let shelveService: ShelveService?
    private let snapshotProvider: @Sendable (URL) async -> GitSnapshot?
    private let stashesProvider: @Sendable (URL) async -> [GitStash]
    private let operationStateProvider: @Sendable (URL) async -> GitOperationState?
    private let worktreesProvider: @Sendable (URL) async -> [GitWorktree]?
    private let diffDocumentProvider: @Sendable (GitChange, GitDiffWhitespaceMode) async -> DiffDocument
    private var workspaceURLProvider: (@MainActor () -> URL?)?
    private var isGitLogVisibleProvider: (@MainActor () -> Bool)?
    private var notify: (@MainActor (String) -> Void)?
    private var onStateRefreshed: (@MainActor () async -> Void)?
    private var saveChangesPolicy: (@MainActor () -> GitSaveChangesPolicy)?
    private var onGitOperationBegan: (@MainActor () -> Void)?
    private var onGitOperationEnded: (@MainActor () async -> Void)?
    private var acquireModuleLease: (@MainActor (String) -> ModuleLease)?
    private static let gitHistoryPageSize = 100
    private var gitHistoryCursor: String?
    private var gitHistoryGeneration = UUID()
    private var activeGitHistoryOperationIDs: Set<String> = []
    private var deferredSavedChanges: GitDeferredSavedChanges?
    private var nextRefreshRequestID: UInt64 = 0
    private var activeRefreshRequestIDs: Set<UInt64> = []
    private var completedRefreshRequestID: UInt64 = 0
    private var refreshCompletionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isLoadingInitialGitConsoleEntry = false
    private var hasLoadedInitialGitConsoleEntry = false
    private var gitConsoleRepositoryGeneration: UInt64 = 0
    private var loadingLineChangeURLs: Set<URL> = []
    private var lineChangeHunks: [URL: [String: DiffHunk]] = [:]
    private var worktreeRequestGeneration: UInt64 = 0
    private var worktreeInspectionRequestGeneration: UInt64 = 0

    private static let commitFilesPrefetchRadius = 4

    package init(
        service: GitService,
        shelveService: ShelveService? = nil,
        snapshotProvider: (@Sendable (URL) async -> GitSnapshot?)? = nil,
        stashesProvider: (@Sendable (URL) async -> [GitStash])? = nil,
        operationStateProvider: (@Sendable (URL) async -> GitOperationState?)? = nil,
        worktreesProvider: (@Sendable (URL) async -> [GitWorktree]?)? = nil,
        diffDocumentProvider: (@Sendable (GitChange, GitDiffWhitespaceMode) async -> DiffDocument)? = nil
    ) {
        self.service = service
        commitFilesLoader = GitCommitFilesLoader(service: service)
        self.shelveService = shelveService
        self.snapshotProvider = snapshotProvider ?? { await service.snapshot(for: $0) }
        self.stashesProvider = stashesProvider ?? { await service.stashes(at: $0) }
        self.operationStateProvider = operationStateProvider ?? { await service.operationState(at: $0) }
        self.worktreesProvider = worktreesProvider ?? { await service.worktrees(at: $0) }
        self.diffDocumentProvider = diffDocumentProvider ?? {
            await service.diffDocument(for: $0, whitespace: $1)
        }
    }

    package func configure(
        workspaceURLProvider: @escaping @MainActor () -> URL?,
        isGitLogVisibleProvider: @escaping @MainActor () -> Bool,
        notify: @escaping @MainActor (String) -> Void,
        onStateRefreshed: @escaping @MainActor () async -> Void,
        saveChangesPolicy: @escaping @MainActor () -> GitSaveChangesPolicy = { .stash },
        onGitOperationBegan: @escaping @MainActor () -> Void = {},
        onGitOperationEnded: @escaping @MainActor () async -> Void = {}
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.isGitLogVisibleProvider = isGitLogVisibleProvider
        self.notify = notify
        self.onStateRefreshed = onStateRefreshed
        self.saveChangesPolicy = saveChangesPolicy
        self.onGitOperationBegan = onGitOperationBegan
        self.onGitOperationEnded = onGitOperationEnded
    }

    package func configureModuleLeases(
        acquire: @escaping @MainActor (String) -> ModuleLease
    ) {
        acquireModuleLease = acquire
    }

    package var currentGitReference: GitReference? {
        gitReferences.first(where: \.isCurrent)
    }

    package var hasActiveModuleWork: Bool {
        isPerformingStashOperation
            || isPerformingShelfOperation
            || isPerformingWorktreeOperation
            || isLoadingDiff
            || isRefreshingGit
            || isCommitting
            || isLoadingGitHistory
            || isLoadingMoreGitHistory
            || isLoadingBranchComparison
            || isPerformingBranchOperation
            || isCloningRepository
            || isResolvingGitOperation
            || commitFilesLoader.hasActiveWork
    }

    package func reset() {
        cancelGitHistoryLoading()
        gitChanges = []
        pendingStagingStates = [:]
        gitStashes = []
        gitShelves = []
        gitWorktrees = []
        gitWorktreeLoadState = .idle
        worktreeRequestGeneration &+= 1
        gitWorktreeInspection = nil
        gitWorktreeInspectionLoadState = .idle
        worktreeInspectionRequestGeneration &+= 1
        gitOperationState = nil
        pendingPullStrategy = nil
        pendingIntegrationConflict = nil
        pendingConflictRollback = nil
        pendingStashRestoreConflict = nil
        isStashRestoreConflictNoticeVisible = false
        recentlyDeletedTag = nil
        recentlyDeletedBranch = nil
        gitConflictFilterPaths = []
        requestedStashReference = nil
        gitLogSearchQuery = ""
        deferredSavedChanges = nil
        isPerformingStashOperation = false
        isPerformingShelfOperation = false
        isPerformingWorktreeOperation = false
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        gitDiffWhitespaceMode = .doNotIgnore
        isLoadingDiff = false
        isRefreshingGit = false
        pendingDiscardChange = nil
        pendingDiscardHunk = nil
        isCommitting = false
        gitBlameLines = [:]
        gitLineChangeMarkers = [:]
        loadingLineChangeURLs = []
        lineChangeHunks = [:]
        gitReferences = []
        recentGitReferences = []
        gitCommits = []
        gitIdentity = nil
        gitLogMatchedCommitHashes = nil
        isFilteringGitLog = false
        commitPathsByHash = [:]
        clearGitCommitFilesCache()
        gitLogFilterGeneration = UUID()
        gitHistoryCursor = nil
        isLoadingGitHistory = false
        isLoadingMoreGitHistory = false
        canLoadMoreGitHistory = false
        gitConsoleEntries = []
        isLoadingInitialGitConsoleEntry = false
        hasLoadedInitialGitConsoleEntry = false
        gitConsoleRepositoryGeneration &+= 1
        selectedGitReference = nil
        isShowingAllGitReferences = false
        selectedGitCommit = nil
        selectedGitCommitFiles = []
        selectedGitCommitFilesLoadState = .idle
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
        isPerformingBranchOperation = false
        isCloningRepository = false
        isResolvingGitOperation = false
    }

    package func refreshGit() async {
        guard let workspaceURLProvider else { return }
        guard !Task.isCancelled else { return }
        nextRefreshRequestID &+= 1
        let requestID = nextRefreshRequestID
        activeRefreshRequestIDs.insert(requestID)
        defer { activeRefreshRequestIDs.remove(requestID) }
        await fulfillGitRefreshRequest(requestID, workspaceURLProvider: workspaceURLProvider)
    }

    private func fulfillGitRefreshRequest(
        _ requestID: UInt64,
        workspaceURLProvider: @MainActor () -> URL?
    ) async {
        if isRefreshingGit {
            await waitForCurrentGitRefresh()
            guard !Task.isCancelled else { return }
            if completedRefreshRequestID < requestID {
                await fulfillGitRefreshRequest(requestID, workspaceURLProvider: workspaceURLProvider)
            }
            return
        }
        guard let workspaceURL = workspaceURLProvider() else {
            reset()
            completedRefreshRequestID = max(completedRefreshRequestID, requestID)
            return
        }

        isRefreshingGit = true
        defer { finishCurrentGitRefresh() }
        repeat {
            guard !Task.isCancelled else { return }
            let processingRequestID = activeRefreshRequestIDs.max() ?? requestID
            await refreshGitState(at: workspaceURL)
            guard !Task.isCancelled else { return }
            completedRefreshRequestID = max(completedRefreshRequestID, processingRequestID)
        } while activeRefreshRequestIDs.contains(where: { $0 > completedRefreshRequestID })
            && workspaceURLProvider() == workspaceURL
    }

    private func waitForCurrentGitRefresh() async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isRefreshingGit, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                refreshCompletionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeGitRefreshWaiter(waiterID)
            }
        }
    }

    private func finishCurrentGitRefresh() {
        isRefreshingGit = false
        let waiters = Array(refreshCompletionWaiters.values)
        refreshCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeGitRefreshWaiter(_ waiterID: UUID) {
        refreshCompletionWaiters.removeValue(forKey: waiterID)?.resume()
    }

    private func refreshGitState(at workspaceURL: URL) async {
        guard !Task.isCancelled else { return }
        var didChange = false
        if let snapshot = await snapshotProvider(workspaceURL) {
            guard !Task.isCancelled else { return }
            let changesChanged = gitChanges != snapshot.changes
            if gitRepositoryRoot != snapshot.repositoryRoot {
                clearGitCommitFilesCache()
                gitRepositoryRoot = snapshot.repositoryRoot
                gitWorktrees = []
                gitWorktreeLoadState = .idle
                worktreeRequestGeneration &+= 1
                gitConsoleRepositoryGeneration &+= 1
                isLoadingInitialGitConsoleEntry = false
                hasLoadedInitialGitConsoleEntry = false
                didChange = true
            }
            if currentBranch != snapshot.branch {
                currentBranch = snapshot.branch
                didChange = true
            }
            if changesChanged {
                gitChanges = snapshot.changes
                gitLineChangeMarkers = [:]
                lineChangeHunks = [:]
                didChange = true
            }
            reconcilePendingStagingStates(with: snapshot.changes)
            if !gitConflictFilterPaths.isEmpty {
                let previousFilter = gitConflictFilterPaths
                gitConflictFilterPaths.formIntersection(Set(snapshot.changes.map(\.path)))
                didChange = didChange || previousFilter != gitConflictFilterPaths
            }
            let stashes = await stashesProvider(snapshot.repositoryRoot)
            guard !Task.isCancelled else { return }
            if gitStashes != stashes {
                gitStashes = stashes
                didChange = true
            }
            let shelves = await shelveService?.entries(for: snapshot.repositoryRoot) ?? []
            guard !Task.isCancelled else { return }
            if gitShelves != shelves {
                gitShelves = shelves
                didChange = true
            }
            let operationState = await operationStateProvider(snapshot.repositoryRoot)
            guard !Task.isCancelled else { return }
            if gitOperationState != operationState {
                gitOperationState = operationState
                didChange = true
            }
            if let gitOperationState, deferredSavedChanges == nil,
               let stash = gitStashes.first(where: { $0.message.contains("Lithe auto-stash before") }) {
                deferredSavedChanges = GitDeferredSavedChanges(
                    stashReference: stash.reference,
                    operationTitle: gitOperationState.kind.title.lowercased()
                )
            }

            if let selectedChange,
               let updated = snapshot.changes.first(where: { $0.path == selectedChange.path }) {
                if self.selectedChange != updated {
                    self.selectedChange = updated
                    didChange = true
                }
                let document = await diffDocumentProvider(updated, gitDiffWhitespaceMode)
                guard !Task.isCancelled else { return }
                if selectedDiffPatch != document.patch {
                    selectedDiffPatch = document.patch
                    diffRows = document.rows
                    diffHunks = document.hunks
                    didChange = true
                }
            } else if selectedChange != nil {
                self.selectedChange = nil
                selectedDiffPatch = ""
                diffRows = []
                diffHunks = []
                isLoadingDiff = false
                didChange = true
            }
        } else {
            if gitRepositoryRoot != nil {
                clearGitCommitFilesCache()
                gitRepositoryRoot = nil
                didChange = true
            }
            if currentBranch != "No Git" { currentBranch = "No Git"; didChange = true }
            if !gitChanges.isEmpty { gitChanges = []; didChange = true }
            if !gitStashes.isEmpty { gitStashes = []; didChange = true }
            if !gitShelves.isEmpty { gitShelves = []; didChange = true }
            if gitOperationState != nil { gitOperationState = nil; didChange = true }
            if selectedChange != nil { selectedChange = nil; didChange = true }
            if !selectedDiffPatch.isEmpty { selectedDiffPatch = ""; didChange = true }
            if !diffRows.isEmpty { diffRows = []; didChange = true }
            if !diffHunks.isEmpty { diffHunks = []; didChange = true }
            if isLoadingDiff { isLoadingDiff = false; didChange = true }
        }

        if didChange && isGitLogVisibleProvider?() == true {
            guard !Task.isCancelled else { return }
            await refreshGitHistory()
        }
        if didChange {
            guard !Task.isCancelled else { return }
            await onStateRefreshed?()
        }
    }

    package func selectChange(_ change: GitChange) async {
        closeBranchComparison()
        selectedGitCommitDiffContext = nil
        selectedChange = change
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        isLoadingDiff = true
        let document = await service.diffDocument(
            for: change,
            whitespace: gitDiffWhitespaceMode
        )
        guard selectedChange?.id == change.id else { return }
        selectedDiffPatch = document.patch
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    package func showDirectoryDiff(at directoryURL: URL) async {
        guard let repositoryRoot = gitRepositoryRoot else { return }
        let rootPath = repositoryRoot.standardizedFileURL.path
        let directoryPath = directoryURL.standardizedFileURL.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else { return }
        let relativePath = directoryPath == rootPath
            ? ""
            : String(directoryPath.dropFirst(rootPath.count + 1))
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"
        let changes = gitChanges.filter {
            relativePath.isEmpty || $0.path == relativePath || $0.path.hasPrefix(prefix)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !changes.isEmpty else { return }

        let hasWorkingTreeChange = changes.contains(where: \.hasWorkingTreeChange)
        let isEntirelyUntracked = changes.allSatisfy(\.isUntracked)
        let summary = GitChange(
            repositoryRoot: repositoryRoot,
            path: relativePath.isEmpty ? "." : relativePath,
            originalPath: nil,
            indexStatus: isEntirelyUntracked ? "?" : (hasWorkingTreeChange ? " " : "M"),
            workTreeStatus: isEntirelyUntracked ? "?" : (hasWorkingTreeChange ? "M" : " ")
        )

        closeBranchComparison()
        selectedGitCommitDiffContext = nil
        selectedChange = summary
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        isLoadingDiff = true
        var documents: [DiffDocument] = []
        for change in changes {
            documents.append(
                await service.diffDocumentAgainstHead(
                    for: change,
                    whitespace: gitDiffWhitespaceMode
                )
            )
        }
        guard selectedChange?.id == summary.id else { return }
        selectedDiffPatch = documents.map(\.patch).filter { !$0.isEmpty }.joined(separator: "\n")
        diffRows = documents.flatMap(\.rows)
        diffHunks = documents.flatMap(\.hunks)
        isLoadingDiff = false
    }

    package func selectConflictPath(_ path: String) async {
        guard let change = gitChanges.first(where: { $0.path == path }) else { return }
        await selectChange(change)
    }

    package func loadLineChanges(for fileURL: URL) async {
        let normalizedURL = fileURL.standardizedFileURL
        guard !loadingLineChangeURLs.contains(normalizedURL) else { return }
        guard let change = gitChanges.first(where: {
            $0.url.standardizedFileURL == normalizedURL
        }) else {
            gitLineChangeMarkers[normalizedURL] = []
            lineChangeHunks[normalizedURL] = [:]
            return
        }
        loadingLineChangeURLs.insert(normalizedURL)
        defer { loadingLineChangeURLs.remove(normalizedURL) }

        let document = await service.diffDocument(for: change)
        guard gitChanges.contains(change) else { return }
        gitLineChangeMarkers[normalizedURL] = GitLineChangeProjection.markers(from: document.rows)
        lineChangeHunks[normalizedURL] = Dictionary(
            uniqueKeysWithValues: document.hunks.map { ($0.id, $0) }
        )
    }

    package func showLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let change = gitChanges.first(where: {
            $0.url.standardizedFileURL == fileURL.standardizedFileURL
        }) else { return }
        await selectChange(change)
        _ = marker
    }

    package func stageLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let (change, hunk) = lineChangeContext(marker, fileURL: fileURL),
              change.hasWorkingTreeChange else { return }
        await stageDiffHunk(hunk, in: change)
    }

    package func unstageLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) async {
        guard let (change, hunk) = lineChangeContext(marker, fileURL: fileURL),
              change.isStaged, !change.hasWorkingTreeChange else { return }
        await unstageDiffHunk(hunk, in: change)
    }

    package func requestDiscardLineChange(_ marker: GitLineChangeMarker, for fileURL: URL) {
        guard let (change, hunk) = lineChangeContext(marker, fileURL: fileURL),
              change.hasWorkingTreeChange else { return }
        requestDiscardHunk(hunk, in: change)
    }

    private func lineChangeContext(
        _ marker: GitLineChangeMarker,
        fileURL: URL
    ) -> (GitChange, DiffHunk)? {
        let normalizedURL = fileURL.standardizedFileURL
        guard let hunkID = marker.hunkID,
              let hunk = lineChangeHunks[normalizedURL]?[hunkID],
              let change = gitChanges.first(where: {
                  $0.url.standardizedFileURL == normalizedURL
              }) else { return nil }
        return (change, hunk)
    }

    private var selectedSaveChangesPolicy: GitSaveChangesPolicy {
        guard saveChangesPolicy?() != .shelve || shelveService != nil else { return .stash }
        return saveChangesPolicy?() ?? .stash
    }

    private func withGitOperation<T>(_ operation: () async -> T) async -> T {
        let lease = acquireModuleLease?("Git operation in progress")
        defer { lease?.release() }
        onGitOperationBegan?()
        let result = await operation()
        if let commandResult = result as? GitService.CommandResult {
            recordGitConsoleEntry(commandResult)
        }
        await onGitOperationEnded?()
        return result
    }

    private func recordingGitCommand(
        _ operation: () async -> GitService.CommandResult
    ) async -> GitService.CommandResult {
        let result = await operation()
        recordGitConsoleEntry(result)
        return result
    }

    package func clearGitConsole() {
        gitConsoleEntries = []
        hasLoadedInitialGitConsoleEntry = true
    }

    package func loadGitConsoleIfNeeded() async {
        guard !hasLoadedInitialGitConsoleEntry,
              let gitRepositoryRoot,
              !isLoadingInitialGitConsoleEntry else { return }
        let requestedRoot = gitRepositoryRoot
        let requestedGeneration = gitConsoleRepositoryGeneration
        isLoadingInitialGitConsoleEntry = true
        defer {
            if requestedGeneration == gitConsoleRepositoryGeneration {
                isLoadingInitialGitConsoleEntry = false
            }
        }
        let result = await service.consoleVersion(at: requestedRoot)
        guard requestedGeneration == gitConsoleRepositoryGeneration,
              gitRepositoryRoot == requestedRoot,
              !hasLoadedInitialGitConsoleEntry else { return }
        hasLoadedInitialGitConsoleEntry = true
        guard gitConsoleEntries.isEmpty else { return }
        recordGitConsoleEntry(result)
    }

    private func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Int {
        let components = startedAt.duration(to: .now).components
        let milliseconds = (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        return max(0, Int(milliseconds.rounded()))
    }

    private func recordGitConsoleEntry(_ result: GitService.CommandResult) {
        guard let workingDirectory = result.workingDirectory ?? gitRepositoryRoot else { return }
        if result.invocations.isEmpty {
            gitConsoleEntries.append(
                GitConsoleEntry(
                    workingDirectory: workingDirectory,
                    arguments: result.arguments,
                    output: result.output,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError,
                    exitCode: result.exitCode
                )
            )
        } else {
            gitConsoleEntries.append(contentsOf: result.invocations.map { invocation in
                GitConsoleEntry(
                    workingDirectory: workingDirectory,
                    arguments: invocation.arguments,
                    output: invocation.output,
                    standardOutput: invocation.standardOutput,
                    standardError: invocation.standardError,
                    exitCode: invocation.exitCode
                )
            })
        }
        if gitConsoleEntries.count > 500 {
            gitConsoleEntries.removeFirst(gitConsoleEntries.count - 500)
        }
    }

    package func setGitConflictFilter(_ paths: [String]) {
        gitConflictFilterPaths = Set(paths)
    }

    package func clearGitConflictFilter() {
        gitConflictFilterPaths = []
    }

    package func requestStashSelection(_ reference: String) {
        requestedStashReference = reference
    }

    package func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        gitDiffWhitespaceMode = whitespace
        guard let selectedChange else { return }
        isLoadingDiff = true
        let document = await service.diffDocument(for: selectedChange, whitespace: whitespace)
        guard self.selectedChange?.id == selectedChange.id else { return }
        selectedDiffPatch = document.patch
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    package func commitMessageInput(for change: GitChange) async -> CommitMessageInput {
        let patch: String
        if selectedChange?.id == change.id, !selectedDiffPatch.isEmpty {
            patch = selectedDiffPatch
        } else {
            patch = await service.diffPatch(for: change, whitespace: gitDiffWhitespaceMode)
        }
        return CommitMessageInput(path: change.path, changeKind: change.kind.commitMessageKind, diff: patch)
    }

    /// Builds the input for the commit editor from the index snapshot. This
    /// deliberately bypasses the selected file's working-tree diff so a file
    /// with both staged and unstaged edits is represented correctly.
    package func stagedCommitMessageInput() async -> CommitMessageInput? {
        let stagedChanges = gitChanges.filter(\.isStaged)
        guard !stagedChanges.isEmpty else { return nil }

        var files: [CommitMessageFileInput] = []
        files.reserveCapacity(stagedChanges.count)
        for change in stagedChanges {
            let patch = await service.stagedDiffPatch(
                for: change,
                whitespace: gitDiffWhitespaceMode
            )
            guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            files.append(
                CommitMessageFileInput(
                    path: change.path,
                    changeKind: change.kind.commitMessageKind,
                    diff: patch
                )
            )
        }

        guard !files.isEmpty else { return nil }
        return CommitMessageInput(files: files)
    }

    package func stageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await withGitOperation { await service.stage(selectedChange) }
        showResult(result, success: "Staged \(selectedChange.path)")
        await refreshGit()
    }

    package func unstageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await withGitOperation { await service.unstage(selectedChange) }
        showResult(result, success: "Unstaged \(selectedChange.path)")
        await refreshGit()
    }

    package func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await withGitOperation { await service.stage(hunk: hunk, of: change) }
        showResult(result, success: "Staged a change block in \(change.path)")
        await refreshGit()
    }

    package func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await withGitOperation { await service.unstage(hunk: hunk, of: change) }
        showResult(result, success: "Unstaged a change block in \(change.path)")
        await refreshGit()
    }

    package func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        pendingDiscardHunk = DiffHunkRequest(change: change, hunk: hunk)
    }

    package func confirmDiscardHunk() async {
        guard let request = pendingDiscardHunk else { return }
        pendingDiscardHunk = nil
        let result = await withGitOperation {
            await service.discard(hunk: request.hunk, of: request.change)
        }
        showResult(result, success: "Discarded a change block in \(request.change.path)")
        await refreshGit()
    }

    package func cancelDiscardHunk() {
        pendingDiscardHunk = nil
    }

    package func requestDiscardSelectedChange() {
        requestDiscardChange(selectedChange)
    }

    /// Opens the existing discard confirmation for a specific row.
    ///
    /// Context-menu actions can be invoked before the row has finished
    /// becoming the selected change, so they must not rely on
    /// `selectedChange` being up to date.
    package func requestDiscardChange(_ change: GitChange?) {
        pendingDiscardChange = change
    }

    package func confirmDiscardChange() async {
        guard let change = pendingDiscardChange else { return }
        pendingDiscardChange = nil
        let result = await withGitOperation { await service.discard(change) }
        showResult(result, success: "Discarded \(change.path)")
        await refreshGit()
    }

    package func cancelDiscardChange() {
        pendingDiscardChange = nil
    }

    package func requestConflictRollback(path: String, resume: GitConflictResume) {
        guard gitChanges.contains(where: { $0.path == path }) else {
            notify?("The conflict file is no longer in the working tree")
            return
        }
        pendingConflictRollback = GitConflictRollbackRequest(path: path, resume: resume)
    }

    package func cancelConflictRollback() {
        pendingConflictRollback = nil
    }

    /// Confirms a rollback using the request captured by the dialog action.
    ///
    /// A confirmation dialog dismisses asynchronously and its binding can clear
    /// `pendingConflictRollback` before an action's `Task` starts. The explicit
    /// request keeps the destructive operation and its retry target alive across
    /// that dismissal.
    package func confirmConflictRollback(_ request: GitConflictRollbackRequest) async {
        if pendingConflictRollback?.id == request.id {
            pendingConflictRollback = nil
        }
        guard let change = gitChanges.first(where: { $0.path == request.path }) else {
            notify?("The conflict file is no longer in the working tree")
            return
        }
        let result = await withGitOperation { await service.discardAll(change) }
        guard result.succeeded else {
            notify?(trimmedMessage(result))
            return
        }
        notify?("Discarded \(request.path)")
        await refreshGit()
        await retryConflictResume(request.resume)
    }

    private func retryConflictResume(_ resume: GitConflictResume) async {
        switch resume {
        case .checkout(let reference):
            guard let gitRepositoryRoot else { return }
            let blockingPaths = await service.checkoutBlockingPaths(
                for: reference,
                at: gitRepositoryRoot
            )
            if blockingPaths.isEmpty {
                await performCheckout(reference)
            } else {
                pendingCheckoutConflict = GitCheckoutConflictRequest(
                    reference: reference,
                    blockingPaths: blockingPaths
                )
            }
        case .integration(let target, let operation):
            await startIntegration(target, operation: operation)
        }
    }

    /// Paths still holding conflict markers. Committing during a merge or rebase
    /// would finish that operation, so an unresolved file has to stop the commit
    /// rather than be recorded with its `<<<<<<<` markers intact.
    private var conflictedPaths: [String] {
        gitChanges.filter(\.isConflicted).map(\.path)
    }

    private func blockCommitWhenConflicted() -> Bool {
        let paths = conflictedPaths
        guard !paths.isEmpty else { return false }
        notify?("Resolve the conflicts first: \(paths.joined(separator: ", "))")
        return true
    }

    /// Refuses a commit whose staged content still carries conflict markers.
    ///
    /// Separate from `blockCommitWhenConflicted`: Git stops marking a file as
    /// conflicted the moment it is staged, so a user who stages before deleting the
    /// `<<<<<<<` lines would otherwise commit them. This reads the staged blobs.
    private func blockCommitWhenMarkersRemain() async -> Bool {
        guard let gitRepositoryRoot else { return false }
        let paths = await service.conflictMarkerPaths(at: gitRepositoryRoot)
        guard !paths.isEmpty else { return false }
        notify?("Conflict markers remain in: \(paths.joined(separator: ", "))")
        return true
    }

    package func commitStagedChanges(message rawMessage: String, amend: Bool) async -> Bool {
        guard let gitRepositoryRoot else { return false }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            notify?("Enter a commit message")
            return false
        }
        guard !blockCommitWhenConflicted() else { return false }
        guard await !blockCommitWhenMarkersRemain() else { return false }

        isCommitting = true
        let result = await withGitOperation {
            await service.commit(at: gitRepositoryRoot, message: message, amend: amend)
        }
        isCommitting = false
        if result.succeeded {
            notify?("Changes committed")
        } else {
            notify?(trimmedMessage(result))
        }
        await refreshGit()
        return result.succeeded
    }

    @discardableResult
    package func commitAndPushStagedChanges(message rawMessage: String, amend: Bool) async -> Bool {
        guard let gitRepositoryRoot else { return false }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            notify?("Enter a commit message")
            return false
        }
        guard gitChanges.contains(where: \.isStaged) else {
            notify?("Stage at least one change before committing")
            return false
        }
        guard !blockCommitWhenConflicted() else { return false }
        guard await !blockCommitWhenMarkersRemain() else { return false }

        isCommitting = true
        let commitResult = await withGitOperation {
            await service.commit(
                at: gitRepositoryRoot,
                message: message,
                amend: amend
            )
        }
        guard commitResult.succeeded else {
            isCommitting = false
            notify?(trimmedMessage(commitResult))
            await refreshGit()
            return false
        }

        guard let currentReference = currentGitReference else {
            isCommitting = false
            notify?("Committed changes, but detached HEAD cannot be pushed")
            await refreshGit()
            return true
        }

        let pushResult = await withGitOperation {
            await service.push(currentReference, at: gitRepositoryRoot)
        }
        isCommitting = false
        if pushResult.succeeded {
            notify?("Committed and pushed \(currentReference.shortName)")
        } else {
            notify?("Committed changes, but push failed: \(trimmedMessage(pushResult))")
        }
        await refreshGit()
        return true
    }

    func reconcilePendingStagingStates(with changes: [GitChange]) {
        let changesByID = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        pendingStagingStates = pendingStagingStates.filter { id, staged in
            changesByID[id]?.isStaged != staged
        }
    }

    package func effectiveStagingState(for change: GitChange) -> Bool {
        pendingStagingStates[change.id] ?? change.isStaged
    }

    package func beginToggleStaging(_ change: GitChange) -> Bool? {
        guard pendingStagingStates[change.id] == nil else { return nil }
        let staged = !change.isStaged
        pendingStagingStates[change.id] = staged
        return staged
    }

    package func beginSetStaging(_ changes: [GitChange], staged: Bool) -> [GitChange] {
        let pendingChanges = changes.filter {
            pendingStagingStates[$0.id] == nil && $0.isStaged != staged
        }
        for change in pendingChanges {
            pendingStagingStates[change.id] = staged
        }
        return pendingChanges
    }

    package func finishToggleStaging(_ change: GitChange, staged: Bool) async {
        let result = await withGitOperation {
            staged
                ? await service.stage(change)
                : await service.unstage(change)
        }
        let verb = staged ? "Staged" : "Unstaged"
        showResult(result, success: "\(verb) \(change.path)")
        if !result.succeeded {
            pendingStagingStates.removeValue(forKey: change.id)
        }
        await refreshGit()
    }

    package func finishSetStaging(_ pendingChanges: [GitChange], staged: Bool) async {
        guard !pendingChanges.isEmpty else { return }

        var completedChangeIDs = Set<GitChange.ID>()
        var failedChange: GitChange?
        var failedResult: GitService.CommandResult?
        await withGitOperation {
            for change in pendingChanges {
                let result = await recordingGitCommand {
                    staged
                        ? await service.stage(change)
                        : await service.unstage(change)
                }
                guard result.succeeded else {
                    failedChange = change
                    failedResult = result
                    break
                }
                completedChangeIDs.insert(change.id)
            }
        }

        if let failedChange, let failedResult {
            notify?("Could not \(staged ? "stage" : "unstage") \(failedChange.path): \(trimmedMessage(failedResult))")
        } else {
            let verb = staged ? "Staged" : "Unstaged"
            notify?("\(verb) \(pendingChanges.count) file(s)")
        }
        for change in pendingChanges where !completedChangeIDs.contains(change.id) {
            pendingStagingStates.removeValue(forKey: change.id)
        }
        await refreshGit()
    }

    package func stageAllChanges() async {
        guard let gitRepositoryRoot else { return }
        let result = await withGitOperation { await service.stageAll(at: gitRepositoryRoot) }
        showResult(result, success: "Staged all changes")
        await refreshGit()
    }

    package func stashWorkingTree(message: String, includeUntracked: Bool) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await withGitOperation {
            await service.stash(
                message: message,
                includeUntracked: includeUntracked,
                at: gitRepositoryRoot
            )
        }
        isPerformingStashOperation = false
        if result.succeeded {
            notify?("Working tree stashed")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    /// Saves the current worktree in Lithe's patch store and clears the Git
    /// worktree. This is the manual counterpart to the automatic Shelve policy.
    package func shelveWorkingTree(message: String) async {
        guard let gitRepositoryRoot, shelveService != nil else {
            notify?("Shelve storage is unavailable")
            return
        }
        isPerformingShelfOperation = true
        let result = await withGitOperation {
            await captureAndCleanShelf(message: message, at: gitRepositoryRoot)
        }
        isPerformingShelfOperation = false
        switch result {
        case .saved(let entry):
            notify?("Shelved \(entry.paths.count) file(s)")
        case .failed(let message):
            notify?(message)
        }
    }

    package func applyShelf(_ shelf: GitShelfEntry) async {
        guard let gitRepositoryRoot else { return }
        isPerformingShelfOperation = true
        let restored = await withGitOperation {
            await restoreShelf(shelf, at: gitRepositoryRoot)
        }
        isPerformingShelfOperation = false
        if restored {
            notify?("Restored shelf")
        }
    }

    package func dropShelf(_ shelf: GitShelfEntry) async {
        guard let gitRepositoryRoot, let shelveService else { return }
        isPerformingShelfOperation = true
        let deleted = await withGitOperation {
            await shelveService.delete(shelf, repositoryRoot: gitRepositoryRoot)
        }
        isPerformingShelfOperation = false
        notify?(deleted ? "Dropped shelf" : "Could not drop shelf")
        await refreshGit()
    }

    private enum ShelfCaptureResult {
        case saved(GitShelfEntry)
        case failed(String)
    }

    private func captureAndCleanShelf(
        message: String,
        at repositoryRoot: URL
    ) async -> ShelfCaptureResult {
        guard let shelveService else { return .failed("Shelve storage is unavailable") }
        let changes = gitChanges
        guard !changes.isEmpty else { return .failed("There are no changes to shelve") }
        guard !changes.contains(where: \.isConflicted) else {
            return .failed("Resolve existing conflicts before shelving changes")
        }

        var stagedPatches: [String] = []
        var workingPatches: [String] = []
        for change in changes {
            if change.isStaged {
                let patch = await service.stagedDiffPatch(for: change)
                if !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    stagedPatches.append(patch)
                }
            }
            if change.hasWorkingTreeChange {
                let patch = await service.workingDiffPatch(for: change)
                if !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    workingPatches.append(patch)
                }
            }
        }

        let stagedPatch = stagedPatches.joined(separator: "\n")
        let workingPatch = workingPatches.joined(separator: "\n")
        guard !stagedPatch.isEmpty || !workingPatch.isEmpty else {
            return .failed("Could not create a patch for these changes")
        }

        let paths = Array(Set(changes.flatMap(\.pathspecs))).sorted()
        guard let entry = await shelveService.save(
            message: message,
            repositoryRoot: repositoryRoot,
            paths: paths,
            stagedPatch: stagedPatch,
            workingPatch: workingPatch
        ) else {
            return .failed("Could not save the shelf")
        }

        for change in changes {
            let discarded = await recordingGitCommand {
                await service.discardAll(change)
            }
            guard discarded.succeeded else {
                await refreshGit()
                return .failed(
                    "Shelf saved, but could not clear \(change.path): \(trimmedMessage(discarded))"
                )
            }
        }
        await refreshGit()
        return .saved(entry)
    }

    @discardableResult
    private func restoreShelf(_ shelf: GitShelfEntry, at repositoryRoot: URL) async -> Bool {
        guard let shelveService else { return false }
        if !shelf.stagedPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = await recordingGitCommand {
                await service.applyPatch(
                    shelf.stagedPatch,
                    at: repositoryRoot,
                    mode: "restoreIndex"
                )
            }
            if !result.succeeded {
                let alreadyApplied = await service.patchIsAlreadyApplied(
                    shelf.stagedPatch,
                    at: repositoryRoot,
                    staged: true
                )
                guard alreadyApplied else {
                    notify?("Could not restore shelf: \(trimmedMessage(result))")
                    return false
                }
            }
        }
        if !shelf.workingPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let result = await recordingGitCommand {
                await service.applyPatch(
                    shelf.workingPatch,
                    at: repositoryRoot,
                    mode: "worktree"
                )
            }
            if !result.succeeded {
                let alreadyApplied = await service.patchIsAlreadyApplied(
                    shelf.workingPatch,
                    at: repositoryRoot,
                    staged: false
                )
                guard alreadyApplied else {
                    notify?("Shelf partially restored; it was kept for retry: \(trimmedMessage(result))")
                    await refreshGit()
                    return false
                }
            }
        }
        guard await shelveService.delete(shelf, repositoryRoot: repositoryRoot) else {
            notify?("Shelf restored, but it could not be removed")
            await refreshGit()
            return true
        }
        await refreshGit()
        return true
    }

    package func applyStash(_ stash: GitStash, pop: Bool = false) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await withGitOperation {
            pop
                ? await service.popStash(stash, at: gitRepositoryRoot)
                : await service.applyStash(stash, at: gitRepositoryRoot)
        }
        isPerformingStashOperation = false
        if result.succeeded {
            notify?(pop ? "Popped \(stash.reference)" : "Applied \(stash.reference)")
            await refreshGit()
        } else {
            if let conflict = result.stashRestoreConflict {
                presentStashRestoreConflict(conflict, operationTitle: "stash restore")
                // `stash apply` can leave an unmerged index while still returning
                // before the normal success refresh path. Load those paths now so
                // the persistent notice can open the existing diff UI immediately.
                await refreshGit()
            } else {
                notify?(trimmedMessage(result))
            }
        }
    }

    package func dropStash(_ stash: GitStash) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await withGitOperation { await service.dropStash(stash, at: gitRepositoryRoot) }
        isPerformingStashOperation = false
        if result.succeeded,
           pendingStashRestoreConflict?.stashReference == stash.reference {
            pendingStashRestoreConflict = nil
            isStashRestoreConflictNoticeVisible = false
        }
        notify?(result.succeeded ? "Dropped \(stash.reference)" : trimmedMessage(result))
        await refreshGit()
    }

    private func presentStashRestoreConflict(
        _ conflict: GitStashRestoreConflict,
        operationTitle: String
    ) {
        pendingStashRestoreConflict = GitStashRestoreConflictRequest(
            stashReference: conflict.stashReference,
            conflictedPaths: conflict.conflictedPaths,
            operationTitle: operationTitle
        )
        isStashRestoreConflictNoticeVisible = true
    }

    package func dismissStashRestoreConflictNotice() {
        isStashRestoreConflictNoticeVisible = false
    }

    package func showStashRestoreConflictNotice() {
        guard pendingStashRestoreConflict != nil else { return }
        isStashRestoreConflictNoticeVisible = true
    }

    package func showStashRestoreConflictFiles() {
        guard let conflict = pendingStashRestoreConflict else { return }
        setGitConflictFilter(conflict.conflictedPaths)
    }

    package func showStashRestoreConflictStash() {
        guard let conflict = pendingStashRestoreConflict else { return }
        requestStashSelection(conflict.stashReference)
    }

    package func selectGitReference(_ reference: GitReference?) async {
        selectedGitReference = reference
        isShowingAllGitReferences = reference == nil
        canLoadMoreGitHistory = false
        await refreshGitHistory()
    }

    package func showAllGitReferences() async {
        await selectGitReference(nil)
    }

    private var currentCheckoutHistoryReference: GitReference {
        GitReference(
            fullName: "HEAD",
            shortName: "HEAD",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
    }

    package func refreshGitHistory() async {
        guard let gitRepositoryRoot else { return }
        cancelGitHistoryLoading()
        let generation = gitHistoryGeneration
        let selectedReference = selectedGitReference
        let showsAllReferences = isShowingAllGitReferences
        let historyReference = showsAllReferences
            ? nil
            : (selectedReference ?? currentCheckoutHistoryReference)
        let referencesOperationID = gitHistoryOperationID(kind: "references", generation: generation)
        let pageOperationID = gitHistoryOperationID(kind: "page", generation: generation)
        activeGitHistoryOperationIDs.formUnion([referencesOperationID, pageOperationID])
        isLoadingGitHistory = true
        let previousCommitHash = selectedGitCommit?.hash
        async let references = service.references(
            at: gitRepositoryRoot,
            operationID: referencesOperationID
        )
        async let page = service.historyPage(
            at: gitRepositoryRoot,
            reference: historyReference,
            cursor: nil,
            limit: Self.gitHistoryPageSize,
            operationID: pageOperationID
        )
        let (referenceSnapshot, historyPage) = await (references, page)
        activeGitHistoryOperationIDs.subtract([referencesOperationID, pageOperationID])
        guard gitHistoryGeneration == generation,
              self.gitRepositoryRoot == gitRepositoryRoot,
              selectedGitReference == selectedReference,
              isShowingAllGitReferences == showsAllReferences else {
            if let cursor = historyPage?.nextCursor {
                service.closeHistoryCursor(at: gitRepositoryRoot, cursor: cursor)
            }
            return
        }
        isLoadingGitHistory = false
        guard let historyPage else { return }

        if let referenceSnapshot {
            gitReferences = referenceSnapshot.references
            recentGitReferences = referenceSnapshot.recentReferences
            gitIdentity = referenceSnapshot.identity
        }
        gitCommits = historyPage.commits
        gitHistoryCursor = historyPage.nextCursor
        canLoadMoreGitHistory = historyPage.hasMore

        let nextCommit = historyPage.commits.first(where: { $0.hash == previousCommitHash })
            ?? historyPage.commits.first
        if let nextCommit {
            if previousCommitHash == nextCommit.hash {
                selectedGitCommit = nextCommit
                await loadGitCommitFiles(for: nextCommit)
            } else {
                await selectGitCommit(nextCommit)
            }
        } else {
            selectedGitCommitFilesGeneration &+= 1
            selectedGitCommit = nil
            selectedGitCommitFiles = []
            selectedGitCommitFilesLoadState = .idle
            selectedGitCommitFile = nil
            selectedGitCommitDiffContext = nil
        }
    }

    package func applyGitLogFilter(_ rawQuery: String) async {
        await applyGitLogFilter(GitLogQuery.parse(rawQuery))
    }

    package func applyGitLogFilter(_ query: GitLogQuery) async {
        gitLogFilterGeneration = UUID()
        let generation = gitLogFilterGeneration
        guard !query.isEmpty else {
            gitLogMatchedCommitHashes = nil
            isFilteringGitLog = false
            return
        }

        isFilteringGitLog = true
        var candidates = gitCommits.filter { query.matchesMetadata($0, identity: gitIdentity) }

        for branchFilter in query.branches {
            guard let repositoryRoot = gitRepositoryRoot else {
                candidates = []
                break
            }
            let references = gitReferences.filter {
                $0.shortName.localizedCaseInsensitiveContains(branchFilter)
                    || $0.fullName.localizedCaseInsensitiveContains(branchFilter)
            }
            var hashes: Set<String> = []
            for reference in references {
                let snapshot = await service.history(
                    at: repositoryRoot,
                    reference: reference,
                    limit: 5_000
                )
                guard gitLogFilterGeneration == generation else { return }
                hashes.formUnion(snapshot.commits.map(\.hash))
            }
            candidates.removeAll { !hashes.contains($0.hash) }
        }

        if !query.paths.isEmpty, let repositoryRoot = gitRepositoryRoot {
            var pathMatched: [GitCommit] = []
            for commit in candidates {
                let paths: Set<String>
                if let cached = commitPathsByHash[commit.hash] {
                    paths = cached
                } else {
                    let outcome = await commitFilesLoader.loadQueryFiles(
                        for: commit,
                        at: repositoryRoot
                    )
                    guard gitLogFilterGeneration == generation else { return }
                    guard case .ready(let files) = outcome else {
                        isFilteringGitLog = false
                        return
                    }
                    paths = Set(files.map(\.path))
                    commitPathsByHash[commit.hash] = paths
                }
                if query.matchesPaths(paths) { pathMatched.append(commit) }
            }
            candidates = pathMatched
        }

        guard gitLogFilterGeneration == generation else { return }
        gitLogMatchedCommitHashes = Set(candidates.map(\.hash))
        isFilteringGitLog = false
    }

    package func loadMoreGitHistory() async {
        guard let gitRepositoryRoot,
              let cursor = gitHistoryCursor,
              canLoadMoreGitHistory,
              !isLoadingGitHistory,
              !isLoadingMoreGitHistory else { return }
        let generation = gitHistoryGeneration
        let selectedReference = selectedGitReference
        let showsAllReferences = isShowingAllGitReferences
        let historyReference = showsAllReferences
            ? nil
            : (selectedReference ?? currentCheckoutHistoryReference)
        let operationID = gitHistoryOperationID(kind: "page-more", generation: generation)
        activeGitHistoryOperationIDs.insert(operationID)
        isLoadingMoreGitHistory = true
        gitHistoryCursor = nil
        let page = await service.historyPage(
            at: gitRepositoryRoot,
            reference: historyReference,
            cursor: cursor,
            limit: Self.gitHistoryPageSize,
            operationID: operationID
        )
        activeGitHistoryOperationIDs.remove(operationID)
        guard gitHistoryGeneration == generation,
              self.gitRepositoryRoot == gitRepositoryRoot,
              selectedGitReference == selectedReference,
              isShowingAllGitReferences == showsAllReferences else {
            if let cursor = page?.nextCursor {
                service.closeHistoryCursor(at: gitRepositoryRoot, cursor: cursor)
            }
            return
        }
        isLoadingMoreGitHistory = false
        guard let page else {
            canLoadMoreGitHistory = false
            return
        }

        let loadedHashes = Set(gitCommits.map(\.hash))
        gitCommits.append(contentsOf: page.commits.filter { !loadedHashes.contains($0.hash) })
        gitHistoryCursor = page.nextCursor
        canLoadMoreGitHistory = page.hasMore
    }

    package func cancelGitHistoryLoading() {
        gitHistoryGeneration = UUID()
        if let gitRepositoryRoot, let cursor = gitHistoryCursor {
            service.closeHistoryCursor(at: gitRepositoryRoot, cursor: cursor)
        }
        gitHistoryCursor = nil
        for operationID in activeGitHistoryOperationIDs {
            service.cancel(operationID: operationID)
        }
        activeGitHistoryOperationIDs.removeAll()
        isLoadingGitHistory = false
        isLoadingMoreGitHistory = false
    }

    private func gitHistoryOperationID(kind: String, generation: UUID) -> String {
        "git-history-\(kind)-\(generation.uuidString)"
    }

    package func selectGitCommit(_ commit: GitCommit) async {
        previewGitCommitSelection(commit)
        await loadGitCommitFiles(for: commit)
    }

    package func previewGitCommitSelection(_ commit: GitCommit) {
        selectedGitCommitFilesGeneration &+= 1
        selectedGitCommit = commit
        guard let gitRepositoryRoot else {
            selectedGitCommitFiles = []
            selectedGitCommitFilesLoadState = .failed
            selectedGitCommitFile = nil
            selectedGitCommitDiffContext = nil
            return
        }
        if let cachedFiles = commitFilesLoader.cachedFiles(for: commit, at: gitRepositoryRoot) {
            selectedGitCommitFiles = cachedFiles
            selectedGitCommitFilesLoadState = .ready
        } else {
            selectedGitCommitFiles = []
            selectedGitCommitFilesLoadState = .loading
        }
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
    }

    package func loadGitCommitFiles(for commit: GitCommit) async {
        guard selectedGitCommit?.hash == commit.hash else { return }
        guard let gitRepositoryRoot else {
            selectedGitCommitFiles = []
            selectedGitCommitFilesLoadState = .failed
            return
        }
        let generation = selectedGitCommitFilesGeneration
        if let cachedFiles = commitFilesLoader.cachedFiles(for: commit, at: gitRepositoryRoot) {
            selectedGitCommitFiles = cachedFiles
            selectedGitCommitFilesLoadState = .ready
            scheduleGitCommitFilesPrefetch(around: commit, at: gitRepositoryRoot)
            return
        }
        selectedGitCommitFilesLoadState = .loading
        let outcome = await commitFilesLoader.loadSelectedFiles(
            for: commit,
            at: gitRepositoryRoot
        )
        guard selectedGitCommitFilesGeneration == generation,
              selectedGitCommit?.hash == commit.hash,
              self.gitRepositoryRoot?.standardizedFileURL
                == gitRepositoryRoot.standardizedFileURL else {
            return
        }
        switch outcome {
        case .ready(let files):
            selectedGitCommitFiles = files
            selectedGitCommitFilesLoadState = .ready
            scheduleGitCommitFilesPrefetch(around: commit, at: gitRepositoryRoot)
        case .failed:
            selectedGitCommitFiles = []
            selectedGitCommitFilesLoadState = .failed
        case .superseded:
            break
        }
    }

    private func scheduleGitCommitFilesPrefetch(
        around commit: GitCommit,
        at repositoryRoot: URL
    ) {
        let candidates = GitCommitFilesPrefetchPlan.candidates(
            in: gitCommits,
            centeredAt: commit.hash,
            radius: Self.commitFilesPrefetchRadius
        )
        commitFilesLoader.replacePrefetchCandidates(candidates, at: repositoryRoot)
    }

    private func clearGitCommitFilesCache() {
        commitPathsByHash = [:]
        selectedGitCommitFilesGeneration &+= 1
        commitFilesLoader.reset()
        selectedGitCommitFiles = []
        selectedGitCommitFilesLoadState = selectedGitCommit == nil ? .idle : .loading
    }

    package func showGitCommitDiff(for file: GitCommitFile) async {
        guard let gitRepositoryRoot, let commit = selectedGitCommit else { return }
        let context = GitCommitDiffContext(
            repositoryRoot: gitRepositoryRoot,
            commit: commit,
            file: file
        )
        closeBranchComparison()
        selectedChange = nil
        selectedDiffPatch = ""
        selectedGitCommitFile = file
        selectedGitCommitDiffContext = context
        diffRows = []
        diffHunks = []
        isLoadingDiff = true
        let document = await service.diffDocument(
            for: commit,
            file: file,
            at: gitRepositoryRoot,
            whitespace: gitDiffWhitespaceMode
        )
        guard selectedGitCommitDiffContext?.id == context.id else { return }
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    package func closeGitCommitDiff() {
        selectedGitCommitDiffContext = nil
        selectedGitCommitFile = nil
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        isLoadingDiff = false
    }

    package func loadBlame(for fileURL: URL) async -> [GitBlameLine] {
        guard let gitRepositoryRoot else { return [] }
        let normalizedURL = fileURL.standardizedFileURL
        let blame = await service.blame(fileURL: normalizedURL, at: gitRepositoryRoot)
        gitBlameLines[normalizedURL] = blame
        return blame
    }

    package func showGitCommit(_ hash: String) async {
        guard gitRepositoryRoot != nil, !hash.allSatisfy({ $0 == "0" }) else { return }
        if gitCommits.isEmpty {
            await refreshGitHistory()
        }
        if let commit = gitCommits.first(where: { $0.hash == hash }) {
            await selectGitCommit(commit)
            return
        }
        guard let gitRepositoryRoot,
              let loaded = await service.commit(withHash: hash, at: gitRepositoryRoot) else { return }
        if !gitCommits.contains(where: { $0.hash == loaded.hash }) {
            gitCommits.insert(loaded, at: 0)
        }
        await selectGitCommit(loaded)
    }

    package func showComparisonWithWorkingTree(for reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommitDiffContext = nil
        selectedChange = nil
        selectedDiffPatch = ""
        isLoadingBranchComparison = true
        branchComparisonRows = []
        let comparison = await service.comparisonWithWorkingTree(
            for: reference,
            at: gitRepositoryRoot
        )
        branchComparison = comparison
        selectedBranchComparisonFile = comparison.files.first
        if let firstFile = comparison.files.first {
            branchComparisonRows = await service.diff(
                for: firstFile,
                against: reference,
                at: gitRepositoryRoot,
                whitespace: gitDiffWhitespaceMode
            )
        }
        isLoadingBranchComparison = false
    }

    package func showComparison(from reference: GitReference, to target: GitReference) async {
        guard let gitRepositoryRoot, reference.id != target.id else { return }
        selectedGitCommitDiffContext = nil
        selectedChange = nil
        selectedDiffPatch = ""
        isLoadingBranchComparison = true
        branchComparisonRows = []
        let comparison = await service.comparison(
            from: reference,
            to: target,
            at: gitRepositoryRoot
        )
        branchComparison = comparison
        selectedBranchComparisonFile = comparison.files.first
        if let firstFile = comparison.files.first {
            branchComparisonRows = await service.diff(
                for: firstFile,
                from: reference,
                to: target,
                at: gitRepositoryRoot,
                whitespace: gitDiffWhitespaceMode
            )
        }
        isLoadingBranchComparison = false
    }

    package func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        guard let gitRepositoryRoot, let comparison = branchComparison else { return }
        selectedBranchComparisonFile = file
        branchComparisonRows = []
        isLoadingBranchComparison = true
        let rows: [DiffRow]
        if let target = comparison.targetReference {
            rows = await service.diff(
                for: file,
                from: comparison.reference,
                to: target,
                at: gitRepositoryRoot,
                whitespace: gitDiffWhitespaceMode
            )
        } else {
            rows = await service.diff(
                for: file,
                against: comparison.reference,
                at: gitRepositoryRoot,
                whitespace: gitDiffWhitespaceMode
            )
        }
        guard selectedBranchComparisonFile?.id == file.id else { return }
        branchComparisonRows = rows
        isLoadingBranchComparison = false
    }

    package func closeBranchComparison() {
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
    }

    package func refreshWorktrees() async {
        worktreeRequestGeneration &+= 1
        let generation = worktreeRequestGeneration
        guard let repositoryRoot = gitRepositoryRoot else {
            gitWorktrees = []
            gitWorktreeLoadState = .idle
            return
        }
        gitWorktreeLoadState = .loading
        let worktrees = await worktreesProvider(repositoryRoot)
        guard generation == worktreeRequestGeneration,
              gitRepositoryRoot?.standardizedFileURL == repositoryRoot.standardizedFileURL,
              !Task.isCancelled else { return }
        if let worktrees {
            gitWorktrees = worktrees
            gitWorktreeLoadState = .ready
        } else {
            gitWorktrees = []
            gitWorktreeLoadState = .failed("Could not load Git worktrees")
        }
    }

    private func worktreeHistoryReference(for worktree: GitWorktree) -> GitReference? {
        if let branch = worktree.branch {
            return gitReferences.first { $0.fullName == branch }
                ?? GitReference(
                    fullName: branch,
                    shortName: worktree.branchName ?? branch,
                    kind: .local,
                    isCurrent: worktree.isCurrent,
                    upstreamShortName: nil
                )
        }
        // A detached worktree must follow its own checkout. Passing nil would
        // make Core use `--all`, which silently replaces this worktree's HEAD
        // history with the repository-wide reference graph.
        return GitReference(
            fullName: "HEAD",
            shortName: "HEAD",
            kind: .local,
            isCurrent: worktree.isCurrent,
            upstreamShortName: nil
        )
    }

    package func inspectWorktree(_ worktree: GitWorktree) async {
        worktreeInspectionRequestGeneration &+= 1
        let generation = worktreeInspectionRequestGeneration
        let inspectionStartedAt = ContinuousClock.now
        guard !worktree.isPrunable else {
            gitWorktreeInspection = nil
            gitWorktreeInspectionLoadState = .failed("The checkout path does not exist")
            return
        }

        // The primary checkout is already observed by the Git feature model.
        // Reuse its settled state without starting another Git scan.
        if worktree.isCurrent, !isLoadingGitHistory {
            gitWorktreeInspection = GitWorktreeInspection(
                worktreeID: worktree.id,
                changes: gitChanges,
                commits: Array(gitCommits.prefix(80)),
                hasMoreCommits: gitCommits.count > 80 || canLoadMoreGitHistory
            )
            gitWorktreeInspectionLoadState = .ready
            service.recordWorktreeInspection(
                worktreeID: worktree.id,
                phase: "reused-state",
                durationMilliseconds: elapsedMilliseconds(since: inspectionStartedAt)
            )
            return
        }

        gitWorktreeInspectionLoadState = .loading
        let reference = worktreeHistoryReference(for: worktree)
        // History is the primary content of this pane. Start it independently
        // from the worktree status scan so a slow or unreadable index cannot
        // keep the commit list behind the loading state.
        async let history = service.history(at: worktree.url, reference: reference, limit: 30)
        async let snapshot = service.snapshot(for: worktree.url)

        let resolvedHistory = await history
        guard generation == worktreeInspectionRequestGeneration, !Task.isCancelled else {
            return
        }

        let initialChanges = worktree.isCurrent ? gitChanges : []
        let initialInspection = GitWorktreeInspection(
            worktreeID: worktree.id,
            changes: initialChanges,
            commits: resolvedHistory.commits,
            hasMoreCommits: resolvedHistory.hasMore,
            hasLoadedChanges: worktree.isCurrent
        )
        gitWorktreeInspection = initialInspection
        gitWorktreeInspectionLoadState = .ready
        service.recordWorktreeInspection(
            worktreeID: worktree.id,
            phase: "history-published",
            durationMilliseconds: elapsedMilliseconds(since: inspectionStartedAt)
        )

        // Do not make the first detail render wait for the full status scan.
        // The larger history window and the status result are both applied only
        // if this worktree is still selected.
        let resolvedChanges = (await snapshot)?.changes ?? []
        guard generation == worktreeInspectionRequestGeneration,
              gitWorktreeInspection?.worktreeID == worktree.id,
              !Task.isCancelled else { return }
        let inspection = GitWorktreeInspection(
            worktreeID: worktree.id,
            changes: resolvedChanges,
            commits: gitWorktreeInspection?.commits ?? resolvedHistory.commits,
            hasMoreCommits: gitWorktreeInspection?.hasMoreCommits ?? resolvedHistory.hasMore,
            hasLoadedChanges: true
        )
        gitWorktreeInspection = inspection
        service.recordWorktreeInspection(
            worktreeID: worktree.id,
            phase: "changes-published",
            durationMilliseconds: elapsedMilliseconds(since: inspectionStartedAt)
        )

        guard inspection.commits.count >= 30 else { return }
        Task { [weak self] in
            guard let self else { return }
            let fullHistory = await self.service.history(
                at: worktree.url,
                reference: reference,
                // Keep the warm cache bounded; older commits can be
                // requested later by pagination or an explicit search.
                limit: 80
            )
            guard generation == self.worktreeInspectionRequestGeneration,
                  self.gitWorktreeInspection?.worktreeID == worktree.id,
                  !Task.isCancelled else { return }
            self.gitWorktreeInspection = GitWorktreeInspection(
                worktreeID: worktree.id,
                changes: self.gitWorktreeInspection?.changes ?? resolvedChanges,
                commits: fullHistory.commits,
                hasMoreCommits: fullHistory.hasMore,
                hasLoadedChanges: self.gitWorktreeInspection?.hasLoadedChanges ?? true
            )
        }
    }

    package func loadMoreWorktreeHistory(for worktree: GitWorktree) async {
        guard let inspection = gitWorktreeInspection,
              inspection.worktreeID == worktree.id,
              inspection.hasMoreCommits,
              !Task.isCancelled else { return }
        let generation = worktreeInspectionRequestGeneration
        let reference = worktreeHistoryReference(for: worktree)
        let nextLimit = inspection.commits.count + 50
        let history = await service.history(at: worktree.url, reference: reference, limit: nextLimit)
        guard generation == worktreeInspectionRequestGeneration,
              gitWorktreeInspection?.worktreeID == worktree.id,
              !Task.isCancelled else { return }
        gitWorktreeInspection = GitWorktreeInspection(
            worktreeID: worktree.id,
            changes: inspection.changes,
            commits: history.commits,
            hasMoreCommits: history.hasMore
        )
    }

    package func createWorktree(
        named rawName: String,
        from reference: GitReference,
        revision: String? = nil,
        at destination: URL
    ) async {
        guard let gitRepositoryRoot, !isPerformingWorktreeOperation else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notify?(String(localized: "Enter a branch name", bundle: .main))
            return
        }
        isPerformingWorktreeOperation = true
        let result = await withGitOperation {
            await service.createWorktree(
                named: name,
                from: reference,
                revision: revision?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : revision,
                at: destination.standardizedFileURL,
                repositoryRoot: gitRepositoryRoot
            )
        }
        isPerformingWorktreeOperation = false
        if result.succeeded {
            notify?(String(
                format: String(localized: "Created worktree for %@", bundle: .main),
                name
            ))
            await refreshWorktrees()
            await refreshGitHistory()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func removeWorktree(_ worktree: GitWorktree, force: Bool) async {
        guard let gitRepositoryRoot, !isPerformingWorktreeOperation else { return }
        isPerformingWorktreeOperation = true
        let result = await withGitOperation {
            await service.removeWorktree(worktree, force: force, at: gitRepositoryRoot)
        }
        isPerformingWorktreeOperation = false
        notify?(result.succeeded
            ? String(
                format: String(localized: "Removed %@", bundle: .main),
                worktree.displayName
            )
            : trimmedMessage(result))
        if result.succeeded {
            if gitWorktreeInspection?.worktreeID == worktree.id {
                // Clear deleted checkout details before the registry refresh so
                // the UI cannot keep rendering a removed path.
                gitWorktreeInspection = nil
                gitWorktreeInspectionLoadState = .idle
            }
            if let removedBranch = worktree.branch,
               selectedGitReference?.fullName == removedBranch {
                // Removing a checkout keeps its branch, but the log should no
                // longer remain scoped to the checkout the user just removed.
                selectedGitReference = nil
                isShowingAllGitReferences = false
            }
        }
        await refreshWorktrees()
        if result.succeeded {
            await refreshGitHistory()
        }
    }

    package func setWorktreeLocked(_ worktree: GitWorktree, locked: Bool) async {
        guard let gitRepositoryRoot, !isPerformingWorktreeOperation else { return }
        isPerformingWorktreeOperation = true
        let result = await withGitOperation {
            if locked {
                await service.lockWorktree(worktree, at: gitRepositoryRoot)
            } else {
                await service.unlockWorktree(worktree, at: gitRepositoryRoot)
            }
        }
        isPerformingWorktreeOperation = false
        let success = String(
            format: String(
                localized: locked ? "Locked %@" : "Unlocked %@",
                bundle: .main
            ),
            worktree.displayName
        )
        notify?(result.succeeded ? success : trimmedMessage(result))
        await refreshWorktrees()
    }

    package func pruneWorktrees() async {
        guard let gitRepositoryRoot, !isPerformingWorktreeOperation else { return }
        isPerformingWorktreeOperation = true
        let result = await withGitOperation { await service.pruneWorktrees(at: gitRepositoryRoot) }
        isPerformingWorktreeOperation = false
        notify?(result.succeeded
            ? String(localized: "Pruned stale worktree records", bundle: .main)
            : trimmedMessage(result))
        await refreshWorktrees()
    }

    package func repairWorktrees() async {
        guard let gitRepositoryRoot, !isPerformingWorktreeOperation else { return }
        isPerformingWorktreeOperation = true
        let result = await withGitOperation { await service.repairWorktrees(at: gitRepositoryRoot) }
        isPerformingWorktreeOperation = false
        notify?(result.succeeded
            ? String(localized: "Repaired worktree records", bundle: .main)
            : trimmedMessage(result))
        await refreshWorktrees()
    }

    package func createBranch(named rawName: String, from reference: GitReference, checkout: Bool) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notify?("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.createBranch(
                named: name,
                from: reference,
                checkout: checkout,
                at: gitRepositoryRoot
            )
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            isShowingAllGitReferences = false
            notify?(checkout ? "Created and checked out \(name)" : "Created branch \(name)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func renameBranch(_ reference: GitReference, to rawName: String) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notify?("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.renameBranch(reference, to: name, at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            isShowingAllGitReferences = false
            closeBranchComparison()
            notify?("Renamed branch to \(name)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func deleteBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation { await service.deleteBranch(reference, at: gitRepositoryRoot) }
        isPerformingBranchOperation = false
        if result.succeeded, let deletion = result.branchDeletion {
            recentlyDeletedBranch = deletion
            notify?(successfulMessage(result, fallback: "Deleted branch \(deletion.name)"))
        } else {
            notify?(result.succeeded ? "Deleted \(reference.shortName)" : trimmedMessage(result))
        }
        await refreshGit()
    }

    /// Rebuilds the deleted branch at its recorded commit. A failure (for
    /// example the name was re-created elsewhere) keeps the record so the user
    /// can retry or close the banner themselves.
    package func restoreRecentlyDeletedBranch() async {
        guard let deletion = recentlyDeletedBranch, let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.createBranch(
                named: deletion.name,
                from: GitReference(
                    fullName: deletion.deletedTarget,
                    shortName: deletion.deletedTarget,
                    kind: .local,
                    isCurrent: false,
                    upstreamShortName: nil
                ),
                checkout: false,
                at: gitRepositoryRoot
            )
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            recentlyDeletedBranch = nil
            notify?("Restored branch \(deletion.name)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func dismissDeletedBranchBanner() {
        recentlyDeletedBranch = nil
    }

    /// Creates a lightweight or annotated tag. Returns `nil` on success so a
    /// dialog can stay open and show the failure where the user typed; the
    /// caller decides whether to surface the returned message itself.
    @discardableResult
    package func createTag(
        at commit: GitCommit,
        name rawName: String,
        message: String
    ) async -> String? {
        guard let gitRepositoryRoot else { return "No Git repository is open" }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a tag name" }
        let annotation = message.trimmingCharacters(in: .whitespacesAndNewlines)
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.createTag(
                named: name,
                at: commit.hash,
                message: annotation.isEmpty ? nil : annotation,
                at: gitRepositoryRoot
            )
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            notify?("Created tag \(name)")
            await refreshGit()
            return nil
        }
        return trimmedMessage(result)
    }

    package func deleteTag(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.deleteTag(named: reference.shortName, at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        if result.succeeded, let deletion = result.tagDeletion {
            recentlyDeletedTag = deletion
            notify?("Deleted tag \(deletion.name)")
        } else {
            notify?(trimmedMessage(result))
        }
        await refreshGit()
    }

    /// Rebuilds the deleted tag at its recorded commit. A failure (for example
    /// the name was re-created elsewhere) keeps the record so the user can
    /// retry or close the banner themselves.
    package func restoreRecentlyDeletedTag() async {
        guard let deletion = recentlyDeletedTag, let gitRepositoryRoot else { return }
        guard deletion.hasConsistentKindAndMessage else {
            recentlyDeletedTag = nil
            notify?("The deleted tag recovery record is invalid")
            return
        }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.createTag(
                named: deletion.name,
                at: deletion.deletedTarget,
                message: deletion.message,
                at: gitRepositoryRoot
            )
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            recentlyDeletedTag = nil
            notify?("Restored tag \(deletion.name)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func dismissDeletedTagBanner() {
        recentlyDeletedTag = nil
    }

    /// Records the merge or rebase commit Git is waiting on once its conflicts are
    /// resolved. Rust refuses while any file is still conflicted, so the failure
    /// message names what is left.
    package func continueGitOperation() async {
        await resolveGitOperation { await service.continueOperation(at: $0) }
    }

    /// Throws away the in-progress operation and restores the pre-operation state.
    package func abortGitOperation() async {
        await resolveGitOperation { await service.abortOperation(at: $0) }
    }

    /// Drops the commit currently being replayed. Rebase only.
    package func skipGitOperationStep() async {
        await resolveGitOperation { await service.skipOperationStep(at: $0) }
    }

    private func resolveGitOperation(
        _ operation: (URL) async -> GitService.CommandResult
    ) async {
        guard let gitRepositoryRoot, !isResolvingGitOperation else { return }
        isResolvingGitOperation = true
        let result = await withGitOperation {
            let result = await operation(gitRepositoryRoot)
            isResolvingGitOperation = false
            // Refresh either way: a rejected continue leaves the operation in place,
            // but a partial resolution may still have changed the conflict list.
            await refreshGit()
            await restoreDeferredIntegrationStashIfFinished()
            return result
        }
        if !result.succeeded {
            notify?(trimmedMessage(result))
        } else if gitOperationState == nil {
            notify?("Git operation finished")
        }
    }

    private func restoreDeferredIntegrationStashIfFinished() async {
        guard gitOperationState == nil,
              let deferredSavedChanges,
              let gitRepositoryRoot else { return }
        self.deferredSavedChanges = nil

        if let stashReference = deferredSavedChanges.stashReference {
            guard let stash = gitStashes.first(where: {
                $0.reference == stashReference
            }) else {
                notify?("Could not find the saved local changes after the Git operation")
                return
            }

            isPerformingBranchOperation = true
            let restored = await recordingGitCommand {
                await service.popStash(stash, at: gitRepositoryRoot)
            }
            isPerformingBranchOperation = false
            if let conflict = restored.stashRestoreConflict {
                presentStashRestoreConflict(
                    conflict,
                    operationTitle: deferredSavedChanges.operationTitle
                )
            } else if !restored.succeeded {
                notify?("Restoring your changes failed: \(trimmedMessage(restored))")
            } else {
                notify?("Restored your local changes")
            }
            await refreshGit()
            return
        }

        guard let shelfID = deferredSavedChanges.shelfID,
              let shelf = gitShelves.first(where: { $0.id == shelfID }) else {
            notify?("Could not find the saved shelf after the Git operation")
            return
        }
        isPerformingShelfOperation = true
        let restored = await restoreShelf(shelf, at: gitRepositoryRoot)
        isPerformingShelfOperation = false
        if restored {
            notify?("Restored your shelved changes")
        }
    }

    package func mergeBranch(_ reference: GitReference) async {
        await startIntegration(.reference(reference), operation: .merge)
    }

    package func rebaseCurrentBranch(onto reference: GitReference) async {
        await startIntegration(.reference(reference), operation: .rebase)
    }

    package func checkoutAndRebase(_ reference: GitReference) async {
        guard let gitRepositoryRoot, reference.kind != .tag, !reference.isCurrent else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.checkoutAndRebase(reference, at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        await reportBranchOperation(
            result,
            success: "Checked out \(reference.shortName) and rebased it onto the previous branch"
        )
    }

    package func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy
    ) async {
        guard let gitRepositoryRoot, reference.kind == .remote else { return }
        isPerformingBranchOperation = true
        let preflight = await service.integrationPreflight(
            for: .reference(reference),
            operation: strategy == .rebase ? .rebase : .merge,
            at: gitRepositoryRoot
        )
        if let preflight, !preflight.isClear {
            switch selectedSaveChangesPolicy {
            case .stash:
                let message = "Lithe auto-stash before pull"
                let stashed = await recordingGitCommand {
                    await service.stash(message: message, includeUntracked: true, at: gitRepositoryRoot)
                }
                guard stashed.succeeded else {
                    isPerformingBranchOperation = false
                    notify?(trimmedMessage(stashed))
                    return
                }
                let result = await withGitOperation {
                    await service.pullRemoteReference(reference, strategy: strategy, at: gitRepositoryRoot)
                }
                isPerformingBranchOperation = false
                await refreshGit()
                if gitOperationState?.hasConflicts == true {
                    if let stash = gitStashes.first(where: { $0.message.contains(message) }) {
                        deferredSavedChanges = GitDeferredSavedChanges(stashReference: stash.reference, operationTitle: "pull")
                    }
                    notify?("拉取产生冲突，改动已保留在暂存中")
                    return
                }
                if let stash = gitStashes.first(where: { $0.message.contains(message) }) {
                    let restored = await service.popStash(stash, at: gitRepositoryRoot)
                    if let conflict = restored.stashRestoreConflict {
                        presentStashRestoreConflict(conflict, operationTitle: "pull")
                        return
                    }
                    guard restored.succeeded else {
                        notify?("恢复本地改动失败：\(trimmedMessage(restored))")
                        return
                    }
                }
                await reportBranchOperation(result, success: strategy == .rebase ? "从远程分支变基拉取完成" : "从远程分支合并拉取完成")
                return
            case .shelve:
                let capture = await captureAndCleanShelf(message: "Lithe shelf before pull", at: gitRepositoryRoot)
                guard case .saved(let shelf) = capture else {
                    isPerformingBranchOperation = false
                    if case .failed(let message) = capture { notify?(message) }
                    return
                }
                let result = await withGitOperation {
                    await service.pullRemoteReference(reference, strategy: strategy, at: gitRepositoryRoot)
                }
                isPerformingBranchOperation = false
                await refreshGit()
                if gitOperationState?.hasConflicts == true {
                    deferredSavedChanges = GitDeferredSavedChanges(shelfID: shelf.id, operationTitle: "pull")
                    notify?("拉取产生冲突，改动已保留在搁置中")
                    return
                }
                if !(await restoreShelf(shelf, at: gitRepositoryRoot)) {
                    notify?("恢复搁置改动失败")
                    return
                }
                await reportBranchOperation(result, success: strategy == .rebase ? "从远程分支变基拉取完成" : "从远程分支合并拉取完成")
                return
            }
        }
        let result = await withGitOperation {
            await service.pullRemoteReference(reference, strategy: strategy, at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        let verb = strategy == .rebase ? "Rebased from" : "Merged from"
        await reportBranchOperation(result, success: "\(verb) \(reference.shortName)")
    }

    /// Checks whether uncommitted changes would stop the operation before running
    /// it, so the user gets a choice instead of Git's localized refusal.
    private func startIntegration(
        _ target: GitIntegrationTarget,
        operation: GitIntegrationOperation
    ) async {
        guard let gitRepositoryRoot else { return }
        let preflight = await service.integrationPreflight(
            for: target,
            operation: operation,
            at: gitRepositoryRoot
        )
        if let preflight, !preflight.isClear {
            pendingIntegrationConflict = GitIntegrationConflictRequest(
                target: target,
                operation: operation,
                blockingPaths: preflight.blockingPaths,
                blocksEntirely: preflight.blocksEntirely
            )
            return
        }
        await runIntegration(target, operation: operation)
    }

    /// Saves the blocking changes, runs the operation, then restores them.
    ///
    /// The stash is left alone when the operation stops on a conflict: popping into
    /// a half-finished merge would tangle the user's own edits with the conflict
    /// markers they still have to resolve.
    package func resolveIntegrationConflict(_ request: GitIntegrationConflictRequest) async {
        pendingIntegrationConflict = nil
        guard let gitRepositoryRoot else { return }
        await withGitOperation {
            switch selectedSaveChangesPolicy {
            case .stash:
                await resolveIntegrationWithStash(request, at: gitRepositoryRoot)
            case .shelve:
                await resolveIntegrationWithShelf(request, at: gitRepositoryRoot)
            }
        }
    }

    private func resolveIntegrationWithStash(
        _ request: GitIntegrationConflictRequest,
        at repositoryRoot: URL
    ) async {
        isPerformingBranchOperation = true
        let stashMessage = "Lithe auto-stash before \(request.operation.rawValue)"
        let stashed = await recordingGitCommand {
            await service.stash(
                message: stashMessage,
                includeUntracked: true,
                at: repositoryRoot
            )
        }
        guard stashed.succeeded else {
            isPerformingBranchOperation = false
            notify?(trimmedMessage(stashed))
            return
        }
        isPerformingBranchOperation = false

        await runIntegration(request.target, operation: request.operation)

        if let state = gitOperationState, state.hasConflicts {
            if let stash = gitStashes.first(where: { $0.message.contains(stashMessage) }) {
                deferredSavedChanges = GitDeferredSavedChanges(
                    stashReference: stash.reference,
                    operationTitle: request.operation.title.lowercased()
                )
            }
            notify?("Your changes stay stashed until the \(request.operation.title.lowercased()) is finished")
            return
        }
        guard let entry = gitStashes.first(where: { $0.message.contains(stashMessage) }) else {
            notify?("Could not find the stashed changes to restore")
            return
        }
        isPerformingBranchOperation = true
        let restored = await recordingGitCommand {
            await service.popStash(entry, at: repositoryRoot)
        }
        isPerformingBranchOperation = false
        if let conflict = restored.stashRestoreConflict {
            presentStashRestoreConflict(
                conflict,
                operationTitle: request.operation.title.lowercased()
            )
        } else if !restored.succeeded {
            notify?("Restoring your changes failed: \(trimmedMessage(restored))")
        }
        await refreshGit()
    }

    private func resolveIntegrationWithShelf(
        _ request: GitIntegrationConflictRequest,
        at repositoryRoot: URL
    ) async {
        isPerformingBranchOperation = true
        let capture = await captureAndCleanShelf(
            message: "Lithe shelf before \(request.operation.rawValue)",
            at: repositoryRoot
        )
        isPerformingBranchOperation = false
        guard case .saved(let shelf) = capture else {
            if case .failed(let message) = capture { notify?(message) }
            return
        }

        await runIntegration(request.target, operation: request.operation)
        if let state = gitOperationState, state.hasConflicts {
            deferredSavedChanges = GitDeferredSavedChanges(
                shelfID: shelf.id,
                operationTitle: request.operation.title.lowercased()
            )
            notify?("Your shelved changes stay saved until the \(request.operation.title.lowercased()) is finished")
            return
        }

        isPerformingShelfOperation = true
        let restored = await restoreShelf(shelf, at: repositoryRoot)
        isPerformingShelfOperation = false
        if restored {
            notify?("Restored your shelved changes")
        }
    }

    package func cancelIntegrationConflict() {
        pendingIntegrationConflict = nil
    }

    private func runIntegration(
        _ target: GitIntegrationTarget,
        operation: GitIntegrationOperation
    ) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let operationResult = await withGitOperation {
            let result: GitService.CommandResult
            let success: String
            let name = target.displayName
            switch operation {
            case .merge:
                result = await recordingGitCommand {
                    await service.mergeBranch(reference(from: target), at: gitRepositoryRoot)
                }
                success = "Merged \(name)"
            case .rebase:
                result = await recordingGitCommand {
                    await service.rebaseCurrentBranch(
                        onto: reference(from: target),
                        at: gitRepositoryRoot
                    )
                }
                success = "Rebased onto \(name)"
            case .cherryPick:
                result = await recordingGitCommand {
                    await service.cherryPick(target.revision, at: gitRepositoryRoot)
                }
                success = "Cherry-picked \(name)"
            case .revert:
                result = await recordingGitCommand {
                    await service.revert(target.revision, at: gitRepositoryRoot)
                }
                success = "Reverted \(name)"
            }
            return (result, success)
        }
        isPerformingBranchOperation = false
        await reportBranchOperation(operationResult.0, success: operationResult.1)
    }

    /// Merge and rebase are only ever started from a branch, so a commit target here
    /// would be a programming error rather than something the user can reach.
    private func reference(from target: GitIntegrationTarget) -> GitReference {
        switch target {
        case .reference(let reference):
            return reference
        case .commit(let commit):
            assertionFailure("Merge and rebase expect a branch, not \(commit.shortHash)")
            return GitReference(
                fullName: commit.hash,
                shortName: commit.shortHash,
                kind: .local,
                isCurrent: false,
                upstreamShortName: nil
            )
        }
    }

    /// Refreshes before reporting so a conflict stop can be named as such. Git's own
    /// stderr for a conflicted merge is a wall of per-file lines; the banner is where
    /// the user acts on it, so the toast just points at the conflict count.
    private func reportBranchOperation(
        _ result: GitService.CommandResult,
        success: String
    ) async {
        await refreshGit()
        if let state = gitOperationState, state.hasConflicts {
            notify?("\(state.kind.title) stopped with \(state.conflictedPaths.count) conflicted file(s)")
        } else {
            notify?(result.succeeded ? successfulMessage(result, fallback: success) : trimmedMessage(result))
        }
    }

    package func updateCurrentBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot, reference.isCurrent else {
            notify?("Only the current branch can be updated")
            return
        }
        // Fetch first so the divergence check reflects the remote as it is now;
        // otherwise a stale ref would send a pull down the wrong path.
        isPerformingBranchOperation = true
        let fetched = await withGitOperation { await service.fetch(at: gitRepositoryRoot) }
        guard fetched.succeeded else {
            isPerformingBranchOperation = false
            notify?(trimmedMessage(fetched))
            return
        }

        let preflight = await service.pullPreflight(at: gitRepositoryRoot)
        if let preflight, preflight.upstream == nil {
            isPerformingBranchOperation = false
            notify?("\(reference.shortName) tracks no remote branch")
            await refreshGit()
            return
        }
        if let preflight, preflight.isUpToDate {
            isPerformingBranchOperation = false
            notify?("\(reference.shortName) is already up to date")
            await refreshGit()
            return
        }
        // Only a divergent history needs a decision. Git would refuse it with a
        // localized hint block, so we ask before running anything.
        if let preflight, preflight.diverged {
            isPerformingBranchOperation = false
            pendingPullStrategy = GitPullStrategyRequest(
                upstream: preflight.upstream ?? "",
                ahead: preflight.ahead,
                behind: preflight.behind,
                hasLocalChanges: preflight.hasLocalChanges
            )
            return
        }

        let result = await withGitOperation {
            await service.updateCurrentBranch(at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        await reportBranchOperation(result, success: "Updated \(reference.shortName)")
    }

    /// Runs the pull the user chose from the divergence dialog.
    package func resolvePullStrategy(_ strategy: GitPullStrategy) async {
        pendingPullStrategy = nil
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.updateCurrentBranch(at: gitRepositoryRoot, strategy: strategy)
        }
        isPerformingBranchOperation = false
        let verb = strategy == .rebase ? "Rebased onto upstream" : "Merged upstream"
        await reportBranchOperation(result, success: verb)
    }

    package func cancelPullStrategy() {
        pendingPullStrategy = nil
    }

    package func fetchGit() async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation { await service.fetch(at: gitRepositoryRoot) }
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Fetched Git remotes" : trimmedMessage(result))
        await refreshGit()
    }

    package func checkoutReference(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        guard !reference.isCurrent else {
            notify?("Already on \(reference.shortName)")
            return
        }
        isPerformingBranchOperation = true
        let blockingPaths = await service.checkoutBlockingPaths(
            for: reference,
            at: gitRepositoryRoot
        )
        isPerformingBranchOperation = false
        guard blockingPaths.isEmpty else {
            pendingCheckoutConflict = GitCheckoutConflictRequest(
                reference: reference,
                blockingPaths: blockingPaths
            )
            return
        }
        await performCheckout(reference)
    }

    /// Resolves a blocked checkout with the strategy the user picked in the conflict dialog.
    package func resolveCheckoutConflict(
        _ request: GitCheckoutConflictRequest,
        strategy: GitCheckoutConflictStrategy
    ) async {
        pendingCheckoutConflict = nil
        switch strategy {
        case .smart:
            await performCheckout(request.reference, autoStash: true)
        case .force:
            await performCheckout(request.reference, force: true)
        }
    }

    private func performCheckout(
        _ reference: GitReference,
        force: Bool = false,
        autoStash: Bool = false
    ) async {
        guard let gitRepositoryRoot else { return }
        if autoStash && selectedSaveChangesPolicy == .shelve {
            await performShelvedCheckout(reference, at: gitRepositoryRoot)
            return
        }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.checkout(
                reference,
                at: gitRepositoryRoot,
                force: force,
                autoStash: autoStash
            )
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            isShowingAllGitReferences = false
            closeBranchComparison()
            if autoStash {
                notify?("Checked out \(reference.shortName) and restored local changes")
            } else if force {
                notify?("Checked out \(reference.shortName), discarding local changes")
            } else {
                notify?("Checked out \(reference.shortName)")
            }
            await refreshGit()
        } else {
            if let conflict = result.stashRestoreConflict {
                presentStashRestoreConflict(conflict, operationTitle: "checkout")
            } else {
                notify?(trimmedMessage(result))
            }
            if autoStash {
                // A smart checkout can switch branches and still fail to restore the stash,
                // so re-read Git rather than assuming the working tree is unchanged.
                selectedGitReference = nil
                isShowingAllGitReferences = false
                closeBranchComparison()
                await refreshGit()
            }
        }
    }

    private func performShelvedCheckout(_ reference: GitReference, at repositoryRoot: URL) async {
        guard shelveService != nil else {
            await performCheckout(reference, autoStash: true)
            return
        }
        isPerformingBranchOperation = true
        let capture = await withGitOperation {
            await captureAndCleanShelf(
                message: "Lithe shelf before checkout",
                at: repositoryRoot
            )
        }
        guard case .saved(let shelf) = capture else {
            isPerformingBranchOperation = false
            if case .failed(let message) = capture { notify?(message) }
            return
        }

        let result = await withGitOperation {
            await service.checkout(
                reference,
                at: repositoryRoot,
                force: false,
                autoStash: false
            )
        }
        guard result.succeeded else {
            _ = await withGitOperation { await restoreShelf(shelf, at: repositoryRoot) }
            isPerformingBranchOperation = false
            notify?(trimmedMessage(result))
            return
        }

        selectedGitReference = nil
        isShowingAllGitReferences = false
        closeBranchComparison()
        await refreshGit()
        isPerformingShelfOperation = true
        let restored = await withGitOperation { await restoreShelf(shelf, at: repositoryRoot) }
        isPerformingShelfOperation = false
        isPerformingBranchOperation = false
        if restored {
            notify?("Checked out \(reference.shortName) and restored shelved changes")
        }
    }

    package func checkoutRevision(_ rawRevision: String) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.checkoutRevision(rawRevision, at: gitRepositoryRoot)
        }
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            isShowingAllGitReferences = false
            closeBranchComparison()
            notify?("Checked out \(rawRevision) in detached HEAD")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    package func cherryPick(_ commit: GitCommit) async {
        await startIntegration(.commit(commit), operation: .cherryPick)
    }

    package func revert(_ commit: GitCommit) async {
        await startIntegration(.commit(commit), operation: .revert)
    }

    package func resetCurrentBranch(to commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation {
            await service.resetCurrentBranch(
                to: commit.hash,
                at: gitRepositoryRoot,
                mode: "--mixed"
            )
        }
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Reset current branch to \(commit.shortHash)" : trimmedMessage(result))
        await refreshGit()
    }

    package func pushBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await withGitOperation { await service.push(reference, at: gitRepositoryRoot) }
        isPerformingBranchOperation = false
        notify?(
            result.succeeded
                ? successfulMessage(result, fallback: "Pushed \(reference.shortName)")
                : trimmedMessage(result)
        )
        await refreshGit()
    }

    @discardableResult
    package func cloneRepository(
        remote rawRemote: String,
        destination: URL,
        destinationExists: (URL) -> Bool
    ) async -> GitService.CommandResult {
        let remote = rawRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            return GitService.CommandResult(output: "Enter a repository URL", exitCode: 1)
        }
        guard !destination.path.isEmpty else {
            return GitService.CommandResult(output: "Choose a destination folder", exitCode: 1)
        }
        guard !destinationExists(destination) else {
            return GitService.CommandResult(output: "The destination folder already exists", exitCode: 1)
        }

        isCloningRepository = true
        defer { isCloningRepository = false }
        return await withGitOperation {
            await service.cloneRepository(from: remote, to: destination)
        }
    }

    private func showResult(_ result: GitService.CommandResult, success: String) {
        notify?(result.succeeded ? successfulMessage(result, fallback: success) : trimmedMessage(result))
    }

    private func successfulMessage(_ result: GitService.CommandResult, fallback: String) -> String {
        guard let warning = result.warnings.first else { return fallback }
        return "\(fallback): \(warning.message)"
    }

    private func trimmedMessage(_ result: GitService.CommandResult) -> String {
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git operation failed" : message
    }
}

package enum GitCommitFilesPrefetchPlan {
    package static func candidates(
        in commits: [GitCommit],
        centeredAt commitHash: String,
        radius: Int
    ) -> [GitCommit] {
        guard radius > 0,
              let centerIndex = commits.firstIndex(where: { $0.hash == commitHash }) else {
            return []
        }

        var candidates: [GitCommit] = []
        for distance in 1...radius {
            let olderIndex = centerIndex + distance
            if commits.indices.contains(olderIndex) {
                candidates.append(commits[olderIndex])
            }
            let newerIndex = centerIndex - distance
            if commits.indices.contains(newerIndex) {
                candidates.append(commits[newerIndex])
            }
        }
        return candidates
    }
}
