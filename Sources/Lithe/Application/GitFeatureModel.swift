import Combine
import Foundation

/// Owns Git state and Git workflows while keeping the UI-specific panel state
/// in AppModel. Git command construction and parsing remain in GitService/Core.
@MainActor
final class GitFeatureModel: ObservableObject {
    @Published private(set) var gitChanges: [GitChange] = []
    @Published private(set) var gitStashes: [GitStash] = []
    @Published private(set) var isPerformingStashOperation = false
    @Published private(set) var gitRepositoryRoot: URL?
    @Published private(set) var currentBranch = "No Git"
    @Published var selectedChange: GitChange?
    @Published private(set) var diffRows: [DiffRow] = []
    @Published private(set) var diffHunks: [DiffHunk] = []
    @Published var gitDiffWhitespaceMode = GitDiffWhitespaceMode.doNotIgnore
    @Published private(set) var isLoadingDiff = false
    @Published private(set) var isRefreshingGit = false
    @Published var pendingDiscardChange: GitChange?
    @Published var pendingDiscardHunk: DiffHunkRequest?
    @Published private(set) var isCommitting = false
    @Published private(set) var gitBlameLines: [URL: [GitBlameLine]] = [:]
    @Published private(set) var gitReferences: [GitReference] = []
    @Published private(set) var gitCommits: [GitCommit] = []
    @Published var selectedGitReference: GitReference?
    @Published var selectedGitCommit: GitCommit?
    @Published private(set) var selectedGitCommitFiles: [GitCommitFile] = []
    @Published var selectedGitCommitFile: GitCommitFile?
    @Published var selectedGitCommitDiffContext: GitCommitDiffContext?
    @Published private(set) var isLoadingGitHistory = false
    @Published private(set) var isLoadingMoreGitHistory = false
    @Published private(set) var canLoadMoreGitHistory = false
    @Published private(set) var branchComparison: GitBranchComparison?
    @Published var selectedBranchComparisonFile: GitBranchComparisonFile?
    @Published private(set) var branchComparisonRows: [DiffRow] = []
    @Published private(set) var isLoadingBranchComparison = false
    @Published private(set) var isPerformingBranchOperation = false
    @Published private(set) var isCloningRepository = false

    private let service: GitService
    private var workspaceURLProvider: (@MainActor () -> URL?)?
    private var isGitLogVisibleProvider: (@MainActor () -> Bool)?
    private var notify: (@MainActor (String) -> Void)?
    private var onStateRefreshed: (@MainActor () async -> Void)?
    private var gitHistoryLimit = 300

    init(service: GitService) {
        self.service = service
    }

    func configure(
        workspaceURLProvider: @escaping @MainActor () -> URL?,
        isGitLogVisibleProvider: @escaping @MainActor () -> Bool,
        notify: @escaping @MainActor (String) -> Void,
        onStateRefreshed: @escaping @MainActor () async -> Void
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.isGitLogVisibleProvider = isGitLogVisibleProvider
        self.notify = notify
        self.onStateRefreshed = onStateRefreshed
    }

    var currentGitReference: GitReference? {
        gitReferences.first(where: \.isCurrent)
    }

    func reset() {
        gitChanges = []
        gitStashes = []
        isPerformingStashOperation = false
        gitRepositoryRoot = nil
        currentBranch = "No Git"
        selectedChange = nil
        diffRows = []
        diffHunks = []
        gitDiffWhitespaceMode = .doNotIgnore
        isLoadingDiff = false
        isRefreshingGit = false
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
    }

