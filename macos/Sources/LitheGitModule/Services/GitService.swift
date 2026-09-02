import Foundation
import LitheCoreContracts

package protocol GitPerformanceLogger: Sendable {
    func record(_ message: String)
}

package struct NullGitPerformanceLogger: GitPerformanceLogger {
    package init() {}

    package func record(_ message: String) {}
}

package protocol GitOperations: Sendable {
    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> GitProcessResult

    func snapshot(at rootURL: URL) -> GitSnapshot?
    func watchContext(at rootURL: URL) -> GitWatchContext?
    func worktrees(at rootURL: URL) -> [GitWorktree]?

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
    func comparisonDiffDocument(
        at rootURL: URL,
        reference: GitReference,
        targetReference: GitReference?,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument?

    func applyPatch(
        _ patch: String,
        at rootURL: URL,
        mode: String
    ) -> GitProcessResult?

    func history(
        at rootURL: URL,
        reference: GitReference?,
        limit: Int
    ) -> GitHistorySnapshot?

    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]?
    func commit(at rootURL: URL, hash: String) -> GitCommit?
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison?
    func comparison(
        from reference: GitReference,
        to target: GitReference,
        at rootURL: URL
    ) -> GitBranchComparison?
    func stashes(at rootURL: URL) -> [GitStash]?
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]?

    func stage(_ change: GitChange) -> GitProcessResult?
    func unstage(_ change: GitChange) -> GitProcessResult?
    func discard(_ change: GitChange) -> GitProcessResult?
    func discardAll(_ change: GitChange) -> GitProcessResult?
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult?
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult?
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult?
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult?
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult?
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult?
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult?
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult?
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult?
    func repairWorktrees(at rootURL: URL) -> GitProcessResult?
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult?
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult?
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult?
    func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy,
        at rootURL: URL
    ) -> GitProcessResult?
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState?
    func conflictMarkerPaths(at rootURL: URL) -> [String]
    func integrationPreflight(
        for target: GitIntegrationTarget,
        operation: GitIntegrationOperation,
        at rootURL: URL
    ) -> GitIntegrationPreflightState?
    func fetch(at rootURL: URL) -> GitProcessResult?
    func checkout(
        _ reference: GitReference,
        at rootURL: URL,
        force: Bool,
        autoStash: Bool
    ) -> GitProcessResult?
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String]
    func operationState(at rootURL: URL) -> GitOperationState?
    func continueOperation(at rootURL: URL) -> GitProcessResult?
    func abortOperation(at rootURL: URL) -> GitProcessResult?
    func skipOperationStep(at rootURL: URL) -> GitProcessResult?
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult?
    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult?
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult?
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func stageAll(at rootURL: URL) -> GitProcessResult?
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult?
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult?
}

package typealias GitWatchContextProviding = LitheCoreContracts.GitWatchContextProviding

private actor GitHistoryCache {
    private struct Key: Hashable {
        let rootPath: String
        let reference: String?
        let limit: Int
    }

    private struct Entry {
        let snapshot: GitHistorySnapshot
        let insertedAt: Date
    }

    private var values: [Key: Entry] = [:]

    func value(rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        let key = Key(rootPath: rootURL.standardizedFileURL.path, reference: reference?.fullName, limit: limit)
        guard let entry = values[key] else { return nil }
        // Short-lived reuse smooths repeated pane opens without allowing a
        // commit made in the meantime to leave the UI stale indefinitely.
        guard Date().timeIntervalSince(entry.insertedAt) < 5 else {
            values.removeValue(forKey: key)
            return nil
        }
        return entry.snapshot
    }

    func insert(_ snapshot: GitHistorySnapshot, rootURL: URL, reference: GitReference?, limit: Int) {
        let key = Key(rootPath: rootURL.standardizedFileURL.path, reference: reference?.fullName, limit: limit)
        values[key] = Entry(snapshot: snapshot, insertedAt: Date())
        // Keep this process-local cache bounded while retaining the most useful recent queries.
        if values.count > 24, let oldestKey = values.keys.first {
            values.removeValue(forKey: oldestKey)
        }
    }
}

