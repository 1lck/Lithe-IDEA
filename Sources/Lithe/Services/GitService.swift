import Foundation

protocol GitOperations: Sendable {
    func snapshot(at rootURL: URL) -> GitSnapshot?
    func watchContext(at rootURL: URL) -> GitWatchContext?


    func diffDocument(
        at rootURL: URL,
        pathspecs: [String],
        staged: Bool,
        untracked: Bool,
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument?

    func diffPatch(
        at rootURL: URL,
        pathspecs: [String],
        staged: Bool,
        untracked: Bool,
        whitespace: GitDiffWhitespaceMode
    ) -> String?

    func commitDiffDocument(
        at rootURL: URL,
        commit: String,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument?

    func comparisonDiffDocument(
        at rootURL: URL,
        reference: String,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument?

    func applyPatch(
        _ patch: String,
        at rootURL: URL,
        mode: String
    ) -> ProcessResult?

    func history(
        at rootURL: URL,
        reference: GitReference?,
        limit: Int
    ) -> GitHistorySnapshot?

    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]?
    func commit(at rootURL: URL, hash: String) -> GitCommit?
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison?
    func stashes(at rootURL: URL) -> [GitStash]?
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]?

    func stage(_ change: GitChange) -> ProcessResult?
    func unstage(_ change: GitChange) -> ProcessResult?
    func stage(paths: [String], at rootURL: URL) -> ProcessResult?
    func unstage(paths: [String], at rootURL: URL) -> ProcessResult?
    func discard(_ change: GitChange) -> ProcessResult?
    func discardAll(_ change: GitChange) -> ProcessResult?
    func commit(at rootURL: URL, message: String, amend: Bool) -> ProcessResult?
    func cherryPick(_ hash: String, at rootURL: URL) -> ProcessResult?
    func revert(_ hash: String, at rootURL: URL) -> ProcessResult?
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> ProcessResult?
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> ProcessResult?
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> ProcessResult?
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> ProcessResult?
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> ProcessResult?
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> ProcessResult?
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> ProcessResult?
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState?
    func conflictMarkerPaths(at rootURL: URL) -> [String]
    func integrationPreflight(
        for target: GitIntegrationTarget,
        operation: GitIntegrationOperation,
        at rootURL: URL
    ) -> GitIntegrationPreflightState?
    func fetch(at rootURL: URL) -> ProcessResult?
    func checkout(
        _ reference: GitReference,
        at rootURL: URL,
        force: Bool,
        autoStash: Bool
    ) -> ProcessResult?
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String]
    func operationState(at rootURL: URL) -> GitOperationState?
    func continueOperation(at rootURL: URL) -> ProcessResult?
    func abortOperation(at rootURL: URL) -> ProcessResult?
    func skipOperationStep(at rootURL: URL) -> ProcessResult?
    func checkoutRevision(_ revision: String, at rootURL: URL) -> ProcessResult?
    func push(_ reference: GitReference, at rootURL: URL) -> ProcessResult?
    func cloneRepository(from remote: String, to destination: URL) -> ProcessResult?
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> ProcessResult?
    func applyStash(_ stash: GitStash, at rootURL: URL) -> ProcessResult?
    func popStash(_ stash: GitStash, at rootURL: URL) -> ProcessResult?
    func dropStash(_ stash: GitStash, at rootURL: URL) -> ProcessResult?
    func stageAll(at rootURL: URL) -> ProcessResult?
}

protocol GitWatchContextProviding: Sendable {
    func watchContext(for workspace: URL) async -> GitWatchContext?
}

/// UI-facing Git service. Git command construction, validation, parsing, and
/// process execution live behind the shared Rust operations port.
struct GitService: GitWatchContextProviding, Sendable {
    private let operations: any GitOperations

    init(operations: any GitOperations) {
        self.operations = operations
    }

    struct CommandResult: Sendable {
        let output: String
        let exitCode: Int32
        let stashRestoreConflict: GitStashRestoreConflict?

        init(
            output: String,
            exitCode: Int32,
            stashRestoreConflict: GitStashRestoreConflict? = nil
        ) {
            self.output = output
            self.exitCode = exitCode
            self.stashRestoreConflict = stashRestoreConflict
        }

        var succeeded: Bool { exitCode == 0 }
    }

    func snapshot(for workspace: URL) async -> GitSnapshot? {
        await read(priority: .utility) { $0.snapshot(at: workspace) }
    }

    func watchContext(for workspace: URL) async -> GitWatchContext? {
        await read(priority: .utility) { $0.watchContext(at: workspace) }
    }


    func diff(for change: GitChange) async -> [DiffRow] {
        (await diffDocument(for: change)).rows
    }