    func refreshGit() async {
        guard let workspaceURLProvider, !isRefreshingGit else { return }
        guard let workspaceURL = workspaceURLProvider() else {
            reset()
            return
        }

        isRefreshingGit = true
        defer { isRefreshingGit = false }

        if let snapshot = await service.snapshot(for: workspaceURL) {
            gitRepositoryRoot = snapshot.repositoryRoot
            currentBranch = snapshot.branch
            gitChanges = snapshot.changes
            gitStashes = await service.stashes(at: snapshot.repositoryRoot)

            if let selectedChange,
               let updated = snapshot.changes.first(where: { $0.path == selectedChange.path }) {
                self.selectedChange = updated
                let document = await service.diffDocument(
                    for: updated,
                    whitespace: gitDiffWhitespaceMode
                )
                diffRows = document.rows
                diffHunks = document.hunks
            } else if selectedChange != nil {
                self.selectedChange = nil
                diffRows = []
                diffHunks = []
                isLoadingDiff = false
            }
        } else {
            gitRepositoryRoot = nil
            currentBranch = "No Git"
            gitChanges = []
            gitStashes = []
            selectedChange = nil
            diffRows = []
            diffHunks = []
            isLoadingDiff = false
        }

        if isGitLogVisibleProvider?() == true {
            await refreshGitHistory()
        }
        await onStateRefreshed?()
    }

    func selectChange(_ change: GitChange) async {
        closeBranchComparison()
        selectedGitCommitDiffContext = nil
        selectedChange = change
        diffRows = []
        diffHunks = []
        isLoadingDiff = true
        let document = await service.diffDocument(
            for: change,
            whitespace: gitDiffWhitespaceMode
        )
        guard selectedChange?.id == change.id else { return }
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    func reloadSelectedChangeDiff(whitespace: GitDiffWhitespaceMode) async {
        gitDiffWhitespaceMode = whitespace
        guard let selectedChange else { return }
        isLoadingDiff = true
        let document = await service.diffDocument(for: selectedChange, whitespace: whitespace)
        guard self.selectedChange?.id == selectedChange.id else { return }
        diffRows = document.rows
        diffHunks = document.hunks
        isLoadingDiff = false
    }

    func stageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await service.stage(selectedChange)
        showResult(result, success: "Staged \(selectedChange.path)")
        await refreshGit()
    }

    func unstageSelectedChange() async {
        guard let selectedChange else { return }
        let result = await service.unstage(selectedChange)
        showResult(result, success: "Unstaged \(selectedChange.path)")
        await refreshGit()
    }

