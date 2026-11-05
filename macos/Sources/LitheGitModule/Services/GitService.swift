import Foundation
import LitheCoreContracts
import LitheModuleAPI

package protocol GitPerformanceLogger: Sendable {
    func emit(_ event: any LogEvent)
}

package struct NullGitPerformanceLogger: GitPerformanceLogger {
    package init() {}

    package func emit(_ event: any LogEvent) {}
}

package protocol GitOperations: Sendable {
    func changelistProjection(_ request: GitChangelistCoreRequest) -> GitChangelistCoreProjection?
    func captureCommitMessageContext(_ repositories: [GitCommitMessageRepository]) -> Result<GitCommitMessageCoreCapture, GitPatchFailure>
    func checkCommitMessageContext(_ context: GitCommitMessageContext) -> Bool
    func reconcileDeletedSelection(at root: URL, changes: [GitChange]) -> GitProcessResult?
    func prepareCommitSelection(_ request: GitCommitSelectionRequest) -> GitProcessResult?
    func prepareWorkspaceCommit(_ request: GitWorkspaceCommitRequest) -> Result<GitWorkspaceCommitPreparation, GitWorkspaceCommitFailure>
    func stepWorkspaceCommit(_ session: GitWorkspaceCommitSession) -> Result<GitWorkspaceCommitSession, GitWorkspaceCommitFailure>

    func consolePresentation(_ request: GitConsolePresentationRequest) -> GitConsolePresentation?
    func executableResolution() -> Result<GitExecutableResolution, GitFetchFailure>
    func executionSettings(_ request: GitConfigurationEdit, save: Bool) -> Result<GitExecutionSettingsSnapshot, GitFetchFailure>
    func remoteURL(at rootURL: URL, remote: String) -> String?
    func answerAuthentication(requestID: String, answer: String?) -> Bool
    func repositorySetup(at root: URL, scope: GitIdentityScope) -> Result<GitRepositorySetup, GitSetupFailure>
    func initializeRepository(at root: URL) -> Result<GitRepositorySetup, GitSetupFailure>
    func configureIdentity(at root: URL, scope: GitIdentityScope, field: GitIdentityField, value: String?) -> Result<GitRepositorySetup, GitSetupFailure>
    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> GitProcessResult

    func snapshot(at rootURL: URL) -> GitSnapshot?
    func snapshot(at rootURL: URL, repositoryRoots: [URL]) -> GitSnapshot?
    /// Status for the changes panel: a large wholly untracked directory arrives
    /// as one summary change instead of one change per file.
    func changesSnapshot(at rootURL: URL, repositoryRoots: [URL]) -> GitSnapshot?
    /// Immediate files and subdirectory summaries of an untracked directory summary.
    func untrackedDirectoryChildren(of directory: GitChange, repositoryRoots: [URL]) -> [GitChange]?
    func repositories(in workspaceURL: URL) -> [URL]
    func repositoryColorAssignments(_ request: GitRepositoryColorPageRequest) -> GitRepositoryColorPage?
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

    func historyDateMatches(_ query: GitHistoryDateQuery) -> [String]?
    func history(
        at rootURL: URL,
        reference: GitReference?,
        limit: Int
    ) -> GitHistorySnapshot?
    func references(at rootURL: URL, operationID: String) -> GitReferenceSnapshot?
    /// Core-owned cleanup and conflict validation for a new branch name.
    func branchNamePreview(
        rawName: String,
        requireName: Bool,
        references: [GitReference],
        reference: GitReference?
    ) -> GitBranchNamePreview?
    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPage?
    /// Reads forward from `cursor` until `target` is found or the page budget
    /// is spent; the commits read are returned so the caller can append them.
    func historyLocate(
        at rootURL: URL,
        reference: GitReference?,
        target: String,
        cursor: String?,
        limit: Int,
        maxPages: Int,
        operationID: String
    ) -> GitHistoryLocateResult?
    func closeHistoryCursor(at rootURL: URL, cursor: String) -> Bool
    func cancel(operationID: String) -> Bool

    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]?
    func commit(at rootURL: URL, hash: String) -> GitCommit?
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison?
    func comparison(
        from reference: GitReference,
        to target: GitReference,
        at rootURL: URL
    ) -> GitBranchComparison?
    func stashes(at rootURL: URL) -> [GitStash]?
    func workspaceStatusPlan(roots: [String], previousRoots: [String], outcomes: [GitWorkspaceStatusOutcome]) -> GitWorkspaceStatusPlan?
    func resolveFileContext(fileURL: URL, relativeTo rootURL: URL) -> GitFileContext?
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]?

    func stage(_ change: GitChange) -> GitProcessResult?
    func unstage(_ change: GitChange) -> GitProcessResult?
    func discard(_ change: GitChange) -> GitProcessResult?
    func discardAll(_ change: GitChange) -> GitProcessResult?
    func prepareRollback(at root: URL, changes: [GitChange], deleteAddedFiles: Bool) -> Result<GitRollbackPlan, GitRollbackFailure>
    func executeRollbackStep(at root: URL, step: GitRollbackPlan.Step) -> GitProcessResult?
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult?
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult?
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult?
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult?
    func historyActionCapabilities(at rootURL: URL, revisions: [String], operationID: String) -> Result<GitHistoryActionCapabilities, GitHistoryActionFailure>
    func historyRewritePreview(at rootURL: URL, operation: GitHistoryRewriteOperation, revisions: [String]) -> GitHistoryRewritePreview?
    func rewriteHistory(at rootURL: URL, expectedState: GitHistoryRewriteExpectedState, message: String?) -> GitProcessResult?
    func interactiveRebasePreview(at rootURL: URL, revision: String) -> Result<GitRebasePreview, GitRebaseFailure>
    func interactiveRebaseSession(at rootURL: URL) -> Result<GitRebaseSession?, GitRebaseFailure>
    func startInteractiveRebase(at rootURL: URL, expectedState: GitRebaseExpectedState, steps: [GitRebaseStep]) -> GitRebaseProcessResult
    func controlInteractiveRebase(at rootURL: URL, sessionId: String, action: GitRebaseControlAction, amendMessage: String?, expectedHead: String?) -> GitRebaseProcessResult
    func createHistoryRecoveryBranch(named name: String, reference: String, at rootURL: URL) -> GitProcessResult?
    func shelfCapture(at rootURL: URL) -> Result<GitShelfSnapshot, GitPatchFailure>
    func shelfPlan(at rootURL: URL, phase: GitShelfPhase) -> Result<GitShelfPlan, GitPatchFailure>
    func shelfStep(at rootURL: URL, phase: GitShelfPhase, layer: GitShelfLayer, snapshot: GitShelfSnapshot) -> GitProcessResult?
    func exportPatch(at rootURL: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) -> Result<GitPatchExport, GitPatchFailure>
    func savedStashFiles(at rootURL: URL, reference: String, base: String) -> Result<[GitSavedPatchFile], GitPatchFailure>
    func savedShelfFiles(at rootURL: URL, patch: String, version: String, base: String) -> Result<[GitSavedPatchFile], GitPatchFailure>
    func previewPatch(at rootURL: URL, patch: String, target: GitPatchTarget) -> Result<GitPatchPreview, GitPatchFailure>
    func applyExchangePatch(at rootURL: URL, patch: String, target: GitPatchTarget, expectedState: String) -> GitProcessResult?
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult?
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult?
    func createWorktree(_ request: GitWorktreeCreation, at rootURL: URL) -> GitProcessResult?
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult?
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult?
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult?
    func repairWorktrees(at rootURL: URL) -> GitProcessResult?
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult?
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult?
    func setUpstream(branch: GitReference, to upstream: GitReference, at rootURL: URL) -> GitProcessResult?
    func unsetUpstream(branch: GitReference, at rootURL: URL) -> GitProcessResult?
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult?
    /// Fast-forwards a non-current local branch from its upstream without switching HEAD.
    func updateBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult?
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
    func fetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, GitFetchFailure>
    func fetchPlan(options: GitFetchOptions, at root: URL) -> Result<GitFetchPlan, GitFetchFailure>
    func fetch(at rootURL: URL, options: GitFetchOptions, operationID: String) -> GitProcessResult?
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
    /// Pushes `reference`. `pushTarget` is required only for a branch that tracks a
    /// differently named upstream; routine pushes pass `nil`.
    func push(_ reference: GitReference, pushTarget: String?, at rootURL: URL) -> GitProcessResult?
    /// Resolves where pushing `reference` would go and which commits it would send.
    /// `pushTarget` previews the destination a differently named upstream was
    /// confirmed to use; routine pushes pass `nil`.
    func pushPreview(
        _ reference: GitReference,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> Result<GitPushPreview, GitPushFailure>
    /// Pushes exactly what `preview` showed. Core rejects the push as stale when the
    /// branch, destination or tracking commit moved after the preview was resolved.
    func pushReviewed(
        _ reference: GitReference,
        preview: GitPushPreview,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> GitProcessResult?
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult?
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult?
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult?
    func stageAll(at rootURL: URL) -> GitProcessResult?
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult?
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult?
}

package extension GitOperations {
    func workspaceStatusPlan(roots: [String], previousRoots: [String], outcomes: [GitWorkspaceStatusOutcome]) -> GitWorkspaceStatusPlan? { nil }
    func resolveFileContext(fileURL: URL, relativeTo rootURL: URL) -> GitFileContext? { nil }
    func changelistProjection(_ request: GitChangelistCoreRequest) -> GitChangelistCoreProjection? { nil }
    func historyDateMatches(_ query: GitHistoryDateQuery) -> [String]? { nil }
    func reconcileDeletedSelection(at root: URL, changes: [GitChange]) -> GitProcessResult? { nil }
    func prepareCommitSelection(_ request: GitCommitSelectionRequest) -> GitProcessResult? { nil }
    func prepareRollback(at root: URL, changes: [GitChange], deleteAddedFiles: Bool) -> Result<GitRollbackPlan, GitRollbackFailure> {
        .failure(GitRollbackFailure(L10n.string("Could not refresh Git status. Refresh to verify the changes.")))
    }
    func executeRollbackStep(at root: URL, step: GitRollbackPlan.Step) -> GitProcessResult? { nil }
    func savedStashFiles(at rootURL: URL, reference: String, base: String) -> Result<[GitSavedPatchFile], GitPatchFailure> {
        .failure(GitPatchFailure(L10n.string("Could not load saved changes")))
    }

    func savedShelfFiles(at rootURL: URL, patch: String, version: String, base: String) -> Result<[GitSavedPatchFile], GitPatchFailure> {
        .failure(GitPatchFailure(L10n.string("Could not load saved changes")))
    }

    func prepareWorkspaceCommit(_ request: GitWorkspaceCommitRequest) -> Result<GitWorkspaceCommitPreparation, GitWorkspaceCommitFailure> {
        .failure(GitWorkspaceCommitFailure("Workspace commit planning is unavailable"))
    }
    func stepWorkspaceCommit(_ session: GitWorkspaceCommitSession) -> Result<GitWorkspaceCommitSession, GitWorkspaceCommitFailure> {
        .failure(GitWorkspaceCommitFailure("Workspace commit execution is unavailable"))
    }
    func snapshot(at rootURL: URL, repositoryRoots: [URL]) -> GitSnapshot? { snapshot(at: rootURL) }
    func changesSnapshot(at rootURL: URL, repositoryRoots: [URL]) -> GitSnapshot? {
        snapshot(at: rootURL, repositoryRoots: repositoryRoots)
    }
    func untrackedDirectoryChildren(of directory: GitChange, repositoryRoots: [URL]) -> [GitChange]? { nil }

    func consolePresentation(_ request: GitConsolePresentationRequest) -> GitConsolePresentation? { nil }
    func executableResolution() -> Result<GitExecutableResolution, GitFetchFailure> { .failure(GitFetchFailure("Git executable resolution is unavailable.")) }
    func executionSettings(_ request: GitConfigurationEdit, save: Bool) -> Result<GitExecutionSettingsSnapshot, GitFetchFailure> { .failure(GitFetchFailure("Git configuration inspection is unavailable.")) }
    func remoteURL(at rootURL: URL, remote: String) -> String? { nil }
    func answerAuthentication(requestID: String, answer: String?) -> Bool { false }
    func pushPreview(
        _ reference: GitReference,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> Result<GitPushPreview, GitPushFailure> {
        .failure(GitPushFailure("Push preview is unavailable."))
    }
    func pushReviewed(
        _ reference: GitReference,
        preview: GitPushPreview,
        pushTarget: GitPushTargetChoice?,
        at rootURL: URL
    ) -> GitProcessResult? {
        GitProcessResult(output: "Reviewed push is unavailable.", exitCode: 1)
    }
    func fetchPlan(options: GitFetchOptions, at root: URL) -> Result<GitFetchPlan, GitFetchFailure> { fetchPlan(options: options) }
    func fetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, GitFetchFailure> {
        .failure(GitFetchFailure("Fetch preview is unavailable."))
    }
    func fetch(at rootURL: URL, options: GitFetchOptions, operationID: String) -> GitProcessResult? {
        GitProcessResult(output: "Configured Fetch is unavailable.", exitCode: 1)
    }
    func repositorySetup(at root: URL, scope: GitIdentityScope) -> Result<GitRepositorySetup, GitSetupFailure> {
        .failure(GitSetupFailure("Git setup is unavailable."))
    }
    func initializeRepository(at root: URL) -> Result<GitRepositorySetup, GitSetupFailure> {
        .failure(GitSetupFailure("Git setup is unavailable."))
    }
    func configureIdentity(at root: URL, scope: GitIdentityScope, field: GitIdentityField, value: String?) -> Result<GitRepositorySetup, GitSetupFailure> {
        .failure(GitSetupFailure("Git setup is unavailable."))
    }
    func interactiveRebasePreview(at rootURL: URL, revision: String) -> Result<GitRebasePreview, GitRebaseFailure> {
        .failure(GitRebaseFailure("Interactive rebase is unavailable."))
    }
    func interactiveRebaseSession(at rootURL: URL) -> Result<GitRebaseSession?, GitRebaseFailure> { .success(nil) }
    func startInteractiveRebase(at rootURL: URL, expectedState: GitRebaseExpectedState, steps: [GitRebaseStep]) -> GitRebaseProcessResult {
        GitRebaseProcessResult(command: GitProcessResult(output: "Interactive rebase is unavailable.", exitCode: 1), session: nil)
    }
    func controlInteractiveRebase(at rootURL: URL, sessionId: String, action: GitRebaseControlAction, amendMessage: String?, expectedHead: String?) -> GitRebaseProcessResult {
        GitRebaseProcessResult(command: GitProcessResult(output: "Interactive rebase is unavailable.", exitCode: 1), session: nil)
    }
    func createWorktree(_ request: GitWorktreeCreation, at rootURL: URL) -> GitProcessResult? {
        guard request.mode == .newBranch, !request.noCheckout, let name = request.name, let reference = request.reference else { return nil }
        return createWorktree(named: name, from: reference, revision: request.revision, at: request.destination, repositoryRoot: rootURL)
    }
    func createHistoryRecoveryBranch(named name: String, reference: String, at rootURL: URL) -> GitProcessResult? { nil }
    func setUpstream(branch: GitReference, to upstream: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func unsetUpstream(branch: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func updateBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func shelfCapture(at rootURL: URL) -> Result<GitShelfSnapshot, GitPatchFailure> { .failure(GitPatchFailure(L10n.string("Saved changes operation failed"))) }
    func shelfPlan(at rootURL: URL, phase: GitShelfPhase) -> Result<GitShelfPlan, GitPatchFailure> { .failure(GitPatchFailure(L10n.string("Saved changes operation failed"))) }
    func shelfStep(at rootURL: URL, phase: GitShelfPhase, layer: GitShelfLayer, snapshot: GitShelfSnapshot) -> GitProcessResult? { nil }
    func captureCommitMessageContext(_ repositories: [GitCommitMessageRepository]) -> Result<GitCommitMessageCoreCapture, GitPatchFailure> { .failure(GitPatchFailure("AI_COMMIT_DIFF_FAILED")) }
    func checkCommitMessageContext(_ context: GitCommitMessageContext) -> Bool { false }
    func exportPatch(at rootURL: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) -> Result<GitPatchExport, GitPatchFailure> {
        .failure(GitPatchFailure("Patch export is unavailable."))
    }
    func previewPatch(at rootURL: URL, patch: String, target: GitPatchTarget) -> Result<GitPatchPreview, GitPatchFailure> {
        .failure(GitPatchFailure("Patch preview is unavailable."))
    }
    func applyExchangePatch(at rootURL: URL, patch: String, target: GitPatchTarget, expectedState: String) -> GitProcessResult? { nil }
    func historyActionCapabilities(at rootURL: URL, revisions: [String], operationID: String) -> Result<GitHistoryActionCapabilities, GitHistoryActionFailure> { .failure(GitHistoryActionFailure()) }
    func historyRewritePreview(at rootURL: URL, operation: GitHistoryRewriteOperation, revisions: [String]) -> GitHistoryRewritePreview? { nil }
    func rewriteHistory(at rootURL: URL, expectedState: GitHistoryRewriteExpectedState, message: String?) -> GitProcessResult? { nil }
    func repositories(in workspaceURL: URL) -> [URL] {
        snapshot(at: workspaceURL).map { [$0.repositoryRoot] } ?? []
    }
    func repositoryColorAssignments(_ request: GitRepositoryColorPageRequest) -> GitRepositoryColorPage? { nil }

    func references(at rootURL: URL, operationID: String) -> GitReferenceSnapshot? {
        guard let snapshot = history(at: rootURL, reference: nil, limit: 1) else { return nil }
        return GitReferenceSnapshot(
            references: snapshot.references,
            recentReferences: snapshot.recentReferences,
            identity: snapshot.identity
        )
    }

    func branchNamePreview(
        rawName: String,
        requireName: Bool,
        references: [GitReference],
        reference: GitReference?
    ) -> GitBranchNamePreview? { nil }

    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPage? {
        let offset = cursor.flatMap(Int.init) ?? 0
        guard let snapshot = history(
            at: rootURL,
            reference: reference,
            limit: offset + limit + 1
        ) else { return nil }
        let page = Array(snapshot.commits.dropFirst(offset).prefix(limit))
        let hasMore = snapshot.commits.count > offset + page.count || snapshot.hasMore
        return GitHistoryPage(
            commits: page,
            nextCursor: hasMore ? String(offset + page.count) : nil,
            hasMore: hasMore
        )
    }

    func historyLocate(
        at rootURL: URL,
        reference: GitReference?,
        target: String,
        cursor: String?,
        limit: Int,
        maxPages: Int,
        operationID: String
    ) -> GitHistoryLocateResult? { nil }

    func closeHistoryCursor(at rootURL: URL, cursor: String) -> Bool { false }
    func cancel(operationID: String) -> Bool { false }
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
    private static let historyDateBatchSize = 4096
    private static let repositoryColorPageSize = 128
    private let operations: any GitOperations
    private let historyCache = GitHistoryCache()
    private let performanceLogger: any GitPerformanceLogger
    private let executionJournal: GitExecutionJournal?

    package init(
        operations: any GitOperations,
        performanceLogger: any GitPerformanceLogger = NullGitPerformanceLogger(),
        executionJournal: GitExecutionJournal? = nil
    ) {
        self.operations = operations
        self.performanceLogger = performanceLogger
        self.executionJournal = executionJournal
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
        package let historyRewrite: GitHistoryRewriteResult?
        package let warnings: [GitOperationWarning]
        package let logReference: LogRecordReference?

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
            historyRewrite: GitHistoryRewriteResult? = nil,
            warnings: [GitOperationWarning] = [],
            logReference: LogRecordReference? = nil
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
            self.historyRewrite = historyRewrite
            self.warnings = warnings
            self.logReference = logReference
        }

        package var succeeded: Bool {
            exitCode == 0 && operationErrorMessage == nil && stashRestoreConflict == nil
        }
    }

    func snapshot(for workspace: URL, repositoryRoots: [URL] = []) async -> GitSnapshot? {
        await read(priority: .utility) { $0.snapshot(at: workspace, repositoryRoots: repositoryRoots) }
    }

    func changesSnapshot(for workspace: URL, repositoryRoots: [URL]) async -> GitSnapshot? {
        await read(priority: .utility) { $0.changesSnapshot(at: workspace, repositoryRoots: repositoryRoots) }
    }

    func untrackedDirectoryChildren(of directory: GitChange, repositoryRoots: [URL]) async -> [GitChange]? {
        await read { $0.untrackedDirectoryChildren(of: directory, repositoryRoots: repositoryRoots) }
    }

    func repositories(in workspace: URL) async -> [URL] {
        await read(priority: .utility) { $0.repositories(in: workspace) } ?? []
    }

    /// Build the presentation cache off the main actor, sending only bounded pages.
    package func repositoryColors(_ roots: [URL]) async -> GitRepositoryColors? {
        await read(priority: .utility) { operations in
            let pageSize = Self.repositoryColorPageSize
            var slots: [String: Int] = [:]
            var firstPage: GitRepositoryColorPage?
            var offset = 0
            repeat {
                guard !Task.isCancelled else { return nil }
                let end = min(offset + pageSize, roots.count)
                let ids = roots[offset..<end].map { $0.standardizedFileURL.path }
                let request = GitRepositoryColorPageRequest(offset: offset, totalCount: roots.count, repositoryIds: ids)
                guard let page = operations.repositoryColorAssignments(request),
                      page.assignments.count == ids.count,
                      page.fallbackSlot >= 0,
                      zip(page.assignments, ids).allSatisfy({ $0.id == $1 && $0.slot >= 0 }),
                      firstPage.map({ $0.fallbackSlot == page.fallbackSlot && $0.showColors == page.showColors }) ?? true
                else { return nil }
                if firstPage == nil { firstPage = page }
                for assignment in page.assignments { slots[assignment.id] = assignment.slot }
                offset = end
            } while offset < roots.count
            guard let firstPage else { return nil }
            return GitRepositoryColors(slots: slots, fallbackSlot: firstPage.fallbackSlot, showColors: firstPage.showColors)
        }
    }

    func changelistProjection(_ request: GitChangelistCoreRequest) async -> GitChangelistCoreProjection? {
        await read { $0.changelistProjection(request) }
    }

    func reconcileDeletedSelection(at root: URL, changes: [GitChange]) async -> CommandResult {
        await command { $0.reconcileDeletedSelection(at: root, changes: changes) }
    }

    func prepareCommitSelection(_ request: GitCommitSelectionRequest) async -> CommandResult {
        await command { $0.prepareCommitSelection(request) }
    }

    func prepareWorkspaceCommit(_ request: GitWorkspaceCommitRequest) async -> Result<GitWorkspaceCommitPreparation, GitWorkspaceCommitFailure> {
        await workspaceCommitOperation { $0.prepareWorkspaceCommit(request) }
    }

    func stepWorkspaceCommit(_ session: GitWorkspaceCommitSession) async -> Result<GitWorkspaceCommitSession, GitWorkspaceCommitFailure> {
        await workspaceCommitOperation { $0.stepWorkspaceCommit(session) }
    }

    private func workspaceCommitOperation<T: Sendable>(
        _ operation: @escaping @Sendable (any GitOperations) -> Result<T, GitWorkspaceCommitFailure>
    ) async -> Result<T, GitWorkspaceCommitFailure> {
        let operations = self.operations
        let execution = GitExecutionContext.current
        return await withTaskCancellationHandler {
            await UserActionContext.detached(priority: .userInitiated) {
                GitExecutionContext.$current.withValue(execution) { operation(operations) }
            }.value
        } onCancel: {
            execution?.requestCancellation()
            if let execution { _ = operations.cancel(operationID: execution.operationID) }
        }
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
    /// Nil when Git could not export the change, which Shelve must not clean.
    func workingDiffPatch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> String? {
        await read {
            $0.diffPatch(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: false,
                untracked: change.isUntracked,
                whitespace: whitespace
            )
        }
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
    /// Nil when Git could not export the staged change.
    func stagedDiffPatch(
        for change: GitChange,
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) async -> String? {
        await read {
            $0.diffPatch(
                at: change.repositoryRoot,
                pathspecs: change.pathspecs,
                staged: true,
                untracked: false,
                whitespace: whitespace
            )
        }
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

    func prepareRollback(at root: URL, changes: [GitChange], deleteAddedFiles: Bool) async -> Result<GitRollbackPlan, GitRollbackFailure> {
        let operations = self.operations
        let execution = GitExecutionContext.current
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                GitExecutionContext.$current.withValue(execution) {
                    operations.prepareRollback(at: root, changes: changes, deleteAddedFiles: deleteAddedFiles)
                }
            }.value
        } onCancel: {
            execution?.requestCancellation()
            if let execution { _ = operations.cancel(operationID: execution.operationID) }
        }
    }

    func executeRollbackStep(at root: URL, step: GitRollbackPlan.Step) async -> CommandResult {
        await command(at: root) { $0.executeRollbackStep(at: root, step: step) }
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

    func historyActionCapabilities(at root: URL, revisions: [String], operationID: String) async -> GitHistoryActionCapabilities? {
        let result = await cancellableRead(operationID: operationID) {
            $0.historyActionCapabilities(at: root, revisions: revisions, operationID: operationID)
        }
        guard let result else { return nil }
        switch result {
        case .success(let capabilities): return capabilities
        case .failure:
            if !Task.isCancelled {
                performanceLogger.emit(VcsHistoryActionCapabilitiesFailed(error: LogFailure(domain: "GitHistoryActions", code: "query_failed")))
            }
            return nil
        }
    }

    func historyRewritePreview(at repositoryRoot: URL, operation: GitHistoryRewriteOperation, revisions: [String]) async -> GitHistoryRewritePreview? {
        await read { $0.historyRewritePreview(at: repositoryRoot, operation: operation, revisions: revisions) }
    }

    func interactiveRebasePreview(at root: URL, revision: String) async -> Result<GitRebasePreview, GitRebaseFailure> {
        await read { $0.interactiveRebasePreview(at: root, revision: revision) }
            ?? .failure(GitRebaseFailure("Could not inspect the rebase range."))
    }

    func executionSettings(_ request: GitConfigurationEdit, save: Bool) async -> Result<GitExecutionSettingsSnapshot, GitFetchFailure> {
        let operations = self.operations
        let context = save ? GitExecutionContext.current : nil
        return await UserActionContext.detached(priority: .userInitiated) {
            GitExecutionContext.$current.withValue(context) { operations.executionSettings(request, save: save) }
        }.value
    }
    func executableResolution() async -> Result<GitExecutableResolution, GitFetchFailure> {
        let operations = self.operations
        return await UserActionContext.detached(priority: .userInitiated) { operations.executableResolution() }.value
    }
    func remoteURL(at rootURL: URL, remote: String) async -> String? {
        let operations = self.operations
        return await UserActionContext.detached(priority: .utility) {
            operations.remoteURL(at: rootURL, remote: remote)
        }.value
    }
    func answerAuthentication(requestID: String, answer: String?) async -> Bool {
        let operations = self.operations
        return await UserActionContext.detached(priority: .userInitiated) { operations.answerAuthentication(requestID: requestID, answer: answer) }.value
    }

    func repositorySetup(at root: URL, scope: GitIdentityScope) async -> Result<GitRepositorySetup, GitSetupFailure> {
        await read { $0.repositorySetup(at: root, scope: scope) }
            ?? .failure(GitSetupFailure("Git setup is unavailable."))
    }

    func initializeRepository(at root: URL) async -> Result<GitRepositorySetup, GitSetupFailure> {
        await setupMutation { $0.initializeRepository(at: root) }
    }

    func configureIdentity(at root: URL, scope: GitIdentityScope, field: GitIdentityField, value: String?) async -> Result<GitRepositorySetup, GitSetupFailure> {
        await setupMutation { $0.configureIdentity(at: root, scope: scope, field: field, value: value) }
    }

    private func setupMutation(_ operation: @escaping @Sendable (any GitOperations) -> Result<GitRepositorySetup, GitSetupFailure>) async -> Result<GitRepositorySetup, GitSetupFailure> {
        let context = GitExecutionContext.current
        let operations = self.operations
        return await UserActionContext.detached(priority: .userInitiated) { GitExecutionContext.$current.withValue(context) { operation(operations) } }.value
    }

    func interactiveRebaseSession(at root: URL) async -> Result<GitRebaseSession?, GitRebaseFailure> {
        await read { $0.interactiveRebaseSession(at: root) }
            ?? .failure(GitRebaseFailure("Could not inspect the rebase session."))
    }

    func startInteractiveRebase(at root: URL, expectedState: GitRebaseExpectedState, steps: [GitRebaseStep]) async -> GitRebaseMutationResult {
        await rebaseCommand(at: root) { $0.startInteractiveRebase(at: root, expectedState: expectedState, steps: steps) }
    }

    func controlInteractiveRebase(at root: URL, sessionId: String, action: GitRebaseControlAction, amendMessage: String?, expectedHead: String?) async -> GitRebaseMutationResult {
        await rebaseCommand(at: root) { $0.controlInteractiveRebase(at: root, sessionId: sessionId, action: action, amendMessage: amendMessage, expectedHead: expectedHead) }
    }

    private func rebaseCommand(
        at root: URL,
        _ operation: @escaping @Sendable (any GitOperations) -> GitRebaseProcessResult
    ) async -> GitRebaseMutationResult {
        let operations = self.operations
        let execution = GitExecutionContext.current
        let response = await withTaskCancellationHandler {
            await UserActionContext.detached(priority: .userInitiated) {
                GitExecutionContext.$current.withValue(execution) { operation(operations) }
            }.value
        } onCancel: {
            execution?.requestCancellation()
            if let execution { _ = operations.cancel(operationID: execution.operationID) }
        }
        let result = response.command
        return GitRebaseMutationResult(command: CommandResult(
            workingDirectory: root, arguments: result.arguments, output: result.output,
            standardOutput: result.standardOutput, standardError: result.standardError,
            exitCode: result.exitCode, invocations: result.invocations,
            operationErrorMessage: result.operationErrorMessage,
            stashRestoreConflict: result.stashRestoreConflict, tagDeletion: result.tagDeletion,
            branchDeletion: result.branchDeletion, historyRewrite: result.historyRewrite,
            warnings: result.warnings
        ), session: response.session)
    }

    func createWorktree(_ request: GitWorktreeCreation, at root: URL) async -> CommandResult {
        await command(at: root) { $0.createWorktree(request, at: root) }
    }

    func shelfCapture(at root: URL) async -> Result<GitShelfSnapshot, GitPatchFailure> {
        await read { $0.shelfCapture(at: root) } ?? .failure(GitPatchFailure(L10n.string("Saved changes operation failed")))
    }
    func shelfPlan(at root: URL, phase: GitShelfPhase) async -> Result<GitShelfPlan, GitPatchFailure> {
        await read { $0.shelfPlan(at: root, phase: phase) } ?? .failure(GitPatchFailure(L10n.string("Saved changes operation failed")))
    }
    func shelfStep(at root: URL, phase: GitShelfPhase, layer: GitShelfLayer, snapshot: GitShelfSnapshot) async -> CommandResult {
        await command(at: root) { $0.shelfStep(at: root, phase: phase, layer: layer, snapshot: snapshot) }
    }

    func captureCommitMessageContext(_ repositories: [GitCommitMessageRepository]) async -> Result<GitCommitMessageCoreCapture, GitPatchFailure> {
        await read { $0.captureCommitMessageContext(repositories) } ?? .failure(GitPatchFailure("AI_COMMIT_DIFF_FAILED"))
    }
    func checkCommitMessageContext(_ context: GitCommitMessageContext) async -> Bool {
        await read { $0.checkCommitMessageContext(context) } ?? false
    }

    func exportPatch(at root: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) async -> Result<GitPatchExport, GitPatchFailure> {
        await read { $0.exportPatch(at: root, source: source, paths: paths, base: base, target: target, metadataOnly: metadataOnly) }
            ?? .failure(GitPatchFailure("Could not create a patch preview."))
    }

    func previewPatch(at root: URL, patch: String, target: GitPatchTarget) async -> Result<GitPatchPreview, GitPatchFailure> {
        await read { $0.previewPatch(at: root, patch: patch, target: target) }
            ?? .failure(GitPatchFailure("Could not inspect the patch."))
    }

    func applyExchangePatch(at root: URL, patch: String, target: GitPatchTarget, expectedState: String) async -> CommandResult {
        await command(at: root) { $0.applyExchangePatch(at: root, patch: patch, target: target, expectedState: expectedState) }
    }

    func rewriteHistory(at repositoryRoot: URL, expectedState: GitHistoryRewriteExpectedState, message: String?) async -> CommandResult {
        await command(at: repositoryRoot) { $0.rewriteHistory(at: repositoryRoot, expectedState: expectedState, message: message) }
    }

    func createHistoryRecoveryBranch(named name: String, reference: String, at root: URL) async -> CommandResult {
        await command(at: root) { $0.createHistoryRecoveryBranch(named: name, reference: reference, at: root) }
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

    func historyDateMatches(_ commits: [GitCommit], after: Date?, before: Date?) async -> Set<String>? {
        let matches = await read(priority: .userInitiated) { operations -> Set<String>? in
            var matches: Set<String> = []
            for start in stride(from: 0, to: commits.count, by: Self.historyDateBatchSize) {
                guard !Task.isCancelled else { return nil }
                let end = min(start + Self.historyDateBatchSize, commits.count)
                let entries = commits[start..<end].map { commit in
                    let fallback = commit.dateUtcOffsetMinutes == nil
                        ? (commit.dateUnixSeconds.map(Double.init) ?? GitLogQuery.parseCommitDate(commit.date)?.timeIntervalSince1970)
                        : nil
                    return GitHistoryDateQuery.Entry(id: commit.hash, date: commit.date,
                        utcOffsetMinutes: commit.dateUtcOffsetMinutes, fallbackUnixSeconds: fallback)
                }
                let query = GitHistoryDateQuery(entries: entries, afterUnixSeconds: after?.timeIntervalSince1970,
                    beforeUnixSeconds: before?.timeIntervalSince1970)
                guard let batch = operations.historyDateMatches(query) else { return nil }
                matches.formUnion(batch)
            }
            return matches
        }
        if matches == nil && !Task.isCancelled {
            performanceLogger.emit(VcsHistoryDateQueryFailed(error: LogFailure(domain: "GitHistoryQuery", code: "query_failed")))
        }
        return matches
    }

    func history(
        at repositoryRoot: URL,
        reference: GitReference? = nil,
        limit: Int = 300
    ) async -> GitHistorySnapshot {
        let historyLookupStartedAt = ContinuousClock.now
        if let cached = await historyCache.value(rootURL: repositoryRoot, reference: reference, limit: limit) {
            performanceLogger.emit(
                PerfGitCacheHit(duration: .milliseconds(elapsedMilliseconds(since: historyLookupStartedAt)), operation: "history")
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

    func references(
        at repositoryRoot: URL,
        operationID: String
    ) async -> GitReferenceSnapshot? {
        await cancellableRead(operationID: operationID) {
            $0.references(at: repositoryRoot, operationID: operationID)
        }
    }

    func branchNamePreview(
        rawName: String,
        requireName: Bool,
        references: [GitReference],
        reference: GitReference?
    ) async -> GitBranchNamePreview? {
        await read {
            $0.branchNamePreview(
                rawName: rawName,
                requireName: requireName,
                references: references,
                reference: reference
            )
        }
    }

    func historyPage(
        at repositoryRoot: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) async -> GitHistoryPage? {
        await cancellableRead(operationID: operationID) {
            $0.historyPage(
                at: repositoryRoot,
                reference: reference,
                cursor: cursor,
                limit: limit,
                operationID: operationID
            )
        }
    }

    func historyLocate(
        at repositoryRoot: URL,
        reference: GitReference?,
        target: String,
        cursor: String?,
        limit: Int,
        maxPages: Int,
        operationID: String
    ) async -> GitHistoryLocateResult? {
        await cancellableRead(operationID: operationID) {
            $0.historyLocate(
                at: repositoryRoot,
                reference: reference,
                target: target,
                cursor: cursor,
                limit: limit,
                maxPages: maxPages,
                operationID: operationID
            )
        }
    }

    @discardableResult
    package func closeHistoryCursor(at repositoryRoot: URL, cursor: String) -> Bool {
        operations.closeHistoryCursor(at: repositoryRoot, cursor: cursor)
    }

    @discardableResult
    package func cancel(operationID: String) -> Bool {
        operations.cancel(operationID: operationID)
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

    func workspaceStatusPlan(roots: [String], previousRoots: [String], outcomes: [GitWorkspaceStatusOutcome]) async -> GitWorkspaceStatusPlan? {
        await read(priority: .utility) { $0.workspaceStatusPlan(roots: roots, previousRoots: previousRoots, outcomes: outcomes) }
    }

    func blame(fileURL: URL, at repositoryRoot: URL) async -> [GitBlameLine] {
        return await read(priority: .utility) { operations in
            guard let context = operations.resolveFileContext(fileURL: fileURL, relativeTo: repositoryRoot),
                  context.ownership == "git" else { return nil }
            return operations.blame(at: URL(fileURLWithPath: context.root), relativePath: context.path)
        } ?? []
    }

    func comparisonWithWorkingTree(
        for reference: GitReference,
        at repositoryRoot: URL
    ) async -> GitBranchComparison {
        let comparison: GitBranchComparison? = await read(priority: .utility) {
            $0.comparison(for: reference, at: repositoryRoot)
        }
        return GitBranchComparison(reference: reference, files: comparison?.files ?? [])
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

    func setUpstream(
        _ reference: GitReference,
        to upstream: GitReference,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.setUpstream(branch: reference, to: upstream, at: repositoryRoot)
        }
    }

    func unsetUpstream(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.unsetUpstream(branch: reference, at: repositoryRoot)
        }
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

    func updateBranch(_ reference: GitReference, at repositoryRoot: URL) async -> CommandResult {
        await command(at: repositoryRoot) { $0.updateBranch(reference, at: repositoryRoot) }
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

    package func cancelExecution(_ context: GitExecutionContext) {
        context.requestCancellation()
        _ = operations.cancel(operationID: context.operationID)
    }

    /// Cancels a shared-journal request whose lifetime is owned by another feature.
    package func cancelExecution(operationID: String) {
        _ = operations.cancel(operationID: operationID)
    }

    package func fetchPlan(options: GitFetchOptions, at root: URL? = nil) async -> Result<GitFetchPlan, GitFetchFailure> {
        let operations = self.operations
        return await UserActionContext.detached(priority: .userInitiated) { root.map { operations.fetchPlan(options: options, at: $0) } ?? operations.fetchPlan(options: options) }.value
    }

    package func fetch(at root: URL, options: GitFetchOptions, operationID: String) async -> CommandResult {
        await withTaskCancellationHandler {
            await command(at: root) { $0.fetch(at: root, options: options, operationID: operationID) }
        } onCancel: {
            _ = operations.cancel(operationID: operationID)
        }
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

    func push(
        _ reference: GitReference,
        pushTarget: String? = nil,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.push(reference, pushTarget: pushTarget, at: repositoryRoot)
        }
    }

    func pushPreview(
        _ reference: GitReference,
        pushTarget: GitPushTargetChoice? = nil,
        at repositoryRoot: URL
    ) async -> Result<GitPushPreview, GitPushFailure> {
        let operations = self.operations
        return await UserActionContext.detached(priority: .userInitiated) {
            operations.pushPreview(reference, pushTarget: pushTarget, at: repositoryRoot)
        }.value
    }

    func pushReviewed(
        _ reference: GitReference,
        preview: GitPushPreview,
        pushTarget: GitPushTargetChoice?,
        at repositoryRoot: URL
    ) async -> CommandResult {
        await command(at: repositoryRoot) {
            $0.pushReviewed(reference, preview: preview, pushTarget: pushTarget, at: repositoryRoot)
        }
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
        let execution = GitExecutionContext.current
        let result = await withTaskCancellationHandler {
            await UserActionContext.detached(priority: .userInitiated) {
                GitExecutionContext.$current.withValue(execution) { operation(operations) }
            }.value
        } onCancel: {
            execution?.requestCancellation()
            if let execution { _ = operations.cancel(operationID: execution.operationID) }
        }
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
            historyRewrite: result?.historyRewrite,
            warnings: result?.warnings ?? [],
            logReference: execution.flatMap { Self.failureReference(result, execution: $0) }
        )
        performanceLogger.emit(
            PerfGitCommandFinished(duration: .milliseconds(elapsedMilliseconds(since: startedAt)), operation: String(operationName.prefix(while: { $0 != "(" })), succeeded: commandResult.succeeded)
        )
        return commandResult
    }

    /// Core records a failed Git process under the request's trace operation, and a
    /// request that failed without one as a Core request. An operation-level failure
    /// whose processes all exited 0 left no Core failure, so the caller records it.
    static func failureReference(_ result: GitProcessResult?, execution: GitExecutionContext) -> LogRecordReference? {
        if let result, result.exitCode == 0, result.operationErrorMessage == nil, result.stashRestoreConflict == nil { return nil }
        let failedProcess = result?.invocations.contains { $0.exitCode != 0 } == true
        if result?.exitCode == 0, !failedProcess { return nil }
        return LogRecordReference(channel: failedProcess ? "vcs/git" : "app/core",
            event: failedProcess ? VcsGitCommandFailed.id : AppCoreRequestFailed.id, op: execution.traceOperationID)
    }

    package func consolePresentation(_ request: GitConsolePresentationRequest) async -> GitConsolePresentation? {
        await read { $0.consolePresentation(request) }
    }

    func savedChangesSnapshot(stash: GitStash?, shelf: GitShelfEntry?, at root: URL) async -> Result<GitSavedChangesSnapshot, GitPatchFailure> {
        let performanceLogger = performanceLogger
        return await read { operations in
            do {
                var patches: [(String, String, String)] = []
                let identity: String
                if let stash {
                    guard let commit = operations.commit(at: root, hash: stash.reference) else {
                        throw GitPatchFailure(L10n.string("Could not load saved changes"))
                    }
                    identity = commit.hash
                    let base = commit.parentHashes.first.map { String($0.prefix(8)) } ?? "HEAD"
                    let files = try operations.savedStashFiles(at: root, reference: identity, base: base).get()
                    try Task.checkCancellation()
                    return .success(GitSavedChangesSnapshot(id: identity, repositoryRoot: root, files: files))
                } else if let shelf {
                    identity = shelf.id.uuidString
                    patches = [("Staged", "HEAD", shelf.stagedPatch), ("Working tree", "Index", shelf.workingPatch)]
                } else { throw GitPatchFailure(L10n.string("Select saved changes")) }
                var files: [GitSavedPatchFile] = []
                for (version, base, patch) in patches {
                    guard !patch.isEmpty else { continue }
                    try Task.checkCancellation()
                    let parsed = try operations.savedShelfFiles(at: root, patch: patch, version: version, base: base).get()
                    files.append(contentsOf: parsed)
                }
                return .success(GitSavedChangesSnapshot(id: identity, repositoryRoot: root, files: files))
            } catch {
                if !(error is CancellationError) {
                    performanceLogger.emit(VcsShelfOperationFailed(error: LogFailure(domain: "GitSavedChanges", code: "load_failed"), stage: "load"))
                }
                return .failure(GitPatchFailure(error.localizedDescription))
            }
        } ?? .failure(GitPatchFailure(L10n.string("Could not load saved changes")))
    }

    private func read<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        operationName: String = #function,
        _ operation: @escaping @Sendable (any GitOperations) -> T?
    ) async -> T? {
        let operations = self.operations
        let startedAt = ContinuousClock.now
        let source = GitExecutionSource.current
        let task = UserActionContext.detached(priority: priority) {
            GitExecutionSource.$current.withValue(source) { operation(operations) }
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        performanceLogger.emit(
            PerfGitReadFinished(duration: .milliseconds(elapsedMilliseconds(since: startedAt)), operation: String(operationName.prefix(while: { $0 != "(" })), succeeded: result != nil)
        )
        return result
    }

    package func recordWorktreeInspection(
        worktreeID: String,
        phase: String,
        durationMilliseconds: Int
    ) {
        // Worktree IDs are paths in the UI; keep them out of channel identities.
        performanceLogger.emit(PerfGitWorktreeInspected(duration: .milliseconds(durationMilliseconds), phase: phase, worktree: URL(fileURLWithPath: worktreeID)))
    }

    private func elapsedMilliseconds(since startedAt: ContinuousClock.Instant) -> Int {
        let components = startedAt.duration(to: .now).components
        let milliseconds = (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
        return max(0, Int(milliseconds.rounded()))
    }

    private func cancellableRead<T: Sendable>(
        priority: TaskPriority = .utility,
        operationID: String,
        _ operation: @escaping @Sendable (any GitOperations) -> T?
    ) async -> T? {
        let operations = self.operations
        let source = GitExecutionSource.current
        let task = UserActionContext.detached(priority: priority) {
            GitExecutionSource.$current.withValue(source) { operation(operations) }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            _ = operations.cancel(operationID: operationID)
        }
    }
}
