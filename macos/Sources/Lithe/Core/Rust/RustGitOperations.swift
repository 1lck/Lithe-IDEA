import Foundation
import LitheGitModule

/// Typed Git operations exposed by Rust Core.
///
/// This is the migration seam for GitService. The Swift service can continue
/// to translate Rust payloads into SwiftUI-facing models while Git execution
/// and patch application remain shared and platform-neutral.
struct RustGitOperations: GitOperations, Sendable {
    let core: RustCoreBridge

    private func makeProcessResult(_ response: RustCoreBridge.GitCommandPayload) -> GitProcessResult {
        GitProcessResult(
            arguments: response.arguments ?? [],
            output: response.operationError?.userMessage ?? response.output,
            standardOutput: response.stdout,
            standardError: response.stderr,
            exitCode: response.exitCode,
            invocations: response.invocations?.map {
                GitProcessInvocation(
                    arguments: $0.arguments,
                    standardOutput: $0.stdout,
                    standardError: $0.stderr,
                    exitCode: $0.exitCode
                )
            } ?? [],
            operationErrorMessage: response.operationError?.userMessage,
            stashRestoreConflict: response.stashRestore.map {
                GitStashRestoreConflict(
                    stashReference: $0.stashReference,
                    conflictedPaths: $0.conflictedPaths
                )
            },
            warnings: response.warnings?.map {
                GitOperationWarning(code: $0.code, message: $0.message, details: $0.details)
            } ?? []
        )
    }

    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> GitProcessResult {
        switch core.gitCommandResult(
            at: URL(fileURLWithPath: workingDirectory),
            arguments: arguments,
            input: input
        ) {
        case .success(let response):
            return makeProcessResult(response)
        case .failure(let error):
            return GitProcessResult(
                output: error.userMessage,
                standardError: error.userMessage,
                exitCode: 1
            )
        }
    }

    private func write(
        at rootURL: URL,
        operation: String,
        paths: [String] = [],
        reference: String? = nil,
        gitReference: GitReference? = nil,
        referenceKind: GitReferenceKind? = nil,
        revision: String? = nil,
        name: String? = nil,
        message: String? = nil,
        remote: String? = nil,
        destination: URL? = nil,
        mode: String? = nil,
        includeUntracked: Bool = false,
        checkout: Bool = false,
        amend: Bool = false,
        force: Bool = false,
        autoStash: Bool = false
    ) -> GitProcessResult? {
        switch core.gitWriteResult(
            at: rootURL,
            operation: operation,
            paths: paths,
            reference: reference,
            gitReference: gitReference,
            referenceKind: referenceKind?.rawValue,
            revision: revision,
            name: name,
            message: message,
            remote: remote,
            destination: destination?.path,
            mode: mode,
            includeUntracked: includeUntracked,
            checkout: checkout,
            amend: amend,
            force: force,
            autoStash: autoStash
        ) {
        case .success(let response):
            return makeProcessResult(response)
        case .failure(let error):
            return GitProcessResult(output: error.userMessage, exitCode: 1)
        }
    }

    func stage(_ change: GitChange) -> GitProcessResult? {
        write(at: change.repositoryRoot, operation: "stage", paths: change.pathspecs)
    }

    func unstage(_ change: GitChange) -> GitProcessResult? {
        write(at: change.repositoryRoot, operation: "unstage", paths: change.pathspecs)
    }

    func discard(_ change: GitChange) -> GitProcessResult? {
        return write(at: change.repositoryRoot, operation: "discard", paths: change.pathspecs)
    }