    func stageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await service.stage(hunk: hunk, of: change)
        showResult(result, success: "Staged a change block in \(change.path)")
        await refreshGit()
    }

    func unstageDiffHunk(_ hunk: DiffHunk, in change: GitChange) async {
        let result = await service.unstage(hunk: hunk, of: change)
        showResult(result, success: "Unstaged a change block in \(change.path)")
        await refreshGit()
    }

    func requestDiscardHunk(_ hunk: DiffHunk, in change: GitChange) {
        pendingDiscardHunk = DiffHunkRequest(change: change, hunk: hunk)
    }

    func confirmDiscardHunk() async {
        guard let request = pendingDiscardHunk else { return }
        pendingDiscardHunk = nil
        let result = await service.discard(hunk: request.hunk, of: request.change)
        showResult(result, success: "Discarded a change block in \(request.change.path)")
        await refreshGit()
    }

    func cancelDiscardHunk() {
        pendingDiscardHunk = nil
    }

    func requestDiscardSelectedChange() {
        requestDiscardChange(selectedChange)
    }

    /// Opens the existing discard confirmation for a specific row.
    ///
    /// Context-menu actions can be invoked before the row has finished
    /// becoming the selected change, so they must not rely on
    /// `selectedChange` being up to date.
    func requestDiscardChange(_ change: GitChange?) {
        pendingDiscardChange = change
    }

    func confirmDiscardChange() async {
        guard let change = pendingDiscardChange else { return }
        pendingDiscardChange = nil
        let result = await service.discard(change)
        showResult(result, success: "Discarded \(change.path)")
        await refreshGit()
    }

    func cancelDiscardChange() {
        pendingDiscardChange = nil
    }

    @discardableResult
    func commitStagedChanges(message rawMessage: String, amend: Bool) async -> Bool {
        guard let gitRepositoryRoot else { return false }
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            notify?("Enter a commit message")
            return false
        }

        isCommitting = true
        let result = await service.commit(at: gitRepositoryRoot, message: message, amend: amend)
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
    func commitAndPushStagedChanges(message rawMessage: String, amend: Bool) async -> Bool {
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

        isCommitting = true
        let commitResult = await service.commit(
            at: gitRepositoryRoot,
            message: message,
            amend: amend
        )
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

        let pushResult = await service.push(currentReference, at: gitRepositoryRoot)
        isCommitting = false
        if pushResult.succeeded {
            notify?("Committed and pushed \(currentReference.shortName)")
        } else {
            notify?("Committed changes, but push failed: \(trimmedMessage(pushResult))")
        }
        await refreshGit()
        return true
    }

    func toggleStaging(_ change: GitChange) async {
        selectedChange = change
        let result = change.isStaged
            ? await service.unstage(change)
            : await service.stage(change)
        let verb = change.isStaged ? "Unstaged" : "Staged"
        showResult(result, success: "\(verb) \(change.path)")
        await refreshGit()
    }

    func stageAllChanges() async {
        guard let gitRepositoryRoot else { return }
        let result = await service.stageAll(at: gitRepositoryRoot)
        showResult(result, success: "Staged all changes")
        await refreshGit()
    }

    func stashWorkingTree(message: String, includeUntracked: Bool) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await service.stash(
            message: message,
            includeUntracked: includeUntracked,
            at: gitRepositoryRoot
        )
        isPerformingStashOperation = false
        if result.succeeded {
            notify?("Working tree stashed")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    func applyStash(_ stash: GitStash, pop: Bool = false) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = pop
            ? await service.popStash(stash, at: gitRepositoryRoot)
            : await service.applyStash(stash, at: gitRepositoryRoot)
        isPerformingStashOperation = false
        if result.succeeded {
            notify?(pop ? "Popped \(stash.reference)" : "Applied \(stash.reference)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    func dropStash(_ stash: GitStash) async {
        guard let gitRepositoryRoot else { return }
        isPerformingStashOperation = true
        let result = await service.dropStash(stash, at: gitRepositoryRoot)
        isPerformingStashOperation = false
        notify?(result.succeeded ? "Dropped \(stash.reference)" : trimmedMessage(result))
        await refreshGit()
    }

    func selectGitReference(_ reference: GitReference?) async {
        selectedGitReference = reference
        gitHistoryLimit = 300
        canLoadMoreGitHistory = false
        await refreshGitHistory()
    }

    func refreshGitHistory() async {
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

    func loadMoreGitHistory() async {
        guard canLoadMoreGitHistory, !isLoadingGitHistory else { return }
        isLoadingMoreGitHistory = true
        defer { isLoadingMoreGitHistory = false }
        gitHistoryLimit += 300
        await refreshGitHistory()
    }

    func selectGitCommit(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommit = commit
        selectedGitCommitFile = nil
        selectedGitCommitDiffContext = nil
        let files = await service.files(in: commit, at: gitRepositoryRoot)
        guard selectedGitCommit?.hash == commit.hash else { return }
        selectedGitCommitFiles = files
        selectedGitCommitFile = files.first
    }

    func showGitCommitDiff(for file: GitCommitFile) async {
        guard let gitRepositoryRoot, let commit = selectedGitCommit else { return }
        let context = GitCommitDiffContext(
            repositoryRoot: gitRepositoryRoot,
            commit: commit,
            file: file
        )
        closeBranchComparison()
        selectedChange = nil
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

    func closeGitCommitDiff() {
        selectedGitCommitDiffContext = nil
        selectedGitCommitFile = nil
        diffRows = []
        diffHunks = []
        isLoadingDiff = false
    }

    func loadBlame(for fileURL: URL) async -> [GitBlameLine] {
        guard let gitRepositoryRoot else { return [] }
        let normalizedURL = fileURL.standardizedFileURL
        let blame = await service.blame(fileURL: normalizedURL, at: gitRepositoryRoot)
        gitBlameLines[normalizedURL] = blame
        return blame
    }

    func showGitCommit(_ hash: String) async {
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

    func showComparisonWithWorkingTree(for reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        selectedGitCommitDiffContext = nil
        selectedChange = nil
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

    func selectBranchComparisonFile(_ file: GitBranchComparisonFile) async {
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

    func closeBranchComparison() {
        branchComparison = nil
        selectedBranchComparisonFile = nil
        branchComparisonRows = []
        isLoadingBranchComparison = false
    }

    func createBranch(named rawName: String, from reference: GitReference, checkout: Bool) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notify?("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await service.createBranch(
            named: name,
            from: reference,
            checkout: checkout,
            at: gitRepositoryRoot
        )
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            notify?(checkout ? "Created and checked out \(name)" : "Created branch \(name)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    func renameBranch(_ reference: GitReference, to rawName: String) async {
        guard let gitRepositoryRoot else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            notify?("Enter a branch name")
            return
        }
        isPerformingBranchOperation = true
        let result = await service.renameBranch(reference, to: name, at: gitRepositoryRoot)
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

    func deleteBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.deleteBranch(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Deleted \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
    }

    func mergeBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.mergeBranch(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Merged \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
    }

    func rebaseCurrentBranch(onto reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.rebaseCurrentBranch(onto: reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Rebased onto \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
    }

    func updateCurrentBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot, reference.isCurrent else {
            notify?("Only the current branch can be updated")
            return
        }
        isPerformingBranchOperation = true
        let result = await service.updateCurrentBranch(at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Updated \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
    }

    func fetchGit() async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.fetch(at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Fetched Git remotes" : trimmedMessage(result))
        await refreshGit()
    }

    func checkoutReference(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        guard !reference.isCurrent else {
            notify?("Already on \(reference.shortName)")
            return
        }
        isPerformingBranchOperation = true
        let result = await service.checkout(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        if result.succeeded {
            selectedGitReference = nil
            closeBranchComparison()
            notify?("Checked out \(reference.shortName)")
            await refreshGit()
        } else {
            notify?(trimmedMessage(result))
        }
    }

    func checkoutRevision(_ rawRevision: String) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.checkoutRevision(rawRevision, at: gitRepositoryRoot)
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

    func cherryPick(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.cherryPick(commit.hash, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Cherry-picked \(commit.shortHash)" : trimmedMessage(result))
        await refreshGit()
    }

    func revert(_ commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.revert(commit.hash, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Reverted \(commit.shortHash)" : trimmedMessage(result))
        await refreshGit()
    }

    func resetCurrentBranch(to commit: GitCommit) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.resetCurrentBranch(
            to: commit.hash,
            at: gitRepositoryRoot,
            mode: "--mixed"
        )
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Reset current branch to \(commit.shortHash)" : trimmedMessage(result))
        await refreshGit()
    }

    func pushBranch(_ reference: GitReference) async {
        guard let gitRepositoryRoot else { return }
        isPerformingBranchOperation = true
        let result = await service.push(reference, at: gitRepositoryRoot)
        isPerformingBranchOperation = false
        notify?(result.succeeded ? "Pushed \(reference.shortName)" : trimmedMessage(result))
        await refreshGit()
    }

    @discardableResult
    func cloneRepository(
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
        return await service.cloneRepository(from: remote, to: destination)
    }

    private func showResult(_ result: GitService.CommandResult, success: String) {
        notify?(result.succeeded ? success : trimmedMessage(result))
    }

    private func trimmedMessage(_ result: GitService.CommandResult) -> String {
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git operation failed" : message
    }
}
