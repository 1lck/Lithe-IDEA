import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Owns Git state and Git workflows while keeping the UI-specific panel state
/// in AppModel. Git command construction and parsing remain in GitService/Core.
@MainActor
package final class GitFeatureModel: ObservableObject {
    @Published package private(set) var gitChanges: [GitChange] = []
    @Published package private(set) var gitStashes: [GitStash] = []
    @Published package private(set) var gitShelves: [GitShelfEntry] = []
    @Published package private(set) var isPerformingStashOperation = false
    @Published package private(set) var isPerformingShelfOperation = false
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
    @Published package private(set) var gitConflictFilterPaths: Set<String> = []
    @Published package private(set) var requestedStashReference: String?
    /// Set whenever Git is mid-merge, mid-rebase, mid-cherry-pick, or mid-revert.
    @Published package var gitOperationState: GitOperationState?
    @Published package var isResolvingGitOperation = false
    @Published package private(set) var isCommitting = false
    @Published package private(set) var gitBlameLines: [URL: [GitBlameLine]] = [:]
    @Published package private(set) var gitReferences: [GitReference] = []
    @Published package private(set) var gitCommits: [GitCommit] = []
    @Published package var selectedGitReference: GitReference?
    @Published package var selectedGitCommit: GitCommit?
    @Published package private(set) var selectedGitCommitFiles: [GitCommitFile] = []
    @Published package var selectedGitCommitFile: GitCommitFile?
    @Published package var selectedGitCommitDiffContext: GitCommitDiffContext?
    @Published package private(set) var isLoadingGitHistory = false
    @Published package private(set) var isLoadingMoreGitHistory = false
    @Published package private(set) var canLoadMoreGitHistory = false
    @Published package private(set) var branchComparison: GitBranchComparison?
    @Published package var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published package private(set) var branchComparisonRows: [DiffRow] = []
    @Published package private(set) var isLoadingBranchComparison = false
    @Published package private(set) var isPerformingBranchOperation = false
    @Published package private(set) var isCloningRepository = false

    private let service: GitService
    private let shelveService: ShelveService?
    private let snapshotProvider: @Sendable (URL) async -> GitSnapshot?
    private let stashesProvider: @Sendable (URL) async -> [GitStash]
    private let operationStateProvider: @Sendable (URL) async -> GitOperationState?
    private let diffDocumentProvider: @Sendable (GitChange, GitDiffWhitespaceMode) async -> DiffDocument
    private var workspaceURLProvider: (@MainActor () -> URL?)?
    private var isGitLogVisibleProvider: (@MainActor () -> Bool)?
    private var notify: (@MainActor (String) -> Void)?
    private var onStateRefreshed: (@MainActor () async -> Void)?
    private var saveChangesPolicy: (@MainActor () -> GitSaveChangesPolicy)?
    private var onGitOperationBegan: (@MainActor () -> Void)?
    private var onGitOperationEnded: (@MainActor () async -> Void)?
    private var acquireModuleLease: (@MainActor (String) -> ModuleLease)?
    private var gitHistoryLimit = 300
    private var deferredSavedChanges: GitDeferredSavedChanges?
    private var refreshRequestedWhileRunning = false


    package init(
        service: GitService,
        shelveService: ShelveService? = nil,
        snapshotProvider: (@Sendable (URL) async -> GitSnapshot?)? = nil,
        stashesProvider: (@Sendable (URL) async -> [GitStash])? = nil,
        operationStateProvider: (@Sendable (URL) async -> GitOperationState?)? = nil,
        diffDocumentProvider: (@Sendable (GitChange, GitDiffWhitespaceMode) async -> DiffDocument)? = nil
    ) {
        self.service = service
        self.shelveService = shelveService
        self.snapshotProvider = snapshotProvider ?? { await service.snapshot(for: $0) }
        self.stashesProvider = stashesProvider ?? { await service.stashes(at: $0) }
        self.operationStateProvider = operationStateProvider ?? { await service.operationState(at: $0) }
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
            || isLoadingDiff
            || isRefreshingGit
            || isCommitting
            || isLoadingGitHistory
            || isLoadingMoreGitHistory
            || isLoadingBranchComparison
            || isPerformingBranchOperation
            || isCloningRepository
            || isResolvingGitOperation
    }

    package func reset() {
        gitChanges = []
        gitStashes = []
        gitShelves = []
        gitOperationState = nil
        pendingPullStrategy = nil
        pendingIntegrationConflict = nil
        pendingConflictRollback = nil
        pendingStashRestoreConflict = nil
        isStashRestoreConflictNoticeVisible = false
        gitConflictFilterPaths = []
        requestedStashReference = nil
        deferredSavedChanges = nil
        isPerformingStashOperation = false
        isPerformingShelfOperation = false
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        selectedDiffPatch = ""
        diffRows = []
        diffHunks = []
        gitDiffWhitespaceMode = .doNotIgnore
        isLoadingDiff = false
        isRefreshingGit = false
        refreshRequestedWhileRunning = false
        pendingDiscardChange = nil
        pendingDiscardHunk = nil
        isCommitting = false
        gitBlameLines = [:]
        gitReferences = []
        gitCommits = []
        gitHistoryLimit = 300
        isLoadingGitHistory = false
        isLoadingMoreGitHistory = false
        canLoadMoreGitHistory = false
        selectedGitReference = nil
        selectedGitCommit = nil
        selectedGitCommitFiles = []
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
        if isRefreshingGit {
            refreshRequestedWhileRunning = true
            return
        }
        guard let workspaceURL = workspaceURLProvider() else {
            reset()
            return
        }

        isRefreshingGit = true
        repeat {
            refreshRequestedWhileRunning = false
            await refreshGitState(at: workspaceURL)
        } while refreshRequestedWhileRunning && workspaceURLProvider() == workspaceURL
        isRefreshingGit = false
    }

    private func refreshGitState(at workspaceURL: URL) async {
        var didChange = false
        if let snapshot = await snapshotProvider(workspaceURL) {
            let changesChanged = gitChanges != snapshot.changes
            if gitRepositoryRoot != snapshot.repositoryRoot {
                gitRepositoryRoot = snapshot.repositoryRoot
                didChange = true
            }
            if currentBranch != snapshot.branch {
                currentBranch = snapshot.branch
                didChange = true
            }
            if changesChanged {
                gitChanges = snapshot.changes
                didChange = true
            }
            if !gitConflictFilterPaths.isEmpty {
                let previousFilter = gitConflictFilterPaths
                gitConflictFilterPaths.formIntersection(Set(snapshot.changes.map(\.path)))
                didChange = didChange || previousFilter != gitConflictFilterPaths
            }
            let stashes = await stashesProvider(snapshot.repositoryRoot)
            if gitStashes != stashes {
                gitStashes = stashes
                didChange = true
            }
            let shelves = await shelveService?.entries(for: snapshot.repositoryRoot) ?? []
            if gitShelves != shelves {
                gitShelves = shelves
                didChange = true
            }
            let operationState = await operationStateProvider(snapshot.repositoryRoot)
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
            if gitRepositoryRoot != nil { gitRepositoryRoot = nil; didChange = true }
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
            await refreshGitHistory()
        }
        if didChange {
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

    package func selectConflictPath(_ path: String) async {
        guard let change = gitChanges.first(where: { $0.path == path }) else { return }
        await selectChange(change)
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
        await onGitOperationEnded?()
        return result
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

    package func toggleStaging(_ change: GitChange) async {
        selectedChange = change
        let result = await withGitOperation {
            change.isStaged
                ? await service.unstage(change)
                : await service.stage(change)
        }
        let verb = change.isStaged ? "Unstaged" : "Staged"
        showResult(result, success: "\(verb) \(change.path)")
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
            let discarded = await service.discardAll(change)
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
            let result = await service.applyPatch(
                shelf.stagedPatch,
                at: repositoryRoot,
                mode: "restoreIndex"
            )
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
            let result = await service.applyPatch(
                shelf.workingPatch,
                at: repositoryRoot,
                mode: "worktree"
            )
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
        gitHistoryLimit = 300
        canLoadMoreGitHistory = false
        await refreshGitHistory()
    }

    package func refreshGitHistory() async {
        guard let gitRepositoryRoot, !isLoadingGitHistory else { return }
        isLoadingGitHistory = true
        let previousCommitHash = selectedGitCommit?.hash
        let snapshot = await service.history(
            at: gitRepositoryRoot,
            reference: selectedGitReference,
            limit: gitHistoryLimit
        )
        gitReferences = snapshot.references
        gitCommits = snapshot.commits
        canLoadMoreGitHistory = snapshot.hasMore

        let nextCommit = snapshot.commits.first(where: { $0.hash == previousCommitHash })
            ?? snapshot.commits.first
        isLoadingGitHistory = false
        if let nextCommit {
            if previousCommitHash == nextCommit.hash {
                selectedGitCommit = nextCommit
            } else {
                await selectGitCommit(nextCommit)
            }
        } else {
            selectedGitCommit = nil
            selectedGitCommitFiles = []
            selectedGitCommitFile = nil
            selectedGitCommitDiffContext = nil
        }
    }

    package func loadMoreGitHistory() async {
        guard canLoadMoreGitHistory, !isLoadingGitHistory else { return }
        isLoadingMoreGitHistory = true
        defer { isLoadingMoreGitHistory = false }
        gitHistoryLimit += 300
        await refreshGitHistory()
    }

    package func selectGitCommit(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommit = commit
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        let files = await service.files(in: commit, at: gitRepositoryRoot)
        guard selectedGitCommit?.hash == commit.hash else { return }
        selectedGitCommitFiles = files
        selectedGitCommitFile = files.first
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

    package func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
        guard let gitRepositoryRoot, let comparison = branchComparison else { return }
        selectedBranchComparisonFile = file
        branchComparisonRows = []
        isLoadingBranchComparison = true
        let rows = await service.diff(
            for: file,
            against: comparison.reference,
            at: gitRepositoryRoot,
            whitespace: gitDiffWhitespaceMode
        )
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
        notify?(result.succeeded ? "Deleted \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
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
            let restored = await service.popStash(stash, at: gitRepositoryRoot)
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
        let stashed = await service.stash(
            message: stashMessage,
            includeUntracked: true,
            at: repositoryRoot
        )
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
        let restored = await service.popStash(entry, at: repositoryRoot)
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
                result = await service.mergeBranch(reference(from: target), at: gitRepositoryRoot)
                success = "Merged \(name)"
            case .rebase:
                result = await service.rebaseCurrentBranch(
                    onto: reference(from: target),
                    at: gitRepositoryRoot
                )
                success = "Rebased onto \(name)"
            case .cherryPick:
                result = await service.cherryPick(target.revision, at: gitRepositoryRoot)
                success = "Cherry-picked \(name)"
            case .revert:
                result = await service.revert(target.revision, at: gitRepositoryRoot)
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
            notify?(result.succeeded ? success : trimmedMessage(result))
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
        notify?(result.succeeded ? "Pushed \(reference.shortName)" : trimmedMessage(result))
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
        notify?(result.succeeded ? success : trimmedMessage(result))
    }

    private func trimmedMessage(_ result: GitService.CommandResult) -> String {
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git operation failed" : message
    }
}