/// UI-facing Git service. Git command construction, validation, parsing, and
/// process execution live behind the shared Rust operations port.
package struct GitService: Sendable {
    private let operations: any GitOperations
    private let historyCache = GitHistoryCache()
    private let performanceLogger: any GitPerformanceLogger

    package init(
        operations: any GitOperations,
        performanceLogger: any GitPerformanceLogger = NullGitPerformanceLogger()
    ) {
        self.operations = operations
        self.performanceLogger = performanceLogger
    }

    package struct CommandResult: Sendable {
        package let workingDirectory: URL?
        package let arguments: [String]
        package let output: String
        package let standardOutput: String?
        package let standardError: String?
        package let exitCode: Int32
        package let invocations: [GitProcessInvocation]
        package let operationErrorMessage: String?
        package let stashRestoreConflict: GitStashRestoreConflict?
        package let tagDeletion: GitTagDeletion?
        package let branchDeletion: GitBranchDeletion?
        package let warnings: [GitOperationWarning]

        package init(
            workingDirectory: URL? = nil,
            arguments: [String] = [],
            output: String,
            standardOutput: String? = nil,
            standardError: String? = nil,
            exitCode: Int32,
            invocations: [GitProcessInvocation] = [],
            operationErrorMessage: String? = nil,
            stashRestoreConflict: GitStashRestoreConflict? = nil,
            tagDeletion: GitTagDeletion? = nil,
            branchDeletion: GitBranchDeletion? = nil,
            warnings: [GitOperationWarning] = []
        ) {
            self.workingDirectory = workingDirectory
            self.arguments = arguments
            self.output = output
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.exitCode = exitCode
            self.invocations = invocations
            self.operationErrorMessage = operationErrorMessage
            self.stashRestoreConflict = stashRestoreConflict
            self.tagDeletion = tagDeletion
            self.branchDeletion = branchDeletion
            self.warnings = warnings
        }

        package var succeeded: Bool {
            exitCode == 0 && operationErrorMessage == nil && stashRestoreConflict == nil
        }
    }

    func snapshot(for workspace: URL) async -> GitSnapshot? {
        await read(priority: .utility) { $0.snapshot(at: workspace) }
    }

    func worktrees(at repositoryRoot: URL) async -> [GitWorktree]? {
        await read(priority: .utility) { $0.worktrees(at: repositoryRoot) }
    }

    func inspectWorktree(
        _ worktree: GitWorktree,
        reference: GitReference?
    ) async -> GitWorktreeInspection? {
        // The detail pane should become useful quickly; the feature model can
        // request a larger window after this first paint.
        async let history = history(at: worktree.url, reference: reference, limit: 30)
        async let snapshot = snapshot(for: worktree.url)
        let resolvedHistory = await history
        // A linked worktree can occasionally have a transiently unreadable
        // index while Git is refreshing it. Keep the independent commit
        // history visible instead of dropping the entire inspection result.
        let resolvedChanges = (await snapshot)?.changes ?? []
        return GitWorktreeInspection(
            worktreeID: worktree.id,
            changes: resolvedChanges,
            commits: resolvedHistory.commits,
            hasMoreCommits: resolvedHistory.hasMore
        )
    }

    func consoleVersion(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot, fallbackArguments: ["version"]) {
            $0.run(
                arguments: ["version"],
                workingDirectory: repositoryRoot.path,
                input: nil
            )
        }
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

    func diffDocumentAgainstHead(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> DiffDocument {
        if change.isUntracked {
            return await diffDocument(for: change, whitespace: whitespace)
        }
        return await read {
            $0.comparisonDiffDocument(
                at: change.repositoryRoot,
                reference: "HEAD",
                pathspecs: change.pathspecs,
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
        await command(at: repositoryRoot) { $0.applyPatch(patch, at: repositoryRoot, mode: mode) }
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
        await command(at: change.repositoryRoot) { $0.stage(change) }
    }

    func unstage(_ change: GitChange) async -> CommandResult {
        await command(at: change.repositoryRoot) { $0.unstage(change) }
    }

    func discard(_ change: GitChange) async -> CommandResult {
        return await command(at: change.repositoryRoot) { $0.discard(change) }
    }

    func discardAll(_ change: GitChange) async -> CommandResult {
        await command(at: change.repositoryRoot) { $0.discardAll(change) }
    }

    func stage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command(at: change.repositoryRoot, fallbackArguments: ["apply", "--cached", "-"]) {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "stage")
        }
    }

    func unstage(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command(at: change.repositoryRoot, fallbackArguments: ["apply", "--cached", "--reverse", "-"]) {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "unstage")
        }
    }

    func discard(hunk: DiffHunk, of change: GitChange) async -> CommandResult {
        await command(at: change.repositoryRoot, fallbackArguments: ["apply", "--reverse", "-"]) {
            $0.applyPatch(hunk.patch, at: change.repositoryRoot, mode: "discard")
        }
    }

    func commit(at repositoryRoot: URL, message: String, amend: Bool = false) async -> CommandResult {
        await command(at: repositoryRoot) { $0.commit(at: repositoryRoot, message: message, amend: amend) }
    }

    func cherryPick(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.cherryPick(hash, at: repositoryRoot) }
    }

    func revert(_ hash: String, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.revert(hash, at: repositoryRoot) }
    }

    func resetCurrentBranch(
        to hash: String,
        at repositoryRoot: URL,
        mode: String = "--mixed"
    ) async -> CommandResult {
        await command(at: repositoryRoot) { $0.resetCurrentBranch(to: hash, mode: mode, at: repositoryRoot) }
    }

    func history(
        at repositoryRoot: URL,
        reference: GitReference? = nil,
        limit: Int = 300
    ) async -> GitHistorySnapshot {
        let historyLookupStartedAt = ContinuousClock.now
        if let cached = await historyCache.value(rootURL: repositoryRoot, reference: reference, limit: limit) {
            performanceLogger.record(
                GitPerformanceLogFormatter.cacheHit(
                    operation: #function,
                    durationMilliseconds: elapsedMilliseconds(since: historyLookupStartedAt)
                )
            )
            return cached
        }
        let snapshot = await read(priority: .utility) {
            $0.history(at: repositoryRoot, reference: reference, limit: limit)
        }
        if let snapshot {
            await historyCache.insert(snapshot, rootURL: repositoryRoot, reference: reference, limit: limit)
            return snapshot
        }
        return GitHistorySnapshot(references: [], commits: [], hasMore: false)
    }

    func files(in commit: GitCommit, at repositoryRoot: URL) async -> [GitCommitFile]? {
        await read(priority: .utility) { $0.files(in: commit, at: repositoryRoot) }
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
        async let trackedComparison: GitBranchComparison? = read(priority: .utility) {
            $0.comparison(for: reference, at: repositoryRoot)
        }
        async let workingTreeSnapshot: GitSnapshot? = read(priority: .utility) {
            $0.snapshot(at: repositoryRoot)
        }

        let (comparison, snapshot) = await (trackedComparison, workingTreeSnapshot)
        var filesByPath: [String: GitBranchComparisonFile] = [:]
        for file in comparison?.files ?? [] {
            filesByPath[file.path] = file
        }
        for change in snapshot?.changes ?? [] where change.isUntracked {
            if filesByPath[change.path] == nil {
                filesByPath[change.path] = GitBranchComparisonFile(
                    status: "A",
                    path: change.path,
                    isUntracked: true
                )
            }
        }

        let files = filesByPath.values.sorted { lhs, rhs in
            if lhs.path == rhs.path { return lhs.status < rhs.status }
            return lhs.path < rhs.path
        }
        return GitBranchComparison(reference: reference, files: files)
    }

    func comparison(
        from reference: GitReference,
        to target: GitReference,
        at repositoryRoot: URL
    ) async -> GitBranchComparison {
        let payload = await read(priority: .utility) {
            $0.comparison(from: reference, to: target, at: repositoryRoot)
        }
        return GitBranchComparison(
            reference: reference,
            targetReference: target,
            files: payload?.files ?? []
        )
    }

    func diff(
        for file: GitBranchComparisonFile,
        against reference: GitReference,
        at repositoryRoot: URL,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> [DiffRow] {
        if file.isUntracked {
            return await read {
                $0.diffDocument(
                    at: repositoryRoot,
                    pathspecs: [file.path],
                    staged: false,
                    untracked: true,
                    whitespace: whitespace
                )
            }?.rows ?? []
        }
        return await read {
            $0.comparisonDiffDocument(
                at: repositoryRoot,
                reference: reference.fullName,
                pathspecs: [file.path],
                whitespace: whitespace
            )
        }?.rows ?? []
    }

    func diff(
        for file: GitBranchComparisonFile,
        from reference: GitReference,
        to target: GitReference,
        at repositoryRoot: URL,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> [DiffRow] {
        return await read {
            $0.comparisonDiffDocument(
                at: repositoryRoot,
                reference: reference,
                targetReference: target,
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
        await command(at: repositoryRoot) {
            $0.createBranch(named: name, from: reference, checkout: checkout, at: repositoryRoot)
        }
    }

    func createWorktree(
        named name: String,
        from reference: GitReference,
        revision: String? = nil,
        at destination: URL,
        repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.createWorktree(
                named: name,
                from: reference,
                revision: revision,
                at: destination,
                repositoryRoot: repositoryRoot
            )
        }
    }

    func removeWorktree(
        _ worktree: GitWorktree,
        force: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.removeWorktree(worktree, force: force, at: repositoryRoot)
        }
    }

    func lockWorktree(_ worktree: GitWorktree, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.lockWorktree(worktree, at: repositoryRoot) }
    }

    func unlockWorktree(_ worktree: GitWorktree, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.unlockWorktree(worktree, at: repositoryRoot) }
    }

    func repairWorktrees(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.repairWorktrees(at: repositoryRoot) }
    }

    func pruneWorktrees(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.pruneWorktrees(at: repositoryRoot) }
    }

    func renameBranch(
        _ reference: GitReference,
        to newName: String,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) { $0.renameBranch(reference, to: newName, at: repositoryRoot) }
    }

    func deleteBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.deleteBranch(reference, at: repositoryRoot) }
    }

    func mergeBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.mergeBranch(reference, at: repositoryRoot) }
    }

    func rebaseCurrentBranch(onto reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.rebaseCurrentBranch(onto: reference, at: repositoryRoot) }
    }

    func checkoutAndRebase(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.checkoutAndRebase(reference, at: repositoryRoot) }
    }

    func updateCurrentBranch(
        at repositoryRoot: URL,
        strategy: GitPullStrategy = .ffOnly
    ) async -> CommandResult {
        await command(at: repositoryRoot) { $0.updateCurrentBranch(at: repositoryRoot, strategy: strategy) }
    }

    func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.pullRemoteReference(reference, strategy: strategy, at: repositoryRoot)
        }
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
        await command(at: repositoryRoot) { $0.fetch(at: repositoryRoot) }
    }

    func checkout(
        _ reference: GitReference,
        at repositoryRoot: URL,
        force: Bool = false,
        autoStash: Bool = false
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
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
        await command(at: repositoryRoot) { $0.continueOperation(at: repositoryRoot) }
    }

    func abortOperation(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.abortOperation(at: repositoryRoot) }
    }

    func skipOperationStep(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.skipOperationStep(at: repositoryRoot) }
    }

    func checkoutRevision(_ revision: String, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.checkoutRevision(revision, at: repositoryRoot) }
    }

    func push(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.push(reference, at: repositoryRoot) }
    }

    func cloneRepository(from remote: String, to destination: URL) async -> CommandResult {
        await command(at: destination.deletingLastPathComponent()) {
            $0.cloneRepository(from: remote, to: destination)
        }
    }

    func stashes(at repositoryRoot: URL) async -> [GitStash] {
        await read(priority: .utility) { $0.stashes(at: repositoryRoot) } ?? []
    }

    func stash(
        message: String,
        includeUntracked: Bool,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.stash(message: message, includeUntracked: includeUntracked, at: repositoryRoot)
        }
    }

    func applyStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.applyStash(stash, at: repositoryRoot) }
    }

    func popStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.popStash(stash, at: repositoryRoot) }
    }

    func dropStash(_ stash: GitStash, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.dropStash(stash, at: repositoryRoot) }
    }

    func stageAll(at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.stageAll(at: repositoryRoot) }
    }

    /// Creates a lightweight or annotated tag: a non-empty `message` produces
    /// the annotated form. `revision` is the commit hash or resolvable
    /// revision the tag should point at.
    func createTag(
        named name: String,
        at revision: String,
        message: String?,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.createTag(named: name, at: revision, message: message, rootURL: repositoryRoot)
        }
    }

    func deleteTag(named name: String, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.deleteTag(named: name, rootURL: repositoryRoot) }
    }

    private func command(
        at workingDirectory: URL? = nil,
        fallbackArguments: [String] = [],
        operationName: String = #function,
        _ operation: @escaping @Sendable (any GitOperations) -> GitProcessResult?
    ) async -> CommandResult {
        let operations = self.operations
        let startedAt = ContinuousClock.now
        let result = await Task.detached(priority: .userInitiated) {
            operation(operations)
        }.value
        let commandResult = CommandResult(
            workingDirectory: workingDirectory,
            arguments: result?.arguments.isEmpty == false
                ? result?.arguments ?? fallbackArguments
                : fallbackArguments,
            output: result?.output ?? "Rust Core Git operation failed",
            standardOutput: result?.standardOutput,
            standardError: result?.standardError,
            exitCode: result?.exitCode ?? 1,
            invocations: result?.invocations ?? [],
            operationErrorMessage: result?.operationErrorMessage,
            stashRestoreConflict: result?.stashRestoreConflict,
            tagDeletion: result?.tagDeletion,
            branchDeletion: result?.branchDeletion,
            warnings: result?.warnings ?? []
        )
        performanceLogger.record(
            GitPerformanceLogFormatter.command(
                operation: operationName,
                workingDirectory: workingDirectory,
                arguments: commandResult.arguments,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                succeeded: commandResult.succeeded
            )
        )
        return commandResult
    }

    private func read<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        operationName: String = #function,
        _ operation: @escaping @Sendable (any GitOperations) -> T?
    ) async -> T? {
        let operations = self.operations
        let startedAt = ContinuousClock.now
        let result = await Task.detached(priority: priority) {
            operation(operations)
        }.value
        performanceLogger.record(
            GitPerformanceLogFormatter.read(
                operation: operationName,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                succeeded: result != nil
            )
        )
        return result
    }

    package func recordWorktreeInspection(
        worktreeID: String,
        phase: String,
        durationMilliseconds: Int
    ) {
        performanceLogger.record(
            "[git-performance] operation=worktree-inspection phase=\(phase) worktree=\(GitPerformanceLogFormatter.redact(worktreeID)) duration_ms=\(durationMilliseconds)"
        )
    }

    private func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Int {
        let components = startedAt.duration(to: .now).components
        let milliseconds = (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        return max(0, Int(milliseconds.rounded()))
    }
}

private enum GitPerformanceLogFormatter {
    static func command(
        operation: String,
        workingDirectory: URL?,
        arguments: [String],
        durationMilliseconds: Int,
        succeeded: Bool
    ) -> String {
        let command = GitConsoleCommandFormatter.commandLine(arguments: arguments)
        let directory = workingDirectory?.path ?? "-"
        return "[git-performance] operation=\(redact(operation)) duration_ms=\(durationMilliseconds) status=\(succeeded ? "success" : "failure") cwd=\(redact(directory)) command=\(redact(command))"
    }

    static func read(
        operation: String,
        durationMilliseconds: Int,
        succeeded: Bool
    ) -> String {
        "[git-performance] operation=\(redact(operation)) duration_ms=\(durationMilliseconds) status=\(succeeded ? "success" : "failure") cache=miss"
    }

    static func cacheHit(operation: String, durationMilliseconds: Int) -> String {
        "[git-performance] operation=\(redact(operation)) duration_ms=\(durationMilliseconds) status=success cache=hit"
    }

    static func redact(_ value: String) -> String {
        GitConsoleRedactor.redact(value)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