    func discardAll(_ change: GitChange) -> GitProcessResult? {
        write(at: change.repositoryRoot, operation: "discardAll", paths: change.pathspecs)
    }

    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? {
        write(at: rootURL, operation: "commit", message: message, amend: amend)
    }

    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "cherryPick", revision: hash)
    }

    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "revert", revision: hash)
    }

    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "reset", revision: hash, mode: mode)
    }

    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? {
        write(
            at: rootURL,
            operation: "createBranch",
            gitReference: reference,
            name: name,
            checkout: checkout
        )
    }

    func createWorktree(
        named name: String,
        from reference: GitReference,
        at destination: URL,
        repositoryRoot: URL
    ) -> GitProcessResult? {
        write(
            at: repositoryRoot,
            operation: "createWorktree",
            gitReference: reference,
            name: name,
            destination: destination
        )
    }

    func removeWorktree(
        _ worktree: GitWorktree,
        force: Bool,
        at rootURL: URL
    ) -> GitProcessResult? {
        write(
            at: rootURL,
            operation: "removeWorktree",
            destination: worktree.url,
            force: force
        )
    }

    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "lockWorktree", destination: worktree.url)
    }

    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "unlockWorktree", destination: worktree.url)
    }

    func repairWorktrees(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "repairWorktrees")
    }

    func pruneWorktrees(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "pruneWorktrees")
    }

    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "renameBranch", gitReference: reference, name: name)
    }

    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "deleteBranch", gitReference: reference)
    }

    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "merge", gitReference: reference)
    }

    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "rebase", gitReference: reference)
    }

    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "checkoutAndRebase", gitReference: reference)
    }

    func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy,
        at rootURL: URL
    ) -> GitProcessResult? {
        write(
            at: rootURL,
            operation: "pull",
            gitReference: reference,
            mode: strategy.rawValue
        )
    }

    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy = .ffOnly) -> GitProcessResult? {
        write(at: rootURL, operation: "pull", mode: strategy.rawValue)
    }

    /// Staged files still containing conflict markers.
    func conflictMarkerPaths(at rootURL: URL) -> [String] {
        core.gitConflictMarkerPaths(at: rootURL)?.paths ?? []
    }

    /// Reports what would stop an integration, so the caller can ask before failing.
    func integrationPreflight(
        for target: GitIntegrationTarget,
        operation: GitIntegrationOperation,
        at rootURL: URL
    ) -> GitIntegrationPreflightState? {
        let payload: RustCoreBridge.GitIntegrationPreflightPayload?
        switch target {
        case .reference(let reference):
            payload = core.gitIntegrationPreflight(
                at: rootURL,
                gitReference: reference,
                operation: operation.rawValue
            )
        case .commit:
            payload = core.gitIntegrationPreflight(
                at: rootURL,
                reference: target.revision,
                operation: operation.rawValue
            )
        }
        guard let payload else { return nil }
        return GitIntegrationPreflightState(
            blockingPaths: payload.blockingPaths,
            blocksEntirely: payload.blocksEntirely
        )
    }

    /// Reports whether a pull can fast-forward, so the caller can ask before failing.
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? {
        guard let payload = core.gitPullPreflight(at: rootURL) else { return nil }
        return GitPullPreflightState(
            upstream: payload.upstream,
            ahead: payload.ahead,
            behind: payload.behind,
            diverged: payload.diverged,
            hasLocalChanges: payload.hasLocalChanges
        )
    }

    func fetch(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "fetch")
    }

    func checkout(
        _ reference: GitReference,
        at rootURL: URL,
        force: Bool = false,
        autoStash: Bool = false
    ) -> GitProcessResult? {
        write(
            at: rootURL,
            operation: "checkout",
            gitReference: reference,
            force: force,
            autoStash: autoStash
        )
    }

    /// Returns the working-tree paths that would block checking out `reference`.
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] {
        core.gitCheckoutPreflight(at: rootURL, reference: reference)?.blockingPaths ?? []
    }

    func operationState(at rootURL: URL) -> GitOperationState? {
        guard let payload = core.gitOperationState(at: rootURL),
              // Rust reports an idle repository as an empty kind rather than an
              // absent payload; only a recognised kind is an operation in progress.
              let kind = GitOperationKind(rawValue: payload.kind) else { return nil }
        return GitOperationState(
            kind: kind,
            reference: payload.reference,
            step: payload.step,
            total: payload.total,
            conflictedPaths: payload.conflictedPaths
        )
    }

    func continueOperation(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "operationContinue")
    }

    func abortOperation(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "operationAbort")
    }

    func skipOperationStep(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "operationSkip")
    }

    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "checkoutRevision", revision: revision)
    }

    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "push", gitReference: reference)
    }

    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? {
        write(
            at: destination.deletingLastPathComponent(),
            operation: "clone",
            remote: remote,
            destination: destination
        )
    }

    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? {
        write(
            at: rootURL,
            operation: "stashPush",
            message: message,
            includeUntracked: includeUntracked
        )
    }

    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "stashApply", reference: stash.reference)
    }

    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "stashPop", reference: stash.reference)
    }

    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "stashDrop", reference: stash.reference)
    }

    func stageAll(at rootURL: URL) -> GitProcessResult? {
        write(at: rootURL, operation: "stageAll")
    }

    func snapshot(at rootURL: URL) -> GitSnapshot? {
        core.gitStatus(at: rootURL)?.makeSnapshot(at: rootURL)
    }

    func watchContext(at rootURL: URL) -> GitWatchContext? {
        core.gitWatchContext(at: rootURL)?.makeContext()
    }

    func worktrees(at rootURL: URL) -> [GitWorktree]? {
        core.gitWorktrees(at: rootURL)?.worktrees.map { $0.makeModel() }
    }

    func diffPatch(
        at rootURL: URL,
        pathspecs: [String],
        staged: Bool,
        untracked: Bool,
        whitespace: GitDiffWhitespaceMode
    ) -> String? {
        core.gitDiff(
            at: rootURL,
            pathspecs: pathspecs,
            staged: staged,
            untracked: untracked,
            ignoreAllWhitespace: whitespace == .ignoreAllWhitespace
        )?.patch
    }

    func diffDocument(
        at rootURL: URL,
        pathspecs: [String],
        staged: Bool,
        untracked: Bool,
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument? {
        core.gitDiff(
            at: rootURL,
            pathspecs: pathspecs,
            staged: staged,
            untracked: untracked,
            ignoreAllWhitespace: whitespace == .ignoreAllWhitespace
        )?.makeDocument()
    }

    func commitDiffDocument(
        at rootURL: URL,
        commit: String,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode
    ) -> DiffDocument? {
        core.gitDiff(
            at: rootURL,
            pathspecs: pathspecs,
            commit: commit,
            staged: false,
            untracked: false,
            ignoreAllWhitespace: whitespace == .ignoreAllWhitespace
        )?.makeDocument()
    }

    func comparisonDiffDocument(
        at rootURL: URL,
        reference: String,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) -> DiffDocument? {
        core.gitDiff(
            at: rootURL,
            pathspecs: pathspecs,
            reference: reference,
            staged: false,
            untracked: false,
            ignoreAllWhitespace: whitespace == .ignoreAllWhitespace
        )?.makeDocument()
    }

    func comparisonDiffDocument(
        at rootURL: URL,
        reference: GitReference,
        targetReference: GitReference?,
        pathspecs: [String],
        whitespace: GitDiffWhitespaceMode = .doNotIgnore
    ) -> DiffDocument? {
        core.gitDiff(
            at: rootURL,
            pathspecs: pathspecs,
            gitReference: reference,
            targetGitReference: targetReference,
            staged: false,
            untracked: false,
            ignoreAllWhitespace: whitespace == .ignoreAllWhitespace
        )?.makeDocument()
    }

    func applyPatch(
        _ patch: String,
        at rootURL: URL,
        mode: String
    ) -> GitProcessResult? {
        switch core.gitApplyResult(at: rootURL, patch: patch, mode: mode) {
        case .success(let response):
            return GitProcessResult(output: response.output, exitCode: response.exitCode)
        case .failure(let error):
            return GitProcessResult(output: error.userMessage, exitCode: 1)
        }
    }

    func history(
        at rootURL: URL,
        reference: GitReference?,
        limit: Int
    ) -> GitHistorySnapshot? {
        core.gitHistory(
            at: rootURL,
            reference: reference?.fullName,
            limit: limit
        )?.makeSnapshot()
    }

    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? {
        core.gitCommitFiles(at: rootURL, commit: commit.hash)?.files.map { file in
            GitCommitFile(status: file.status, path: file.path)
        }
    }

    func commit(at rootURL: URL, hash: String) -> GitCommit? {
        core.gitCommit(at: rootURL, commit: hash)?.makeModel()
    }

    func comparison(
        for reference: GitReference,
        at rootURL: URL
    ) -> GitBranchComparison? {
        guard let payload = core.gitComparison(at: rootURL, gitReference: reference) else {
            return nil
        }
        return GitBranchComparison(
            reference: reference,
            files: payload.files.map { file in
                GitBranchComparisonFile(status: file.status, path: file.path)
            }
        )
    }

    func comparison(
        from reference: GitReference,
        to target: GitReference,
        at rootURL: URL
    ) -> GitBranchComparison? {
        guard let payload = core.gitComparison(
            at: rootURL,
            gitReference: reference,
            targetGitReference: target
        ) else { return nil }
        return GitBranchComparison(
            reference: reference,
            targetReference: target,
            files: payload.files.map { file in
                GitBranchComparisonFile(status: file.status, path: file.path)
            }
        )
    }

    func stashes(at rootURL: URL) -> [GitStash]? {
        core.gitStashes(at: rootURL)?.stashes.map { stash in
            GitStash(
                reference: stash.reference,
                message: stash.message,
                branch: stash.branch,
                date: stash.date
            )
        }
    }

    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? {
        core.gitBlame(at: rootURL, relativePath: relativePath)?.makeModels()
    }
}

/// Workspace Foundation only needs repository metadata paths for its watcher.
/// This narrow provider avoids constructing the complete Git workflow while
/// the on-demand Git module is inactive.
struct RustGitWatchContextProvider: GitWatchContextProviding, Sendable {
    let core: RustCoreBridge

    func watchContext(for workspace: URL) async -> GitWatchContext? {
        core.gitWatchContext(at: workspace)?.makeContext()
    }
}