    func diffDocument(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> DiffDocument {
        await read {
            $0.diffDocument(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: !change.hasWorkingTreeChange,
                untracked: change.isUntracked,
                whitespace: whitespace
            )
        } ?? DiffDocument(rows: [], hunks: [])
    }

    func diffPatch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> String {
        await read {
            $0.diffPatch(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: !change.hasWorkingTreeChange,
                untracked: change.isUntracked,
                whitespace: whitespace
            )
        } ?? ""
    }

    /// Returns only the working-tree delta against the current index. This is
    /// kept separate from `diffPatch(for:)` so Shelve can preserve staged and
    /// unstaged edits independently for a file that has both.
    func workingDiffPatch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> String {
        await read {
            $0.diffPatch(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: false,
                untracked: change.isUntracked,
                whitespace: whitespace
            )
        } ?? ""
    }

    /// Applies a complete patch outside the diff-hunk convenience methods.
    /// Shelve uses `restoreIndex` to restore the index and worktree together,
    /// then `worktree` for the unstaged part.
    func applyPatch(_ patch: String, at repositoryRoot: URL, mode: String) async -> CommandResult {
        await command { $0.applyPatch(patch, at: repositoryRoot, mode: mode) }
    }

    /// A failed restore can leave one half of a Shelf already applied. Check
    /// the reverse patch so retrying the Shelf remains idempotent instead of
    /// treating that expected state as a second restore failure.
    func patchIsAlreadyApplied(
        _ patch: String,
        at repositoryRoot: URL,
        staged: Bool
    ) async -> Bool {
        let mode = staged ? "restoreIndexCheck" : "worktreeCheck"
        return (await applyPatch(patch, at: repositoryRoot, mode: mode)).succeeded
    }

    /// Returns exactly what Git would include for this file in the next
    /// commit, even when the file also has unstaged working-tree changes.
    func stagedDiffPatch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> String {
        await read {
            $0.diffPatch(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: true,
                untracked: false,
                whitespace: whitespace
            )
        } ?? ""
    }

    func stage(_ change: GitChange) async -> CommandResult {
        await command { $0.stage(change) }
    }

    func unstage(_ change: GitChange) async -> CommandResult {
        await command { $0.unstage(change) }
    }

    func stage(paths: [String], at repositoryRoot: URL) async -> CommandResult {
        await command { $0.stage(paths: paths, at: repositoryRoot) }
    }

    func unstage(paths: [String], at repositoryRoot: URL) async -> CommandResult {
        await command { $0.unstage(paths: paths, at: repositoryRoot) }
    }

    func discard(_ change: GitChange) async -> CommandResult {
        return await command { $0.discard(change) }
    }

    func discardAll(_ change: GitChange) async -> CommandResult {
        await command { $0.discardAll(change) }
    }

    func stage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "stage")
        }
    }

    func unstage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "unstage")
        }
    }

    func discard(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "discard")
        }
    }

    func commit(at repositoryRoot: URL, message: String, amend: Bool = false) async -> CommandResult {
        await command { $0.commit(at: repositoryRoot, message: message, amend: amend) }
    }

    func cherryPick(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.cherryPick(hash, at: repositoryRoot) }
    }

    func revert(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.revert(hash, at: repositoryRoot) }
    }

    func resetCurrentBranch(
        to hash: String,
        at repositoryRoot: URL,
        mode: String = "--mixed"
    ) async -> CommandResult {
        await command { $0.resetCurrentBranch(to: hash, mode: mode, at: repositoryRoot) }
    }

    func history(
        at repositoryRoot: URL,
        reference: GitReference? = nil,
        limit: Int = 300
    ) async -> GitHistorySnapshot {
        await read(priority: .utility) {
            $0.history(at: repositoryRoot, reference: reference, limit: limit)
        } ?? GitHistorySnapshot(references: [], commits: [], hasMore: false)
    }

    func files(in commit: GitCommit, at repositoryRoot: URL) async -> [GitCommitFile] {
        await read(priority: .utility) { $0.files(in: commit, at: repositoryRoot) } ?? []
    }

    func diffDocument(
        for commit: GitCommit,
        file: GitCommitFile,
        at repositoryRoot: URL,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> DiffDocument {
        await read {
            $0.commitDiffDocument(
                at: repositoryRoot,
                commit: commit.hash,
                pathspecs: [file.path],
                whitespace: whitespace
            )
        } ?? DiffDocument(rows: [], hunks: [])
    }

    func blame(fileURL: URL, at repositoryRoot: URL) async -> [GitBlameLine] {
        let rootPath = repositoryRoot.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return [] }
        let relativePath = String(filePath.dropFirst(rootPath.count + 1))
        return await read(priority: .utility) {
            $0.blame(at: repositoryRoot, relativePath: relativePath)
        } ?? []
    }

    func commit(withHash hash: String, at repositoryRoot: URL) async -> GitCommit? {
        await read(priority: .utility) { $0.commit(at: repositoryRoot, hash: hash) }
    }

    func comparisonWithWorkingTree(
        for reference: GitReference,
        at repositoryRoot: URL
    ) async -> GitBranchComparison {
        await read(priority: .utility) {
            $0.comparison(for: reference, at: repositoryRoot)
        } ?? GitBranchComparison(reference: reference, files: [])
    }

    func diff(
        for file: GitBranchComparisonFile,
        against reference: GitReference,
        at repositoryRoot: URL,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> [DiffRow] {
        await read {
            $0.comparisonDiffDocument(
                at: repositoryRoot,
                reference: reference.fullName,
                pathspecs: [file.path],
                whitespace: whitespace
            )
        }?.rows ?? []
    }

    func createBranch(
        named name: String,
        from reference: GitReference,
        checkout: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command { $0.createBranch(named: name, from: reference, checkout: checkout, at: repositoryRoot) }
    }

    func renameBranch(
        _ reference: GitReference,
        to newName: String,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command { $0.renameBranch(reference, to: newName, at: repositoryRoot) }
    }

    func deleteBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.deleteBranch(reference, at: repositoryRoot) }
    }

    func mergeBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.mergeBranch(reference, at: repositoryRoot) }
    }

    func rebaseCurrentBranch(onto reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.rebaseCurrentBranch(onto: reference, at: repositoryRoot) }
    }

    func updateCurrentBranch(
        at repositoryRoot: URL,
        strategy: GitPullStrategy = .ffOnly
    ) async -> CommandResult {
        await command { $0.updateCurrentBranch(at: repositoryRoot, strategy: strategy) }
    }

    func pullPreflight(at repositoryRoot: URL) async -> GitPullPreflightState? {
        await read { $0.pullPreflight(at: repositoryRoot) }
    }

    func conflictMarkerPaths(at repositoryRoot: URL) async -> [String] {
        await read { $0.conflictMarkerPaths(at: repositoryRoot) } ?? []
    }

    func integrationPreflight(
        for target: GitIntegrationTarget,
        operation: GitIntegrationOperation,
        at repositoryRoot: URL
    ) async -> GitIntegrationPreflightState? {
        await read {
            $0.integrationPreflight(for: target, operation: operation, at: repositoryRoot)
        }
    }

    func fetch(at repositoryRoot: URL) async -> CommandResult {
        await command { $0.fetch(at: repositoryRoot) }
    }

    func checkout(
        _ reference: GitReference,
        at repositoryRoot: URL,
        force: Bool = false,
        autoStash: Bool = false
    ) async -> CommandResult {
        await command {
            $0.checkout(reference, at: repositoryRoot, force: force, autoStash: autoStash)
        }
    }

    /// Working-tree paths that would block checking out `reference`, empty when the switch is clean.
    func checkoutBlockingPaths(for reference: GitReference, at repositoryRoot: URL) async -> [String] {
        await read { $0.checkoutBlockingPaths(for: reference, at: repositoryRoot) } ?? []
    }

    /// The half-finished merge, rebase, cherry-pick, or revert Git is sitting in,
    /// or nil when the repository is in its normal state.
    func operationState(at repositoryRoot: URL) async -> GitOperationState? {
        await read(priority: .utility) { $0.operationState(at: repositoryRoot) }
    }

    func continueOperation(at repositoryRoot: URL) async -> CommandResult {
        await command { $0.continueOperation(at: repositoryRoot) }
    }

    func abortOperation(at repositoryRoot: URL) async -> CommandResult {
        await command { $0.abortOperation(at: repositoryRoot) }
    }

    func skipOperationStep(at repositoryRoot: URL) async -> CommandResult {
        await command { $0.skipOperationStep(at: repositoryRoot) }
    }

    func checkoutRevision(_ revision: String, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.checkoutRevision(revision, at: repositoryRoot) }
    }

    func push(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.push(reference, at: repositoryRoot) }
    }

    func cloneRepository(from remote: String, to destination: URL) async -> CommandResult {
        await command { $0.cloneRepository(from: remote, to: destination) }
    }

    func stashes(at repositoryRoot: URL) async -> [GitStash] {
        await read(priority: .utility) { $0.stashes(at: repositoryRoot) } ?? []
    }

    func stash(
        message: String,
        includeUntracked: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command {
            $0.stash(message: message, includeUntracked: includeUntracked, at: repositoryRoot)
        }
    }

    func applyStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.applyStash(stash, at: repositoryRoot) }
    }

    func popStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.popStash(stash, at: repositoryRoot) }
    }

    func dropStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command { $0.dropStash(stash, at: repositoryRoot) }
    }

    func stageAll(at repositoryRoot: URL) async -> CommandResult {
        await command { $0.stageAll(at: repositoryRoot) }
    }

    private func command(
        _ operation: @escaping @Sendable (any GitOperations) -> ProcessResult?
    ) async -> CommandResult {
        let operations = self.operations
        return await Task.detached(priority: .userInitiated) {
            let result = operation(operations)
            return CommandResult(
                output: result?.output ?? "Rust Core Git operation failed",
                exitCode: result?.exitCode ?? 1,
                stashRestoreConflict: result?.stashRestoreConflict
            )
        }.value
    }

    private func read<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable (any GitOperations) -> T?
    ) async -> T? {
        let operations = self.operations
        return await Task.detached(priority: priority) {
            operation(operations)
        }.value
    }
}
