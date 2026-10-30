import Combine
import Foundation
import LitheApplicationKernel
@testable import LitheGitModule
import LitheModuleAPI
import Testing

@MainActor
struct GitModuleTests {
    @Test
    func independentDiffSessionsKeepBuffersAndRejectClosedReads() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let firstChange = GitChange(repositoryRoot: root, path: "first.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let secondChange = GitChange(repositoryRoot: root, path: "second.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let probe = RepositoryDiffDocumentProbe(blockedCall: 1)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()),
            diffDocumentProvider: { _, _ in await probe.read() })
        let first = feature.repositoryDiffSession(id: UUID())
        let second = feature.repositoryDiffSession(id: UUID())
        let pending = Task { await feature.selectChange(firstChange, session: first) }
        defer { probe.release.open(); pending.cancel(); feature.reset() }
        try #require(await probe.started.waitUntilOpen(), "First tab did not reach its read gate")
        await feature.selectChange(secondChange, session: second)
        #expect(second.selectedChange == secondChange && second.selectedDiffPatch == "fresh")
        #expect(first.isLoadingDiff && first.selectedDiffPatch.isEmpty)
        feature.activateRepositoryDiffSession(second.id)
        second.gitDiffWhitespaceMode = .ignoreAllWhitespace
        #expect(first.gitDiffWhitespaceMode == .doNotIgnore)
        feature.closeRepositoryDiffSession(first.id)
        probe.release.open()
        try #require(await waitForGitTaskCompletion(pending))
        #expect(first.isClosed && first.diffRows.isEmpty && !first.isLoadingDiff)
        #expect(second.selectedChange == secondChange && second.diffRows.first?.rightText == "fresh")
        #expect(feature.hasActiveModuleWork, "An open tab must keep its Git module alive")
        feature.closeRepositoryDiffSession(second.id)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test
    func independentSavedDiffSessionsSurviveHistorySelectionAndOtherTabClose() async {
        let root = URL(fileURLWithPath: "/workspace")
        let file = GitCommitFile(status: "M", path: "same.txt")
        let snapshot = GitSavedChangesSnapshot(id: "stash", repositoryRoot: root, files: ["one", "two"].map {
            GitSavedPatchFile(file: file, version: $0, base: "base",
                patch: "diff --git a/same.txt b/same.txt\n--- a/same.txt\n+++ b/same.txt\n@@ -1 +1 @@\n-old\n+\($0)\n")
        })
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let first = feature.repositoryDiffSession(id: UUID()), second = feature.repositoryDiffSession(id: UUID())
        feature.showSavedChangesDiff(snapshot, version: "one", file: file, session: first)
        feature.showSavedChangesDiff(snapshot, version: "two", file: file, session: second)
        feature.activateRepositoryDiffSession(first.id)
        feature.previewGitCommitSelection(makeTestCommit(hash: "other", subject: "Other"))
        #expect(first.selectedGitCommitFile == file && second.selectedGitCommitFile == file)
        #expect(first.selectedGitCommitDiffContext?.id != second.selectedGitCommitDiffContext?.id)
        #expect(first.diffRows.contains { $0.rightText == "one" })
        #expect(second.diffRows.contains { $0.rightText == "two" })
        feature.closeRepositoryDiffSession(first.id)
        #expect(second.diffRows.contains { $0.rightText == "two" })
    }

    @Test
    func savedDiffRejectsAnotherRepositoryAndUnknownFileWithoutTouchingTheSession() async {
        let root = URL(fileURLWithPath: "/workspace"), other = URL(fileURLWithPath: "/other")
        let file = GitCommitFile(status: "M", path: "same.txt")
        func snapshot(in repository: URL) -> GitSavedChangesSnapshot {
            GitSavedChangesSnapshot(id: "stash", repositoryRoot: repository, files: [
                GitSavedPatchFile(file: file, version: "one", base: "base",
                    patch: "diff --git a/same.txt b/same.txt\n--- a/same.txt\n+++ b/same.txt\n@@ -1 +1 @@\n-old\n+one\n")
            ])
        }
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let session = feature.repositoryDiffSession(id: UUID())

        feature.showSavedChangesDiff(snapshot(in: other), version: "one", file: file, session: session)
        feature.showSavedChangesDiff(snapshot(in: root), version: "missing", file: file, session: session)
        #expect(session.savedDiffSnapshot == nil && session.selectedGitCommitFile == nil && session.diffRows.isEmpty)

        feature.showSavedChangesDiff(snapshot(in: root), version: "one", file: file, session: session)
        #expect(session.selectedGitCommitFile == file && session.diffRows.contains { $0.rightText == "one" })
    }

    @Test
    func workspaceRefreshKeepsLinkedWorktreeDiffItDoesNotObserveUntilItsOwnReadConfirmsClean() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let other = makeTestWorktree(path: "/other", branch: "other")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [change])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) })),
            worktreesProvider: { _ in [worktree, other] },
            diffDocumentProvider: { _, _ in DiffDocument(patch: "linked diff", rows: [], hunks: []) })
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let session = feature.repositoryDiffSession(id: UUID())
        await feature.selectChange(change, session: session)
        #expect(session.selectedChange == change)

        // The workspace snapshot never lists a linked checkout, and the Worktrees
        // panel now shows another one, so neither source can vouch for this file.
        await feature.inspectWorktree(other)
        await feature.refreshGit()
        #expect(session.selectedChange == change)
        #expect(session.selectedDiffPatch == "linked diff")

        // A status read of the linked checkout itself is what proves it clean.
        await feature.inspectWorktree(worktree)
        _ = probe.mutate(change, action: "discard")
        await feature.refreshWorktreeChanges(worktree)
        #expect(session.selectedChange == nil && session.selectedDiffPatch.isEmpty)
    }

    @Test
    func unchangedWorkingDiffRefreshLeavesTheSessionUntouchedAndChangedRowsStillPublish() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "file.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let source = MutableDiffDocumentSource(text: "before")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]))),
            diffDocumentProvider: { _, _ in source.document() })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.selectChange(change)
        let session = feature.activeRepositoryDiffSession
        var publications = 0
        let observation = session.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        await feature.refreshGit()
        #expect(publications == 0, "Equal content must not redraw the diff or reset its scroll position")
        #expect(session.diffRows.first?.rightText == "before")

        source.set(text: "after")
        await feature.refreshGit()
        #expect(publications > 0)
        #expect(session.selectedDiffPatch == "after" && session.diffRows.first?.rightText == "after")
    }

    @Test
    func directoryDiffRefreshKeepsRowsVisibleAndOnlyPublishesRealChanges() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["one.txt", "two.txt"].map {
            GitChange(repositoryRoot: root, path: "dir/\($0)", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let source = MutableDiffDocumentSource(text: "before", includesPatch: false)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: changes),
            comparisonRowsRead: { source.document() })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let session = feature.repositoryDiffSession(id: UUID())
        await feature.showDirectoryDiff(at: root.appendingPathComponent("dir"), session: session)
        #expect(session.diffRows.map(\.rightText) == ["before", "before"] && !session.isLoadingDiff)
        var publications = 0
        let observation = session.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        await feature.refreshGit()
        #expect(publications == 0, "A refresh must not blank the rows or flash the loading state")
        #expect(session.diffRows.map(\.rightText) == ["before", "before"])

        source.set(text: "after")
        await feature.refreshGit()
        #expect(session.diffRows.map(\.rightText) == ["after", "after"] && !session.isLoadingDiff)
        #expect(session.directoryURL != nil)
    }

    @Test(arguments: [false, true])
    func closedWorkingDiffCannotOverwriteSameFileReopenedDuringRead(refresh: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "file.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let probe = RepositoryDiffDocumentProbe(blockedCall: refresh ? 2 : 1)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]))),
            diffDocumentProvider: { _, _ in await probe.read() })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        if refresh { await feature.selectChange(change) }
        let pending = Task { @MainActor in
            if refresh { await feature.refreshGit() } else { await feature.selectChange(change) }
        }
        defer { probe.release.open(); pending.cancel(); feature.reset() }
        try #require(await probe.started.waitUntilOpen(), "Diff read did not reach its gate")
        feature.closeRepositoryDiff()
        await feature.selectChange(change)
        #expect(feature.selectedDiffPatch == "fresh")
        probe.release.open()
        try #require(await waitForGitTaskCompletion(pending))
        #expect(feature.selectedChange == change && feature.selectedDiffPatch == "fresh")
        #expect(feature.diffRows.first?.rightText == "fresh" && !feature.isLoadingDiff)
        // Closing an unrelated comparison must not cancel this variant's loading owner.
        feature.closeBranchComparison()
        #expect(feature.selectedDiffPatch == "fresh")
    }

    @Test(arguments: 0..<8)
    func closedBranchDiffRejectsLateComparisonAndRows(scenario: Int) async throws {
        let typed = scenario & 1 != 0, blockRows = scenario & 2 != 0, reset = scenario & 4 != 0
        let root = URL(fileURLWithPath: "/workspace")
        let source = GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
            isCurrent: true, upstreamShortName: nil)
        let target = GitReference(fullName: "refs/heads/topic", shortName: "topic", kind: .local,
            isCurrent: false, upstreamShortName: nil)
        let comparison = GitBranchComparison(reference: source, files: [GitBranchComparisonFile(status: "M", path: "file.txt")])
        let started = GitModuleTestGate(), release = GitModuleTestGate()
        let operations = TestGitOperations(snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            comparisonRead: {
                if !blockRows { started.open(); _ = release.waitSynchronously() }
                return comparison
            }, comparisonRowsRead: {
                if blockRows { started.open(); _ = release.waitSynchronously() }
                return DiffDocument(rows: [DiffRow(oldLine: 1, newLine: 1, left: "old", right: "stale", kind: .changed)], hunks: [])
            })
        let feature = GitFeatureModel(service: GitService(operations: operations))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        let pending = Task { @MainActor in
            if typed { await feature.showComparison(from: source, to: target) }
            else { await feature.showComparisonWithWorkingTree(for: source) }
        }
        defer { release.open(); pending.cancel(); feature.reset() }
        try #require(await started.waitUntilOpen(), "Branch Diff read did not reach its gate")
        if reset { feature.reset() } else { feature.closeRepositoryDiff() }
        release.open()
        try #require(await waitForGitTaskCompletion(pending))
        #expect(feature.branchComparison == nil && feature.branchComparisonRows.isEmpty)
        #expect(feature.selectedBranchComparisonFile == nil && !feature.isLoadingBranchComparison)
        #expect(!feature.hasActiveModuleWork)
    }

    @Test
    func worktreeRegistryRefreshUpdatesLinkedStatusWithoutReopeningHistory() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [])
        let commits = (0..<80).map { makeTestCommit(hash: "worktree-\($0)", subject: "Commit \($0)") }
        let pages = WorktreeHistoryPageProbe(pages: [GitHistoryPage(commits: commits, nextCursor: "older", hasMore: true)])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) },
            historyValue: GitHistorySnapshot(references: [], commits: Array(commits.prefix(30)), hasMore: true),
            worktreeHistoryProbe: pages)), worktreesProvider: { _ in [worktree] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset(); pages.releaseAll() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        await feature.inspectWorktree(worktree)
        await feature.loadMoreWorktreeHistory(for: worktree)
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)

        // Editing a file does not change the registry record or HEAD task identity.
        probe.replaceChanges([change])
        await feature.refreshWorktrees()
        #expect(feature.gitWorktreeInspection?.changes == [change])
        #expect(feature.gitWorktreeInspection?.commits == commits)
        #expect(feature.gitWorktreeInspection?.hasMoreCommits == true)
        #expect(pages.requests.count == 1 && pages.closed.isEmpty)
        let version = feature.gitWorktreeInspectionVersion
        await feature.refreshWorktrees()
        #expect(feature.gitWorktreeInspectionVersion == version, "Unchanged status must retain presentation identity")

        probe.failSnapshots()
        await feature.refreshWorktrees()
        #expect(feature.gitWorktreeInspection?.changes == [change], "An unreadable index must not masquerade as clean")
        #expect(feature.worktreeChangesError != nil)
        #expect(feature.gitWorktreeInspection?.commits == commits)
    }

    @Test
    func workspaceRefreshUpdatesCurrentWorktreeStatusWithoutReopeningHistory() async {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = GitWorktree(path: root.path, head: "head", branch: "refs/heads/main", isCurrent: true,
            isPrimary: true, isBare: false, isDetached: false, isLocked: false, lockReason: nil,
            isPrunable: false, pruneReason: nil)
        let change = GitChange(repositoryRoot: root, path: "file.txt", originalPath: nil,
            indexStatus: " ", workTreeStatus: "M")
        let snapshots = UntrackedDirectorySnapshots(GitSnapshot(repositoryRoot: root, branch: "main", changes: []))
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()),
            snapshotProvider: { _ in await snapshots.current() },
            worktreesProvider: { _ in [worktree] }, repositoryRootsProvider: { _ in [root] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.inspectWorktree(worktree)
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)
        await snapshots.replace(with: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]))
        await feature.refreshGit()
        #expect(feature.gitWorktreeInspection?.changes == [change])
        let version = feature.gitWorktreeInspectionVersion
        await feature.refreshGit()
        #expect(feature.gitWorktreeInspectionVersion == version)
        await snapshots.replace(with: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))
        await feature.refreshGit()
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)
        #expect(feature.gitWorktreeInspection?.hasLoadedChanges == true)
    }

    @Test
    func worktreeCommitFeatureKeepsChangeListsAndCommitScopeInsideSelectedCheckout() async throws {
        let primary = makeTestWorktree(path: "/workspace", branch: "main")
        let linked = makeTestWorktree(path: "/workspace/.worktrees/linked", branch: "feature/linked")
        let nested = linked.url.appendingPathComponent("nested")
        let change = GitChange(repositoryRoot: linked.url, path: "config.txt", originalPath: nil,
            indexStatus: "M", workTreeStatus: " ")
        let primaryChange = GitChange(repositoryRoot: primary.url, path: "main.txt", originalPath: nil,
            indexStatus: "M", workTreeStatus: " ")
        let probe = WorkspaceCommitProbe()
        let storage = ChangelistStorageProbe()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotsByRoot: [primary.path: GitSnapshot(repositoryRoot: primary.url, branch: "main", changes: [primaryChange]),
                linked.path: GitSnapshot(repositoryRoot: linked.url, branch: "feature/linked", changes: [change])],
            repositoryRoots: [primary.url, linked.url, nested], workspaceCommitProbe: probe)),
            changelistStorage: storage, worktreesProvider: { _ in [primary, linked] })
        feature.configure(workspaceURLProvider: { primary.url }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        await feature.inspectWorktree(linked)
        let scoped = feature.commitFeature(for: linked)
        #expect(feature.commitFeature(for: linked) === scoped)
        #expect(scoped.gitRepositoryRoot == linked.url && scoped.availableRepositoryRoots == [linked.url])
        #expect(scoped.gitChanges == [change] && feature.gitRepositoryRoot == primary.url)
        #expect(scoped.saveChangelistName("Local config") == nil)
        let list = try #require(scoped.changelists.lists.last?.id)
        scoped.moveChanges([change, primaryChange], toChangelist: list)
        #expect(scoped.changelists.listID(for: change) == list)
        #expect(scoped.changelists.listID(for: primaryChange) == GitLocalChangelists.defaultID)
        #expect(scoped.changelistCommitError != nil)
        #expect(await !scoped.commitStagedChanges(message: "wrong list", amend: false))
        #expect(probe.requests.isEmpty)
        scoped.activateChangelist(list)
        #expect(await !scoped.commitAndPushStagedChanges(message: "linked only", amend: true))
        let request = try #require(probe.requests.first)
        #expect(request.repositories == [GitWorkspaceRepositoryBinding(id: ".", root: linked.path)])
        #expect(request.message == "linked only" && request.amend && request.push)
        #expect(request.pathScope?.include == true && request.pathScope?.paths["."] == [change.path])
        #expect(storage.states[linked.url]?.activeID == list)
        #expect(feature.changelists.lists.count == 1)
        await scoped.refreshGit()
        #expect(scoped.availableRepositoryRoots == [linked.url] && scoped.gitChanges == [change])
        #expect(feature.gitRepositoryRoot == primary.url)
    }

    @Test
    func worktreeCommitFeatureSharesMainCheckoutMetadataAndResetInvalidatesSessions() async throws {
        let worktree = makeTestWorktree(path: "/workspace", branch: "main")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: worktree.url, branch: "main", changes: []), repositoryRoots: [worktree.url])),
            changelistStorage: ChangelistStorageProbe(), worktreesProvider: { _ in [worktree] })
        feature.configure(workspaceURLProvider: { worktree.url }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        let scoped = feature.commitFeature(for: worktree)
        #expect(scoped.saveChangelistName("Shared") == nil)
        #expect(feature.changelists == scoped.changelists)
        #expect(feature.saveChangelistName("From sidebar") == nil)
        #expect(scoped.changelists == feature.changelists)
        scoped.changelistStorageFailed = true
        #expect(feature.changelistStorageFailed && feature.changelistEditingDisabled)
        feature.changelistStorageFailed = false
        #expect(!scoped.changelistStorageFailed)
        scoped.isCommitting = true
        #expect(feature.changelistEditingDisabled)
        #expect(feature.beginSetStaging(feature.gitChanges, staged: true).isEmpty)
        scoped.isCommitting = false
        let sharedLists = feature.changelists
        feature.reset()
        #expect(scoped.gitRepositoryRoot == nil && scoped.gitChanges.isEmpty)
        #expect(scoped.changelists == GitLocalChangelists() && sharedLists.lists.count == 3)
        await scoped.refreshGit()
        #expect(scoped.gitRepositoryRoot == nil, "An editor retained across workspace switches cannot reopen the old checkout")
        #expect(feature.commitFeature(for: worktree) !== scoped)
    }

    @Test
    func worktreeCommitPreparationBlocksDirectDiffIndexMutations() async throws {
        let worktree = makeTestWorktree(path: "/workspace/A", branch: "main")
        let change = GitChange(repositoryRoot: worktree.url, path: "tracked.txt", originalPath: nil,
            indexStatus: "M", workTreeStatus: "M")
        let hunk = DiffHunk(id: "h1", header: "@@ -1 +1 @@", patch: "confirmed patch")
        let state = try #require(workspacePreparation().session.states["A/B"])
        let plan = GitWorkspaceCommitPlan(repositories: [GitWorkspaceRepositoryBinding(id: ".", root: worktree.path)],
            message: "commit", amend: false, push: false, includeParentReferences: true, isRetry: false,
            orderedIds: ["."], propagatedRelations: [], dependencyRelations: [], states: [".": state],
            committedIds: [], pendingPushIds: [])
        let session = GitWorkspaceCommitSession(plan: plan, states: [".": state], results: [:], blocked: [],
            cursor: 0, commandFailed: false, finished: false, succeeded: false, canRetry: true)
        let preparation = GitWorkspaceCommitPreparation(session: session, reviewChanged: false, requiresConfirmation: false)
        var completed = session
        completed.finished = true; completed.succeeded = true; completed.canRetry = false; completed.cursor = 1
        completed.results = [".": GitWorkspaceRepositoryResult(committed: true, pushed: false, status: "committed", detail: "")]
        let prepared = GitModuleTestGate(), releasePreparation = GitModuleTestGate()
        let probe = WorkspaceCommitProbe(preparations: [preparation], steps: [completed],
            prepareStarted: prepared, prepareRelease: releasePreparation)
        let mutations = WorktreeChangesProbe(root: worktree.url, changes: [change])
        let patches = PushMessageRecorder()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: worktree.url, branch: "main", changes: [change]),
            repositoryRoots: [worktree.url], applyPatchHandler: { _, _, mode in
                patches.record(mode)
                return GitProcessResult(output: "", exitCode: 0)
            }, stageHandler: { mutations.mutate($0, action: "stage") },
            unstageHandler: { mutations.mutate($0, action: "unstage") }, workspaceCommitProbe: probe)),
            worktreesProvider: { _ in [worktree] })
        feature.configure(workspaceURLProvider: { worktree.url }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.refreshWorktrees()
        let scoped = feature.commitFeature(for: worktree)
        var succeeded = false
        let commit = Task { succeeded = await scoped.commitStagedChanges(message: "commit", amend: false) }
        defer { releasePreparation.open(); commit.cancel(); feature.reset() }
        try #require(await prepared.waitUntilOpen(), "Scoped commit did not reach its prepared-plan gate")
        #expect(scoped.isCommitting && !feature.isCommitting && feature.isWorktreeCommitBlocked)
        #expect(probe.requests.first?.repositories == [GitWorkspaceRepositoryBinding(id: ".", root: worktree.path)])
        await feature.stageChange(change)
        await feature.unstageChange(change)
        await feature.stageDiffHunk(hunk, in: change)
        await feature.unstageDiffHunk(hunk, in: change)
        #expect(mutations.calls.isEmpty)
        #expect(patches.values.isEmpty)
        releasePreparation.open()
        try #require(await waitForGitTaskCompletion(commit))
        #expect(succeeded && probe.stepCount == 1 && !feature.isWorktreeCommitBlocked)
        await feature.stageChange(change)
        await feature.unstageChange(change)
        await feature.stageDiffHunk(hunk, in: change)
        await feature.unstageDiffHunk(hunk, in: change)
        #expect(mutations.calls.map(\.action) == ["stage", "unstage"])
        #expect(patches.values == ["stage", "unstage"])
    }

    @Test
    func worktreeChangesStageUnstageDiscardUseSelectedCheckoutAndPreserveHistory() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "feature/linked")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil, indexStatus: "M", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [change])
        let commits = (0..<80).map { makeTestCommit(hash: "worktree-\($0)", subject: "Commit \($0)") }
        let pages = WorktreeHistoryPageProbe(pages: [GitHistoryPage(commits: commits, nextCursor: "older", hasMore: true)])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) },
            historyValue: GitHistorySnapshot(references: [], commits: Array(commits.prefix(30)), hasMore: true),
            worktreeHistoryProbe: pages, discardHandler: { probe.mutate($0, action: "discard") },
            stageHandler: { probe.mutate($0, action: "stage") }, unstageHandler: { probe.mutate($0, action: "unstage") })),
            worktreesProvider: { _ in [worktree] }, diffDocumentProvider: { _, _ in DiffDocument(patch: "linked diff", rows: [], hunks: []) })
        defer { feature.reset(); pages.releaseAll() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.refreshWorktrees()
        await feature.inspectWorktree(worktree)
        await feature.loadMoreWorktreeHistory(for: worktree)
        await feature.selectChange(change)
        // Add includes the remaining edits in a partially staged file.
        await feature.setWorktreeStaging([change], staged: true, in: worktree)
        let staged = try #require(feature.gitWorktreeInspection?.changes.first)
        #expect(staged.isStaged && !staged.hasWorkingTreeChange)
        #expect(feature.selectedChange == staged)
        #expect(feature.selectedDiffPatch == "linked diff")
        await feature.setWorktreeStaging([staged], staged: false, in: worktree)
        let unstaged = try #require(feature.gitWorktreeInspection?.changes.first)
        #expect(!unstaged.isStaged && unstaged.hasWorkingTreeChange)
        await feature.discardWorktreeChanges([unstaged], in: worktree)
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)
        #expect(feature.selectedChange == nil)
        #expect(feature.gitRepositoryRoot == root)
        #expect(feature.gitWorktreeInspection?.commits == commits)
        #expect(feature.gitWorktreeInspection?.hasMoreCommits == true)
        #expect(pages.closed.isEmpty && pages.requests.count == 1)
        #expect(probe.calls.map(\.action) == ["stage", "unstage", "discard"])
        #expect(probe.calls.allSatisfy { $0.change.repositoryRoot == worktree.url })
        #expect(!feature.isMutatingWorktreeChanges && !feature.isRefreshingWorktreeChanges)
    }

    @Test
    func worktreeChangesRejectForeignStaleAndProtectedTargets() async {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let foreign = GitChange(repositoryRoot: root, path: "same.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let current = GitChange(repositoryRoot: worktree.url, path: "same.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let stale = GitChange(repositoryRoot: worktree.url, path: "same.txt", originalPath: nil, indexStatus: "M", workTreeStatus: "M")
        let protected = GitChange(repositoryRoot: worktree.url, path: "module", originalPath: nil, indexStatus: " ", workTreeStatus: "M", canToggleStaging: false)
        let probe = WorktreeChangesProbe(root: root, changes: [current, protected])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            discardHandler: { probe.mutate($0, action: "discard") }, stageHandler: { probe.mutate($0, action: "stage") })),
            worktreesProvider: { _ in [worktree] })
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        await feature.setWorktreeStaging([foreign, stale, protected], staged: true, in: worktree)
        await feature.discardWorktreeChanges([foreign, stale], in: worktree)
        #expect(probe.calls.isEmpty)
        await feature.setWorktreeStaging([current], staged: true, in: worktree)
        await feature.discardWorktreeChanges([current], in: worktree)
        #expect(probe.calls.map(\.action) == ["stage"])
        #expect(feature.gitWorktreeInspection?.changes.contains(protected) == true)
    }

    @Test
    func worktreeChangesFailureStopsBatchAndRefreshFailureRetainsRows() async {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let changes = ["first.txt", "second.txt"].map {
            GitChange(repositoryRoot: worktree.url, path: $0, originalPath: nil, indexStatus: "?", workTreeStatus: "?")
        }
        let probe = WorktreeChangesProbe(root: root, changes: changes)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            discardHandler: { probe.mutate($0, action: "discard", succeeds: false) })),
            worktreesProvider: { _ in [worktree] })
        defer { feature.reset() }
        var messages: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { messages.append($0) }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        await feature.discardWorktreeChanges(changes, in: worktree)
        #expect(probe.calls.map(\.change.path) == ["first.txt"])
        #expect(feature.worktreeChangesError == "operation failed")
        #expect(messages.contains("operation failed"))
        #expect(feature.gitWorktreeInspection?.changes == changes)
        probe.failSnapshots()
        await feature.refreshWorktreeChanges(worktree)
        #expect(feature.gitWorktreeInspection?.changes == changes)
        #expect(feature.worktreeChangesError != nil)
        #expect(!feature.isRefreshingWorktreeChanges)
    }

    @Test
    func worktreeChangesDeduplicateInFlightMutationAndCannotOverwriteNewSelection() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let other = makeTestWorktree(path: "/other", branch: "other")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [change])
        let started = GitModuleTestGate(), release = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            stageHandler: { change in
                started.open()
                guard release.waitSynchronously() else { return nil }
                return probe.mutate(change, action: "stage")
            })), worktreesProvider: { _ in [worktree, other] })
        defer { release.open(); feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let task = Task { await feature.setWorktreeStaging([change], staged: true, in: worktree) }
        defer { task.cancel(); release.open() }
        try #require(await started.waitUntilOpen())
        #expect(feature.isMutatingWorktreeChanges)
        await feature.setWorktreeStaging([change], staged: true, in: worktree)
        await feature.inspectWorktree(other)
        release.open()
        try #require(await waitForGitTaskCompletion(task))
        #expect(probe.calls.count == 1)
        #expect(feature.gitWorktreeInspection?.worktreeID == other.id)
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)
        #expect(!feature.isMutatingWorktreeChanges)
    }

    @Test(arguments: [true, false])
    func worktreeStagingShowsTheRequestedStateAtOnceAndSettlesToWhatGitDid(succeeds: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [change])
        let started = GitModuleTestGate(), release = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            stageHandler: { change in
                started.open()
                guard release.waitSynchronously() else { return nil }
                return probe.mutate(change, action: "stage", succeeds: succeeds)
            })), worktreesProvider: { _ in [worktree] })
        defer { release.open(); feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let task = Task { await feature.setWorktreeStaging([change], staged: true, in: worktree) }
        defer { task.cancel(); release.open() }
        try #require(await started.waitUntilOpen())
        // Git has not answered yet: the row already reads as staged, though the status has not changed.
        #expect(feature.pendingStagedStates == [change.id: true])
        #expect(feature.effectiveStagingState(for: change))
        #expect(feature.gitWorktreeInspection?.changes.first?.isStaged == false)
        release.open()
        try #require(await waitForGitTaskCompletion(task))
        #expect(feature.pendingStagedStates.isEmpty && !feature.isStagingChanges)
        #expect(feature.gitWorktreeInspection?.changes.first?.isStaged == succeeds)
    }

    @Test
    func worktreeChangesAreIdleOnceTheirStatusIsReadWithoutWaitingForTheProjectRefresh() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let change = GitChange(repositoryRoot: worktree.url, path: "file.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: root, changes: [change])
        let projectRefreshEntered = GitModuleTestGate(), releaseProjectRefresh = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) },
            stageHandler: { probe.mutate($0, action: "stage") })), worktreesProvider: { _ in [worktree] })
        defer { releaseProjectRefresh.open(); feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {},
            onGitOperationEnded: {
                projectRefreshEntered.open()
                _ = await releaseProjectRefresh.waitUntilOpen()
            })
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let projectReads = probe.snapshotRoots.filter { $0 == root }.count
        let task = Task { await feature.setWorktreeStaging([change], staged: true, in: worktree) }
        defer { task.cancel(); releaseProjectRefresh.open() }
        try #require(await projectRefreshEntered.waitUntilOpen())
        // The worktree's own status is already confirmed, so its rows accept the next click.
        #expect(feature.gitWorktreeInspection?.changes.first?.isStaged == true)
        #expect(!feature.isMutatingWorktreeChanges && !feature.isRefreshingWorktreeChanges)
        #expect(feature.pendingStagedStates.isEmpty && !feature.isStagingChanges)
        #expect(probe.snapshotRoots.filter { $0 == root }.count == projectReads)
        releaseProjectRefresh.open()
        try #require(await waitForGitTaskCompletion(task))
    }

    @Test(arguments: [false, true])
    func worktreeChangesCancellationOrResetStopsBatchAndRejectsLateFailure(reset: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let changes = ["first.txt", "second.txt"].map {
            GitChange(repositoryRoot: worktree.url, path: $0, originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let probe = WorktreeChangesProbe(root: root, changes: changes)
        let started = GitModuleTestGate(), release = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            stageHandler: { change in
                started.open()
                guard release.waitSynchronously() else { return nil }
                return probe.mutate(change, action: "stage", succeeds: false)
            })), worktreesProvider: { _ in [worktree] })
        var messages: [String] = []
        func configure() {
            feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                              notify: { messages.append($0) }, onStateRefreshed: {})
        }
        defer { release.open(); feature.reset() }
        configure()
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let task = Task { await feature.setWorktreeStaging(changes, staged: true, in: worktree) }
        defer { task.cancel(); release.open() }
        try #require(await started.waitUntilOpen())
        if reset {
            feature.reset()
            configure()
            await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        } else {
            task.cancel()
        }
        release.open()
        try #require(await waitForGitTaskCompletion(task))
        #expect(probe.calls.map(\.change.path) == ["first.txt"])
        #expect(feature.gitWorktreeInspection?.changes == changes)
        #expect(feature.worktreeChangesError == nil && messages.isEmpty)
        #expect(!feature.isMutatingWorktreeChanges && !feature.isRefreshingWorktreeChanges)
    }

    @Test
    func gitLogFileSelectionReplacesSavedDiffEvenForTheSamePath() async {
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        let commit = GitCommit(hash: "history", shortHash: "history", parentHashes: [],
            authorName: "", authorEmail: "", date: "", subject: "History", decorations: "")
        feature.previewGitCommitSelection(commit)
        let file = GitCommitFile(status: "M", path: "file.txt")
        let saved = GitSavedChangesSnapshot(id: "stash", repositoryRoot: root, files: [
            GitSavedPatchFile(file: file, version: "Stash", base: "base",
                patch: "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+saved\n")
        ])
        feature.showSavedChangesDiff(saved, version: "Stash", file: file)
        #expect(feature.selectedGitCommitDiffContext?.commit.hash == "saved:stash:Stash")
        await feature.showGitCommitDiff(for: file)
        #expect(feature.selectedGitCommitDiffContext?.commit.hash == commit.hash)
        #expect(feature.diffRows.isEmpty)
        #expect(!feature.isLoadingDiff)
        feature.showSavedChangesDiff(saved, version: "Stash", file: file)
        #expect(feature.diffRows.contains { $0.rightText == "saved" })
    }

    @Test
    func sharedConsoleCancelsExternalOperationsEvenAfterClearingButResetPreservesTheirOwner() async {
        let root = URL(fileURLWithPath: "/workspace")
        let journal = GitExecutionJournal()
        let probe = GitGraphHistoryProbe()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe)),
            executionJournal: journal)
        defer {
            for operationID in ["github-push", "github-fetch"] {
                journal.receive(GitExecutionEvent(operationId: operationID, type: "requestFinished"))
            }
            feature.reset()
        }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        for (operationID, command) in [("github-push", "push"), ("github-fetch", "fetch")] {
            journal.receive(GitExecutionEvent(operationId: operationID, type: "started", invocationId: 1,
                workingDirectory: root.path, arguments: [command, "origin"]))
        }
        await feature.refreshGit()
        #expect(feature.gitConsoleEntries.count == 2)
        #expect(feature.isGitExecutionRunning)
        feature.reset()
        #expect(probe.cancelledOperationIDs.isEmpty)
        #expect(journal.runningOperationIDs.count == 2)
        await feature.refreshGit()
        feature.clearGitConsole()
        #expect(feature.gitConsoleEntries.isEmpty)
        #expect(feature.isGitExecutionRunning)
        feature.cancelGitExecutions()
        #expect(probe.cancelledOperationIDs.sorted() == ["github-fetch", "github-push"])
        for operationID in ["github-push", "github-fetch"] {
            journal.receive(GitExecutionEvent(operationId: operationID, type: "requestFinished"))
        }
        await feature.loadGitConsoleIfNeeded()
        #expect(!feature.isGitExecutionRunning)
        #expect(feature.gitConsoleEntries.isEmpty)
    }

    @Test
    func projectConsoleIncludesWorktreeCommandsOutsideTheSelectedRepository() async {
        let root = URL(fileURLWithPath: "/workspace")
        let journal = GitExecutionJournal()
        for (index, directory) in ["/workspace", "/linked-checkout"].enumerated() {
            journal.receive(GitExecutionEvent(operationId: "worktree-\(index)", type: "started", invocationId: 1,
                workingDirectory: directory, arguments: ["worktree", "repair"]))
            journal.receive(GitExecutionEvent(operationId: "worktree-\(index)", type: "finished", invocationId: 1, exitCode: 0))
            journal.receive(GitExecutionEvent(operationId: "worktree-\(index)", type: "requestFinished"))
        }
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))), executionJournal: journal)
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.loadGitConsoleIfNeeded()
        #expect(feature.gitConsoleEntries.map(\.workingDirectory.path) == ["/workspace", "/linked-checkout"])
        #expect(Set(feature.gitConsoleEntries.map(\.id)).count == 2)
        feature.clearGitConsole()
        #expect(journal.snapshot.isEmpty)
        #expect(feature.gitConsoleEntries.isEmpty)
    }

    @Test
    func consoleIncludesCommandsFromOtherFeaturesBeforeItWasOpened() async {
        let root = URL(fileURLWithPath: "/workspace")
        let journal = GitExecutionJournal()
        journal.receive(GitExecutionEvent(operationId: "github", type: "started", invocationId: 1,
            workingDirectory: root.path, arguments: ["push", "origin", "feature"]))
        journal.receive(GitExecutionEvent(operationId: "github", type: "finished", invocationId: 1, exitCode: 0))
        journal.receive(GitExecutionEvent(operationId: "github", type: "requestFinished"))
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []))),
            executionJournal: journal)
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["push", "origin", "feature"]])
        await feature.loadGitConsoleIfNeeded()
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["push", "origin", "feature"]])
        feature.clearGitConsole()
        await feature.loadGitConsoleIfNeeded()
        #expect(feature.gitConsoleEntries.isEmpty)
        #expect(journal.snapshot.isEmpty)
    }

    @Test
    func fetchProgressOnStderrRemainsReadableAndDoesNotImplyFailure() {
        let progress = "Receiving objects: 10%\rReceiving objects: 100%\r\n"
        let entry = GitConsoleEntry(workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["fetch", "--progress"], output: progress,
            standardError: progress, exitCode: 0, operationTitle: "Fetch")
        #expect(entry.succeeded)
        #expect(entry.outputLines.map(\.text) == ["Receiving objects: 10%", "Receiving objects: 100%"])
        #expect(entry.outputLines.allSatisfy { $0.stream == .standardError })
    }

    @Test(arguments: [Int32(0), Int32(128)])
    func fetchRecordsPlanBeforeExecutionAndKeepsTheActualExitStatus(exitCode: Int32) async {
        let root = URL(fileURLWithPath: "/workspace")
        let options = GitFetchOptions(remote: "team/origin", prune: false, submodules: .no)
        let planned = ["fetch", "--progress", "--no-prune", "--", "team/origin"]
        let actual = ["--no-pager"] + planned
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: options, arguments: planned),
            fetchHandler: { receivedOptions, operationID in
                #expect(receivedOptions == options)
                #expect(UUID(uuidString: operationID) != nil)
                return GitProcessResult(arguments: actual, output: "remote output", exitCode: exitCode,
                    invocations: [GitProcessInvocation(arguments: actual, standardOutput: "",
                        standardError: "remote output", exitCode: exitCode)])
            }
        )))
        defer { feature.reset() }
        var observedStart = false
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {}, onGitOperationBegan: {
                observedStart = true
                #expect(feature.gitConsoleEntries.last?.state == .planned)
                #expect(feature.gitConsoleEntries.last?.arguments == planned)
                #expect(feature.gitConsoleEntries.last?.succeeded == false)
            })
        await feature.refreshGit()
        await feature.fetchGit(options: options)
        #expect(observedStart)
        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.last?.arguments == actual)
        #expect(feature.gitConsoleEntries.last?.exitCode == exitCode)
        #expect(feature.gitConsoleEntries.last?.standardError == "remote output")
        #expect(feature.gitConsoleEntries.last?.succeeded == (exitCode == 0))
        #expect(feature.gitConsoleEntries.last?.state == .completed)
        #expect(feature.gitConsoleEntries.last?.durationMilliseconds != nil)
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test(arguments: [false, true])
    func fetchDoesNotRestoreClearedOrPreviousRepositoryConsole(resetRepository: Bool) async {
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: GitFetchOptions(), arguments: ["fetch", "--all"]),
            fetchHandler: { _, _ in GitProcessResult(output: "fetch failed", exitCode: 1) }
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {}, onGitOperationBegan: {
                // The lifecycle callback gives the test an exact boundary before
                // execution; neither sleeps nor a blocking process double is needed.
                if resetRepository { feature.reset() } else { feature.clearGitConsole() }
            })
        await feature.refreshGit()
        await feature.fetchGit()
        #expect(feature.gitConsoleEntries.isEmpty)
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test
    func fetchWithoutAnInvocationKeepsItsCommandExplicitlyUnconfirmed() async {
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            fetchPlan: GitFetchPlan(options: GitFetchOptions(), arguments: ["fetch", "--all"]),
            fetchHandler: { _, _ in GitProcessResult(output: "Could not start Git", exitCode: 1) }
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.fetchGit()
        #expect(feature.gitConsoleEntries.last?.state == .unconfirmed)
        #expect(feature.gitConsoleEntries.last?.succeeded == false)
        #expect(feature.gitConsoleEntries.last?.copyText.contains("No completed Git invocation") == true)
    }
    @Test
    func patchDiscoveryKeepsFilesSelectableAfterAnEncodingFailure() async throws {
        let good = GitPatchFile(path: "good.txt", originalPath: nil, additions: 1, deletions: 0)
        let legacy = GitPatchFile(path: "legacy.txt", originalPath: nil, additions: 1, deletions: 0)
        let service = GitService(operations: TestGitOperations(exportPatchHandler: { paths, metadataOnly in
            if metadataOnly { return .success(GitPatchExport(patch: "", files: [good, legacy], byteLength: 0)) }
            if paths.contains("legacy.txt") { return .failure(GitPatchFailure("Non-UTF-8 patch")) }
            return .success(GitPatchExport(patch: "selected UTF-8 patch", files: [good], byteLength: 20))
        }))
        let feature = GitPatchFeatureModel(service: service) { _, _, _, _ in nil }
        defer { feature.reset() }
        feature.beginExport(at: URL(fileURLWithPath: "/workspace"))
        // Observe the public busy boundary with the existing bounded helper;
        // reset owns task cancellation even when an assertion fails.
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.files == [good, legacy])
        #expect(feature.exportPreview == nil)
        #expect(feature.canGenerateExport)
        feature.generateExport()
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.errorMessage == "Non-UTF-8 patch")
        #expect(feature.files == [good, legacy])
        feature.selectPath("legacy.txt", included: false)
        feature.generateExport()
        try #require(await waitForGitWorkToBecomeIdle { feature.isBusy })
        #expect(feature.errorMessage == nil)
        #expect(feature.exportPreview?.files == [good])
        #expect(feature.canSave)
    }

    @Test
    func treeStatusUsesExactNodeStatusWithoutInheritingDescendantColors() {
        let root = URL(fileURLWithPath: "/workspace")
        let projection = GitTreeStatusProjection(changes: [
            GitChange(
                repositoryRoot: root,
                path: "Sources/Modified.swift",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "M"
            ),
            GitChange(
                repositoryRoot: root,
                path: "Sources/Feature/Added.swift",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            ),
            GitChange(
                repositoryRoot: root,
                path: "Sources/Feature/Conflict.swift",
                originalPath: nil,
                indexStatus: "U",
                workTreeStatus: "U"
            )
        ])

        #expect(projection.kind(relativePath: "Sources/Modified.swift", isDirectory: false) == .modified)
        #expect(projection.kind(relativePath: "Sources/Feature/Conflict.swift", isDirectory: false) == .conflicted)
        #expect(projection.kind(relativePath: "Sources/Feature", isDirectory: true) == nil)
        #expect(projection.kind(relativePath: "Sources", isDirectory: true) == nil)
        #expect(projection.kind(relativePath: "Tests", isDirectory: true) == nil)
        #expect(projection.kind(relativePath: "", isDirectory: true) == nil)
    }

    @Test
    func treeStatusNormalizesSeparatorsWithoutMatchingSiblingPrefixes() {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "src/main/App.java",
            originalPath: nil,
            indexStatus: "A",
            workTreeStatus: " "
        )
        let projection = GitTreeStatusProjection(changes: [change])

        #expect(projection.change(relativePath: "\\src\\main\\App.java") == change)
        #expect(projection.kind(relativePath: "src/mai", isDirectory: true) == nil)
    }

    @Test
    func treeStatusTreatsFilesBelowAnUntrackedSummaryAsUntracked() {
        // Project rows, editor gutters and Show Diff found a per-file record for
        // these files before status summarized large untracked directories (#1385).
        let root = URL(fileURLWithPath: "/workspace")
        let summary = GitChange(repositoryRoot: root, path: "target/", originalPath: nil,
                                indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 5_273)
        let projection = GitTreeStatusProjection(changes: [summary])

        let file = projection.change(relativePath: "target/debug/app")
        #expect(file?.path == "target/debug/app")
        #expect(file?.isUntracked == true)
        #expect(file?.isUntrackedDirectory == false)
        #expect(projection.kind(relativePath: "target", isDirectory: true) == .added)
        #expect(projection.change(relativePath: "targets/app") == nil)
        let absolute = GitTreeStatusProjection(changes: [summary], absolutePaths: true)
        #expect(absolute.change(relativePath: "/workspace/target/a.o")?.path == "target/a.o")
        #expect(absolute.containingUntrackedDirectory(of: summary) == nil)
    }

    @Test
    func untrackedDirectorySummaryListsItsContentsOnDemandAndAcrossRefreshes() async {
        let root = URL(fileURLWithPath: "/workspace")
        func untracked(_ path: String, count: Int? = nil) -> GitChange {
            GitChange(repositoryRoot: root, path: path, originalPath: nil,
                      indexStatus: "?", workTreeStatus: "?", untrackedFileCount: count)
        }
        let source = GitChange(repositoryRoot: root, path: "src/App.swift", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let target = untracked("target/", count: 5_273)
        let debug = untracked("target/debug/", count: 5_272)
        let snapshots = UntrackedDirectorySnapshots(
            GitSnapshot(repositoryRoot: root, branch: "main", changes: [source, target])
        )
        let listing: [String: [GitChange]] = [
            "target/": [untracked("target/.rustc_info.json"), debug],
            "target/debug/": [untracked("target/debug/app")]
        ]
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations()),
            snapshotProvider: { _ in await snapshots.current() },
            stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil },
            repositoryRootsProvider: { _ in [] },
            diffDocumentProvider: { _, _ in DiffDocument(rows: [], hunks: []) },
            untrackedDirectoryChildrenProvider: { listing[$0.path] }
        )
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})

        await feature.refreshGit()
        #expect(feature.gitChanges.map(\.path) == ["src/App.swift", "target/"])
        #expect(feature.gitChangedFileCount == 5_274)

        // A summary stands for thousands of files and has no diff of its own.
        await feature.selectChange(target)
        #expect(feature.selectedChange == nil)

        let expanded = ["src/App.swift", "target/", "target/.rustc_info.json", "target/debug/", "target/debug/app"]
        await feature.toggleUntrackedDirectory(target)
        await feature.toggleUntrackedDirectory(debug)
        #expect(feature.gitChanges.map(\.path) == expanded)
        #expect(feature.gitChangedFileCount == 5_274)

        // A watcher refresh lists expanded summaries again instead of collapsing them.
        await feature.refreshGit()
        #expect(feature.gitChanges.map(\.path) == expanded)

        await feature.toggleUntrackedDirectory(target)
        #expect(feature.gitChanges.map(\.path) == ["src/App.swift", "target/"])
        #expect(feature.expandedUntrackedDirectoryIDs.isEmpty)

        // Staging or deleting the directory removes its summary and its expansion.
        await feature.toggleUntrackedDirectory(target)
        await snapshots.replace(with: GitSnapshot(repositoryRoot: root, branch: "main", changes: [source]))
        await feature.refreshGit()
        #expect(feature.gitChanges.map(\.path) == ["src/App.swift"])
        #expect(feature.expandedUntrackedDirectoryIDs.isEmpty)
    }

    @Test
    func lineChangeProjectionMapsAdditionsChangesAndMiddleDeletions() {
        let markers = GitLineChangeProjection.markers(from: [
            DiffRow(oldLine: 1, newLine: 1, left: "same", right: "same", kind: .context, hunkID: "h1"),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added", kind: .addition, hunkID: "h1"),
            DiffRow(oldLine: 2, newLine: 3, left: "old", right: "new", kind: .changed, hunkID: "h1"),
            DiffRow(oldLine: 3, newLine: nil, left: "removed", right: nil, kind: .removal, hunkID: "h2"),
            DiffRow(oldLine: 4, newLine: 4, left: "next", right: "next", kind: .context, hunkID: "h2")
        ])

        #expect(markers == [
            GitLineChangeMarker(line: 1, kind: .added, hunkID: "h1"),
            GitLineChangeMarker(line: 2, kind: .modified, hunkID: "h1"),
            GitLineChangeMarker(line: 3, kind: .deleted, hunkID: "h2")
        ])
    }

    @Test
    func lineChangeProjectionAnchorsEndDeletionAndUsesSameLinePriority() {
        let markers = GitLineChangeProjection.markers(from: [
            DiffRow(oldLine: 1, newLine: 1, left: "same", right: "same", kind: .context, hunkID: "context"),
            DiffRow(oldLine: nil, newLine: 2, left: nil, right: "added", kind: .addition, hunkID: "added"),
            DiffRow(oldLine: 2, newLine: 2, left: "old", right: "new", kind: .changed, hunkID: "modified"),
            DiffRow(oldLine: 3, newLine: nil, left: "removed", right: nil, kind: .removal, hunkID: "deleted")
        ])

        #expect(markers == [
            GitLineChangeMarker(line: 1, kind: .modified, hunkID: "modified")
        ])
    }

    @Test
    func gitLogQueryParsesStructuredFiltersAndQuotedValues() {
        let query = GitLogQuery.parse(
            #"fix login me author:"Ada Lovelace" branch:origin/main path:'Sources/Auth Flow'"#
        )

        #expect(query.textTerms == ["fix", "login"])
        #expect(query.currentUserOnly)
        #expect(query.authors == ["Ada Lovelace"])
        #expect(query.branches == ["origin/main"])
        #expect(query.paths == ["Sources/Auth Flow"])
    }

    @Test
    func gitLogQueryMatchesIdentityAuthorTextAndPaths() {
        let commit = GitCommit(
            hash: "0123456789abcdef",
            shortHash: "0123456",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026/08/16 00:00",
            subject: "Fix login redirect",
            decorations: "HEAD -> main"
        )
        let query = GitLogQuery.parse("me author:ada fix path:AuthController")

        #expect(query.matchesMetadata(
            commit,
            identity: GitIdentity(name: nil, email: "ada@example.com")
        ))
        #expect(query.matchesPaths(["src/main/java/demo/AuthController.java"]))
        #expect(!query.matchesPaths(["src/main/java/demo/HomeController.java"]))
        #expect(!query.matchesMetadata(
            commit,
            identity: GitIdentity(name: "Grace Hopper", email: "grace@example.com")
        ))
    }

    @Test
    func gitLogStructuredFiltersPreserveQuotedPathsAndMatchSelectedAuthorExactly() {
        let selectedAuthor = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "dev@example.com",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Update quoted path",
            decorations: ""
        )
        let similarAuthor = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "dev@example.com.invalid",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Update quoted path",
            decorations: ""
        )
        let path = #"Sources/It's a "quoted" file.swift"#
        let query = GitLogQuery.parse("Update").addingStructuredFilters(
            exactAuthor: GitIdentity(name: selectedAuthor.authorName, email: selectedAuthor.authorEmail),
            paths: [path]
        )

        #expect(query.paths == [path])
        #expect(query.matchesMetadata(selectedAuthor, identity: nil))
        #expect(!query.matchesMetadata(similarAuthor, identity: nil))
        #expect(query.matchesPaths([path]))
        #expect(!query.matchesPaths([#"Sources/Its a "quoted" file.swift"#]))
    }

    @Test
    func gitLogStructuredAuthorFallsBackToExactNameWhenEmailIsBlank() {
        let exactName = GitCommit(
            hash: "3333333333333333",
            shortHash: "3333333",
            parentHashes: [],
            authorName: "Alice",
            authorEmail: "",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Exact author",
            decorations: ""
        )
        let similarName = GitCommit(
            hash: "4444444444444444",
            shortHash: "4444444",
            parentHashes: [],
            authorName: "Alice Smith",
            authorEmail: "",
            date: "2026-08-27T09:30:00+08:00",
            subject: "Similar author",
            decorations: ""
        )
        let query = GitLogQuery(exactAuthor: GitIdentity(name: "Alice", email: nil))

        #expect(query.matchesMetadata(exactName, identity: nil))
        #expect(!query.matchesMetadata(similarName, identity: nil))
    }

    @Test
    func gitLogQueryMatchesInclusiveAfterAndExclusiveBeforeDates() {
        let insideRange = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-16T09:30:00+08:00",
            subject: "Inside range",
            decorations: ""
        )
        let atExclusiveEnd = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-18T00:00:00Z",
            subject: "Outside range",
            decorations: ""
        )
        let query = GitLogQuery.parse("after:2026-08-16 before:2026-08-18")

        #expect(!query.isEmpty)
        #expect(query.afterDate != nil)
        #expect(query.beforeDate != nil)
        #expect(query.matchesMetadata(insideRange, identity: nil))
        #expect(!query.matchesMetadata(atExclusiveEnd, identity: nil))
    }

    @Test
    func gitConsoleCommandFormatterQuotesArgumentsAndRedactsURLCredentials() {
        let commandLine = GitConsoleCommandFormatter.commandLine(arguments: [
            "push",
            "feature branch",
            "John's change\nnext line",
            "https://alice:secret@example.com/org/repository.git",
            ""
        ])

        #expect(commandLine.hasPrefix("git push 'feature branch'"))
        #expect(commandLine.contains(#"'John'\''s change\nnext line'"#))
        #expect(commandLine.contains("redacted"))
        #expect(!commandLine.contains("alice"))
        #expect(!commandLine.contains("secret"))
        #expect(commandLine.hasSuffix(" ''"))
    }

    @Test
    func gitConsoleMarksDestructiveCommands() {
        let root = URL(fileURLWithPath: "/workspace")
        let destructive = [
            ["branch", "-d", "--", "feature/old"],
            ["tag", "-d", "v1.0"],
            ["worktree", "remove", "/tmp/worktree"],
            ["stash", "drop", "stash@{0}"],
            ["apply", "--reverse", "-"]
        ]
        for arguments in destructive {
            #expect(GitConsoleEntry(
                workingDirectory: root,
                arguments: arguments,
                output: "",
                exitCode: 0
            ).isDestructive)
        }
        #expect(!GitConsoleEntry(
            workingDirectory: root,
            arguments: ["status", "--short"],
            output: "",
            exitCode: 0
        ).isDestructive)
    }

    @Test
    func gitConsoleRedactsCredentialsFromArgumentsAndProcessStreams() {
        let secret = "FAKE_SUPER_SECRET_TOKEN"
        let credentialURL = "https://alice:password@example.com/repository.git?access_token=\(secret)&mode=test"
        let tokenURL = "https://example.com/repository.git?token=\(secret)"
        let entry = GitConsoleEntry(
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["fetch", credentialURL],
            output: "warning: request failed for \(tokenURL)\nfatal: unable to access '\(credentialURL)'\n",
            standardOutput: "warning: request failed for \(tokenURL)\n",
            standardError: "fatal: unable to access '\(credentialURL)'\n",
            exitCode: 1
        )

        let visibleText = [
            entry.arguments.joined(separator: " "),
            entry.output,
            entry.standardOutput ?? "",
            entry.standardError ?? "",
            entry.commandLine,
            entry.copyText,
            entry.outputLines.map(\.text).joined(separator: "\n")
        ].joined(separator: "\n")
        #expect(visibleText.contains("redacted"))
        #expect(!visibleText.contains(secret))
        #expect(!visibleText.contains("alice"))
        #expect(!visibleText.contains("password"))
    }

    @Test
    func gitConsoleRecordsEveryInvocationFromCompositeOperations() async {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            stageResult: GitProcessResult(
                arguments: ["checkout", "HEAD", "--", "README.md"],
                output: "",
                exitCode: 0,
                invocations: [
                    GitProcessInvocation(
                        arguments: ["status", "--porcelain", "--", "README.md"],
                        standardOutput: " M README.md\n",
                        standardError: "",
                        exitCode: 0
                    ),
                    GitProcessInvocation(
                        arguments: ["checkout", "HEAD", "--", "README.md"],
                        standardOutput: "",
                        standardError: "",
                        exitCode: 0
                    )
                ]
            )
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectChange(change)
        await feature.stageSelectedChange()

        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["status", "--porcelain", "--", "README.md"],
            ["checkout", "HEAD", "--", "README.md"]
        ])
    }

    @Test
    func gitRefreshCombinesChangesFromDiscoveredWorkspaceRepositories() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let firstRoot = workspace.appendingPathComponent("service-a", isDirectory: true)
        let secondRoot = workspace.appendingPathComponent("service-b", isDirectory: true)
        let firstChange = GitChange(
            repositoryRoot: firstRoot,
            path: "src/App.swift",
            originalPath: nil,
            indexStatus: "M",
            workTreeStatus: "M"
        )
        let secondChange = GitChange(
            repositoryRoot: secondRoot,
            path: "src/App.swift",
            originalPath: nil,
            indexStatus: "U",
            workTreeStatus: "U"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                firstRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: firstRoot,
                    branch: "main",
                    changes: [firstChange]
                ),
                secondRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: secondRoot,
                    branch: "develop",
                    changes: [secondChange]
                )
            ],
            repositoryRoots: [firstRoot, secondRoot],
            commitResult: GitProcessResult(arguments: ["commit"], output: "committed", exitCode: 0)
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()

        #expect(feature.availableRepositoryRoots == [firstRoot, secondRoot])
        #expect(feature.gitChanges == [firstChange, secondChange])
        #expect(feature.currentBranch == "main")
        #expect(feature.activeRepositoryChanges == [firstChange])
        #expect(firstChange.id != secondChange.id)
        #expect(feature.gitTreeStatus.change(relativePath: firstChange.url.path) == firstChange)
        #expect(feature.gitTreeStatus.change(relativePath: secondChange.url.path) == secondChange)
        await feature.selectRepository(secondRoot)
        #expect(feature.gitRepositoryRoot == secondRoot)
        #expect(feature.currentBranch == "develop")
        #expect(feature.activeRepositoryChanges == [secondChange])
        #expect(feature.gitChanges == [firstChange, secondChange])
    }

    @Test(arguments: [false, true])
    func repositorySwitchUsesOnlyTheNewRepositoryReference(selectSpecificReference: Bool) async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let first = workspace.appendingPathComponent("first")
        let second = workspace.appendingPathComponent("second")
        let probe = GitRepositoryHistoryProbe()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                first.path: GitSnapshot(repositoryRoot: first, branch: "first-only", changes: []),
                second.path: GitSnapshot(repositoryRoot: second, branch: "second-only", changes: [])
            ], repositoryRoots: [first, second], repositoryHistoryProbe: probe
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { workspace }, isGitLogVisibleProvider: { true },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.selectGitReference(probe.reference(for: first))
        #expect(feature.selectedGitCommit?.hash == "first-commit")
        let countBeforeSwitch = probe.requests.count
        let nextReference = selectSpecificReference ? probe.reference(for: second) : nil

        await feature.selectRepository(second, reference: nextReference)

        let requests = Array(probe.requests.dropFirst(countBeforeSwitch))
        #expect(requests.count == 2) // One visible page plus the independent graph.
        #expect(requests.allSatisfy { $0.root == second })
        #expect(requests.filter { $0.reference != nil }.map(\.reference)
            == [nextReference?.fullName ?? "HEAD"])
        #expect(probe.closedCursors.contains { $0.root == first && $0.cursor == "first-cursor" })
        #expect(!probe.closedCursors.contains { $0.root == second && $0.cursor == "first-cursor" })
        #expect(feature.selectedGitReference == nextReference)
        #expect(feature.selectedGitCommit?.hash == "second-commit")
        #expect(feature.gitCommits.map(\.hash) == ["second-commit"])
    }

    @Test(arguments: [false, true])
    func latestRepositorySelectionWinsWhileStatusIsPending(returnToOriginal: Bool) async throws {
        let workspace = URL(fileURLWithPath: "/workspace")
        let roots = ["first", "second", "third"].map { workspace.appendingPathComponent($0) }
        let probe = GitRepositoryHistoryProbe()
        let snapshots = GitRepositorySwitchSnapshots()
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations(repositoryHistoryProbe: probe)),
            snapshotProvider: { root in await snapshots.next(root) },
            repositoryRootsProvider: { _ in roots })
        feature.configure(workspaceURLProvider: { workspace }, isGitLogVisibleProvider: { true },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await snapshots.blockNext()
        let oldSelection = Task { await feature.selectRepository(roots[1], reference: probe.reference(for: roots[1])) }
        defer { snapshots.release.open(); oldSelection.cancel(); feature.reset() }
        try #require(await snapshots.started.waitUntilOpen())
        let newestRoot = returnToOriginal ? roots[0] : roots[2]
        let newestReference = probe.reference(for: newestRoot)
        // Both tasks inherit MainActor. The release cannot run until the direct
        // selection below has stored its root/ref and suspended in refreshGit.
        let releaseTask = Task { snapshots.release.open() }
        defer { releaseTask.cancel() }
        await feature.selectRepository(newestRoot, reference: newestReference)
        try #require(await waitForGitTaskCompletion(oldSelection))
        await releaseTask.value

        #expect(feature.gitRepositoryRoot == newestRoot)
        #expect(feature.selectedGitReference == newestReference)
        #expect(feature.selectedGitCommit?.hash == "\(newestRoot.lastPathComponent)-commit")
        #expect(!probe.requests.contains { $0.reference == "refs/heads/second-only" })
    }

    @Test
    func failedHistoryAfterRepositorySwitchClearsOldCommitSelection() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let first = workspace.appendingPathComponent("first")
        let second = workspace.appendingPathComponent("second")
        let probe = GitRepositoryHistoryProbe(failedRoot: second)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                first.path: GitSnapshot(repositoryRoot: first, branch: "first-only", changes: []),
                second.path: GitSnapshot(repositoryRoot: second, branch: "second-only", changes: [])
            ], repositoryRoots: [first, second], repositoryHistoryProbe: probe
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { workspace }, isGitLogVisibleProvider: { true },
            notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.selectGitReference(probe.reference(for: first))
        #expect(feature.selectedGitCommit != nil)
        #expect(feature.canLoadMoreGitHistory)

        await feature.selectRepository(second)

        #expect(feature.gitRepositoryRoot == second)
        #expect(feature.selectedGitReference == nil)
        #expect(feature.selectedGitCommit == nil)
        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.gitCommits.isEmpty)
        #expect(feature.gitReferences.isEmpty)
        #expect(!feature.canLoadMoreGitHistory)
        #expect(!feature.isLoadingGitHistory)
    }

    @Test
    func sharedStagingEligibilityDisablesParentCheckbox() {
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()))
        let change = GitChange(repositoryRoot: URL(fileURLWithPath: "/workspace"), path: "libs/B",
            originalPath: nil, indexStatus: " ", workTreeStatus: "M",
            submodule: GitSubmoduleStatus(commitChanged: false, trackedChanges: true, untrackedChanges: false), canToggleStaging: false)
        #expect(feature.beginToggleStaging(change) == nil)
        #expect(feature.beginSetStaging([change], staged: true).isEmpty)
    }

    @Test(arguments: [false, true])
    func gitRefreshPreservesStagedDeletionAndUntrackedReplacement(reverseRecords: Bool) async {
        let root = URL(fileURLWithPath: "/workspace")
        // `git rm --cached` retains the file on disk: porcelain reports both
        // the staged deletion and the untracked file under the same identity.
        let deletion = GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
            indexStatus: "D", workTreeStatus: " ")
        let untracked = GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?")
        let changes = reverseRecords ? [untracked, deletion] : [deletion, untracked]
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: changes)
        )))
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})

        await feature.refreshGit()
        await feature.refreshGit()

        #expect(deletion.id == untracked.id)
        #expect(feature.gitChanges == changes)
        #expect(feature.currentBranch == "main")
        #expect(!feature.isStagingChanges)
        #expect(feature.effectiveStagingState(for: deletion))
        #expect(!feature.effectiveStagingState(for: untracked))
    }

    @Test(arguments: [false, true], [false, true])
    func duplicateGitStatusRecordsKeepStagingPendingUntilEveryRecordMatches(staged: Bool, reverseRecords: Bool) {
        let root = URL(fileURLWithPath: "/workspace")
        let deletion = GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
            indexStatus: "D", workTreeStatus: " ")
        let untracked = GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?")
        let changes = reverseRecords ? [untracked, deletion] : [deletion, untracked]
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()))
        defer { feature.reset() }
        let target = staged ? untracked : deletion
        #expect(feature.beginToggleStaging(target) == staged)

        // One matching record in a stale snapshot must not confirm either
        // staging the untracked replacement or unstaging the deleted file.
        feature.reconcilePendingStagingStates(with: changes, successfullyReadRepositoryRoots: [root])
        #expect(feature.isStagingChanges)
        #expect(feature.effectiveStagingState(for: deletion) == staged)
        #expect(feature.effectiveStagingState(for: untracked) == staged)
        #expect(feature.beginToggleStaging(target) == nil)

        let confirmed = GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
            indexStatus: staged ? "M" : " ", workTreeStatus: staged ? " " : "M")
        feature.reconcilePendingStagingStates(with: [confirmed], successfullyReadRepositoryRoots: [root])
        #expect(!feature.isStagingChanges)
        #expect(feature.effectiveStagingState(for: confirmed) == staged)
        #expect(feature.beginToggleStaging(confirmed) == !staged)
    }

    @Test(arguments: [false, true])
    func partialWorkspaceRefreshKeepsUnobservedStagingPending(staged: Bool) async {
        let firstRoot = URL(fileURLWithPath: "/workspace/A")
        let secondRoot = URL(fileURLWithPath: "/workspace/B")
        let changes = [firstRoot, secondRoot].map { root in
            GitChange(repositoryRoot: root, path: "example.txt", originalPath: nil,
                indexStatus: staged ? " " : "M", workTreeStatus: staged ? "M" : " ")
        }
        let firstDirty = GitSnapshot(repositoryRoot: firstRoot, branch: "main", changes: [changes[0]])
        let secondDirty = GitSnapshot(repositoryRoot: secondRoot, branch: "main", changes: [changes[1]])
        let firstClean = GitSnapshot(repositoryRoot: firstRoot, branch: "main", changes: [])
        let secondClean = GitSnapshot(repositoryRoot: secondRoot, branch: "main", changes: [])
        let snapshots = GitStatusSnapshotSequence(values: [
            firstRoot: [firstDirty, firstClean, firstClean, firstClean],
            secondRoot: [secondDirty, nil, secondDirty, secondClean]
        ])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()),
            snapshotProvider: { root in await snapshots.next(for: root) },
            repositoryRootsProvider: { _ in [firstRoot, secondRoot] })
        defer { feature.reset() }
        var notifications: [String] = []
        feature.configure(workspaceURLProvider: { firstRoot.deletingLastPathComponent() },
            isGitLogVisibleProvider: { false }, notify: { notifications.append($0) }, onStateRefreshed: {})
        await feature.refreshGit()
        #expect(feature.beginSetStaging(changes, staged: staged).count == 2)

        // A succeeds with a clean snapshot while B fails during an unconfirmed
        // staging request. Manual refresh must preserve B's commit protection.
        await feature.refreshGit()
        #expect(feature.gitChanges.isEmpty)
        #expect(feature.isStagingChanges)
        #expect(feature.effectiveStagingState(for: changes[0]) == changes[0].isStaged)
        #expect(feature.effectiveStagingState(for: changes[1]) == staged)
        #expect(feature.beginToggleStaging(changes[1]) == nil)
        #expect(await feature.commitStagedChanges(message: "Wait for B", amend: false) == false)
        #expect(notifications.last == "Wait for staging to finish before reviewing the commit plan.")

        // A later stale response from B still cannot confirm the request.
        await feature.refreshGit()
        #expect(feature.gitChanges == [changes[1]])
        #expect(feature.isStagingChanges)
        #expect(feature.effectiveStagingState(for: changes[1]) == staged)

        // Only B's successful clean snapshot can release the pending request.
        await feature.refreshGit()
        #expect(feature.gitChanges.isEmpty)
        #expect(!feature.isStagingChanges)
        #expect(feature.beginToggleStaging(changes[1]) == staged)
    }

    @Test(arguments: [Character("M"), Character("A")])
    func explicitStagingIncludesRemainingEditsWithoutChangingCheckboxSemantics(indexStatus: Character) {
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations()))
        defer { feature.reset() }
        let change = GitChange(repositoryRoot: URL(fileURLWithPath: "/workspace"), path: "Main.java",
            originalPath: nil, indexStatus: indexStatus, workTreeStatus: "M")
        #expect(feature.beginSetStaging([change], staged: true).isEmpty)
        #expect(feature.beginSetStaging([change], staged: true, includeWorkingTreeChanges: true) == [change])
        #expect(feature.beginSetStaging([change], staged: true, includeWorkingTreeChanges: true).isEmpty)
    }

    @Test
    func changelistManagementPersistsWithoutChangingTheIndexAndIsolatesWorkspaces() async throws {
        let root = URL(fileURLWithPath: "/workspace/A")
        let config = GitChange(repositoryRoot: root, path: "application.yaml", originalPath: nil,
                               indexStatus: "M", workTreeStatus: "M")
        let storage = ChangelistStorageProbe()
        let feature = workspaceCommitFeature(roots: [root], changes: [config], storage: storage)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.saveChangelistName(" Local config ") == nil)
        let id = try #require(feature.changelists.lists.last?.id)
        #expect(feature.saveChangelistName("local CONFIG") != nil)
        #expect(feature.saveChangelistName("Changed", id: GitLocalChangelists.defaultID) != nil)
        let originalSelection = feature.changelistSelectionGeneration
        feature.moveChanges([config], toChangelist: id)
        #expect(feature.changelistSelectionGeneration != originalSelection)
        let movedSelection = feature.changelistSelectionGeneration
        #expect(feature.gitChanges == [config])
        #expect(feature.activeChangelistChanges.isEmpty)
        #expect(feature.changelistCommitError != nil)
        feature.activateChangelist(id)
        #expect(feature.changelistSelectionGeneration != movedSelection)
        let activeSelection = feature.changelistSelectionGeneration
        feature.activateChangelist(GitLocalChangelists.defaultID)
        feature.activateChangelist(id)
        #expect(feature.changelistSelectionGeneration != activeSelection)
        #expect(feature.changelistCommitError == nil)
        #expect(feature.saveChangelistName("Private", id: id) == nil)
        let reopened = workspaceCommitFeature(roots: [root], changes: [config], storage: storage)
        defer { reopened.reset() }
        await reopened.refreshGit()
        #expect(reopened.changelists == feature.changelists)
        reopened.configure(workspaceURLProvider: { URL(fileURLWithPath: "/other-workspace") },
            isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        #expect(reopened.changelists.lists.count == 1)
        feature.removeChangelist(id)
        #expect(feature.changelists.activeID == GitLocalChangelists.defaultID)
        #expect(feature.activeChangelistChanges == [config])
        #expect(feature.gitChanges == [config])
    }

    @Test
    func changelistBulkStagingAndPreparationUseOnlyTheActiveList() async throws {
        let root = URL(fileURLWithPath: "/workspace/A")
        let config = GitChange(repositoryRoot: root, path: "application.yaml", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let code = GitChange(repositoryRoot: root, path: "feature.swift", originalPath: nil,
                             indexStatus: " ", workTreeStatus: "M")
        let recorder = StageCallRecorder()
        let probe = WorkspaceCommitProbe()
        let feature = workspaceCommitFeature(roots: [root], changes: [config, code], probe: probe, stageRecorder: recorder)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.saveChangelistName("Local") == nil)
        feature.moveChanges([config], toChangelist: try #require(feature.changelists.lists.last?.id))
        await feature.stageAllChanges()
        #expect(recorder.recorded.map(\.path) == ["feature.swift"])
        // The scripted status remains unstaged; failed staging must clear pending UI state.
        feature.includeChangelistParentReferences = false
        #expect(await !feature.commitStagedChanges(message: "Feature", amend: false))
        let request = try #require(probe.requests.last)
        #expect(request.pathScope == GitWorkspaceCommitPathScope(include: false, paths: ["A": ["application.yaml"]]))
        #expect(!request.includeParentReferences)
    }

    @Test
    func corruptOrUnwritableChangelistStorageBlocksStagingAndCommit() async {
        let root = URL(fileURLWithPath: "/workspace/A")
        let code = GitChange(repositoryRoot: root, path: "feature.swift", originalPath: nil,
                             indexStatus: "M", workTreeStatus: "M")
        let storage = ChangelistStorageProbe()
        storage.failLoad = true
        let probe = WorkspaceCommitProbe()
        let feature = workspaceCommitFeature(roots: [root], changes: [code], probe: probe, storage: storage)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.changelistStorageFailed)
        #expect(feature.activeChangelistChanges.isEmpty)
        #expect(feature.beginSetStaging([code], staged: false).isEmpty)
        #expect(feature.beginToggleStaging(code) == nil)
        #expect(await !feature.commitStagedChanges(message: "Blocked", amend: false))
        #expect(probe.requests.isEmpty)
        storage.failLoad = false
        feature.reset()
        await feature.refreshGit()
        storage.failSave = true
        #expect(feature.saveChangelistName("Local") != nil)
        #expect(feature.changelistStorageFailed)
        #expect(feature.changelists.lists.count == 1)
        #expect(await !feature.commitStagedChanges(message: "Blocked", amend: false))
        #expect(probe.requests.isEmpty)
    }

    @Test
    func changelistReviewAndRetryKeepTheOriginalScopeAndFreezeListEditing() async throws {
        let scope = GitWorkspaceCommitPathScope(include: false, paths: ["A": ["application.yaml"]])
        let original = try workspacePreparation(pathScope: scope)
        var failed = original.session
        failed.finished = true
        let probe = WorkspaceCommitProbe(preparations: [original, original, original], steps: [failed])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.saveChangelistName("Local") == nil)
        let id = try #require(feature.changelists.lists.last?.id)
        #expect(await !feature.commitStagedChanges(message: "Feature", amend: false))
        feature.activateChangelist(id)
        #expect(feature.changelists.activeID == GitLocalChangelists.defaultID)
        #expect(feature.saveChangelistName("Blocked") != nil)
        #expect(await !feature.confirmPendingSubmoduleCommit())
        #expect(probe.requests.last?.pathScope == scope)
        #expect(feature.changelistEditingDisabled)
        await feature.prepareWorkspaceCommitRetry()
        #expect(probe.requests.last?.pathScope == scope)
        #expect(probe.requests.last?.previous?.plan.pathScope == scope)
        feature.cancelPendingSubmoduleCommit()
        feature.dismissWorkspaceCommitResults()
        #expect(!feature.changelistEditingDisabled)
    }

    @Test
    func workspaceCommitConfirmationUsesTheSharedPlanAndForwardsOptions() async throws {
        let preparation = try workspacePreparation()
        let probe = WorkspaceCommitProbe(preparations: [preparation, preparation], steps: [completedWorkspace(preparation)])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await !feature.commitAndPushStagedChanges(message: "commit", amend: true))
        #expect(probe.stepCount == 0)
        #expect(feature.pendingSubmoduleCommitPlan?.orderedRoots.map(\.lastPathComponent) == ["B", "A"])
        #expect(await feature.confirmPendingSubmoduleCommit())
        #expect(probe.stepCount == 1)
        #expect(probe.requests.first?.amend == true)
        #expect(probe.requests.first?.push == true)
        #expect(probe.requests.first?.repositories.map(\.id) == ["A", "A/B"])
        #expect(probe.requests.last?.reviewed == preparation.session.plan)
        #expect(feature.workspaceCommitResults.allSatisfy { $0.committed && $0.pushed })
    }

    @Test
    func changedSharedCommitPlanRequiresAnotherConfirmationBeforeAnyStep() async throws {
        let original = try workspacePreparation()
        let changed = GitWorkspaceCommitPreparation(session: original.session, reviewChanged: true, requiresConfirmation: true)
        let probe = WorkspaceCommitProbe(preparations: [original, changed, original], steps: [completedWorkspace(original)])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await !feature.commitStagedChanges(message: "commit", amend: false))
        let oldID = feature.pendingSubmoduleCommitPlan?.id
        #expect(await !feature.confirmPendingSubmoduleCommit())
        #expect(probe.stepCount == 0)
        #expect(feature.pendingSubmoduleCommitPlan?.id != oldID)
        #expect(await feature.confirmPendingSubmoduleCommit())
        #expect(probe.stepCount == 1)
    }

    @Test
    func parentReferenceToggleAndRetryAreForwardedToCore() async throws {
        let original = try workspacePreparation()
        var failed = original.session
        failed.finished = true
        failed.results["A/B"] = GitWorkspaceRepositoryResult(committed: true, pushed: false, status: "pushFailed", detail: "stopped")
        failed.results["A"] = GitWorkspaceRepositoryResult(committed: false, pushed: false, status: "waitingForSubmodule", detail: "")
        let probe = WorkspaceCommitProbe(preparations: [original, original, original, original], steps: [failed])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await !feature.commitAndPushStagedChanges(message: "commit", amend: false))
        await feature.setCommitPlanParentReferences(false)
        #expect(probe.requests.last?.includeParentReferences == false)
        #expect(await !feature.confirmPendingSubmoduleCommit())
        #expect(feature.canRetryWorkspaceCommit)
        #expect(feature.workspaceCommitResults.first { $0.root.lastPathComponent == "A" }?.detail == "Waiting for submodule")
        await feature.prepareWorkspaceCommitRetry()
        #expect(probe.requests.last?.previous?.results["A/B"]?.committed == true)
        #expect(feature.pendingSubmoduleCommitPlan != nil)
        feature.cancelPendingSubmoduleCommit()
        #expect(feature.pendingSubmoduleCommitPlan == nil)
        #expect(feature.canRetryWorkspaceCommit)
    }

    @Test
    func workspaceWithoutRequiredConfirmationDrivesCoreStepsUntilFinished() async throws {
        let original = try workspacePreparation()
        let immediate = GitWorkspaceCommitPreparation(session: original.session, reviewChanged: false, requiresConfirmation: false)
        var progress = original.session
        progress.cursor = 1
        let probe = WorkspaceCommitProbe(preparations: [immediate], steps: [progress, completedWorkspace(original)])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await feature.commitStagedChanges(message: "commit", amend: false))
        #expect(probe.stepCount == 2)
        #expect(!feature.canRetryWorkspaceCommit)
        feature.dismissWorkspaceCommitResults()
        #expect(feature.workspaceCommitResults.isEmpty)
    }

    @Test
    func firstCoreStepFailureKeepsRecoveryActionsVisible() async throws {
        let original = try workspacePreparation()
        let immediate = GitWorkspaceCommitPreparation(session: original.session, reviewChanged: false, requiresConfirmation: false)
        let probe = WorkspaceCommitProbe(preparations: [immediate])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await !feature.commitStagedChanges(message: "commit", amend: false))
        #expect(feature.canRetryWorkspaceCommit)
        #expect(!feature.workspaceCommitResults.isEmpty)
        #expect(!feature.isCommitting)
        feature.dismissWorkspaceCommitResults()
        #expect(!feature.canRetryWorkspaceCommit)
        #expect(feature.workspaceCommitResults.isEmpty)
    }

    @Test
    func workspaceResetDuringCommitDoesNotStartTheNextStepOrPublishOldResults() async throws {
        let original = try workspacePreparation()
        let immediate = GitWorkspaceCommitPreparation(session: original.session, reviewChanged: false, requiresConfirmation: false)
        var progress = original.session
        progress.cursor = 1
        let started = GitModuleTestGate()
        let release = GitModuleTestGate()
        let probe = WorkspaceCommitProbe(preparations: [immediate], steps: [progress], started: started, release: release)
        let feature = workspaceCommitFeature(probe: probe)
        await feature.refreshGit()
        let task = Task { await feature.commitStagedChanges(message: "commit", amend: false) }
        defer { release.open(); task.cancel(); feature.reset() }
        #expect(await started.waitUntilOpen())
        feature.reset()
        release.open()
        #expect(await !task.value)
        #expect(probe.stepCount == 1)
        #expect(feature.workspaceCommitResults.isEmpty)
        #expect(!feature.isCommitting)
    }

    private nonisolated static func pushPreview(
        branch: String = "main",
        remote: String = "origin",
        remoteBranch: String? = nil,
        kind: GitPushTargetKind = .tracking,
        upstream: String? = "origin/main",
        createsRemoteBranch: Bool = false
    ) -> GitPushPreview {
        GitPushPreview(
            localBranch: branch, localHead: "head-\(branch)", remote: remote, remoteBranch: remoteBranch ?? branch,
            targetKind: kind, createsRemoteBranch: createsRemoteBranch, remoteTrackingOid: "tracking-\(branch)",
            upstream: upstream, commits: [GitCommit(hash: "c1", shortHash: "c1", parentHashes: [], authorName: "A",
                authorEmail: "a@example.com", date: "2026-10-22", subject: "Subject", decorations: "")])
    }

    @Test
    func pushReviewReturnsCoreDestinationAndSendsTheReviewedPreviewBack() async {
        let preview = Self.pushPreview(branch: "feature/topic")
        let recorder = PushCallRecorder()
        let feature = workspaceCommitFeature(
            pushPreview: { _, target, _ in recorder.recordPreview(target); return .success(preview) },
            pushReviewed: { _, reviewed, target in
                recorder.recordPush(reviewed, target)
                return GitProcessResult(output: "pushed", exitCode: 0)
            })
        defer { feature.reset() }
        await feature.refreshGit()
        let reference = GitReference(fullName: "refs/heads/feature/topic", shortName: "feature/topic", kind: .local,
            isCurrent: true, upstreamShortName: "origin/feature/topic")

        guard case .success(let resolved) = await feature.previewPush(reference, pushTarget: .upstream) else {
            Issue.record("The preview should resolve")
            return
        }
        #expect(resolved == preview)
        #expect(recorder.previewTargets == [.upstream])
        #expect(await feature.pushReviewed(reference, preview: resolved, pushTarget: .upstream) == nil)
        #expect(recorder.pushes.map(\.preview) == [preview])
        #expect(recorder.pushes.map(\.target) == [.upstream])
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test
    func rejectedReviewedPushReportsWhyAndLeavesNoBusyState() async {
        let preview = Self.pushPreview()
        let messages = PushMessageRecorder()
        let feature = workspaceCommitFeature(
            pushPreview: { _, _, _ in .success(preview) },
            pushReviewed: { _, _, _ in
                GitProcessResult(output: "Git push preview is stale; refresh and try again.", exitCode: 1)
            },
            notify: { messages.record($0) })
        defer { feature.reset() }
        await feature.refreshGit()
        let reference = GitReference(fullName: "refs/heads/main", shortName: "main", kind: .local,
            isCurrent: true, upstreamShortName: "origin/main")

        let failure = await feature.pushReviewed(reference, preview: preview, pushTarget: nil)

        #expect(failure?.message == "Git push preview is stale; refresh and try again.")
        #expect(messages.values.last == "Git push preview is stale; refresh and try again.")
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test
    func commitAndPushReviewsEveryDestinationBeforeAnyStep() async throws {
        let original = try workspacePreparation()
        // Core needs no review of its own here; the push alone must still wait.
        let immediate = GitWorkspaceCommitPreparation(session: original.session, reviewChanged: false, requiresConfirmation: false)
        let probe = WorkspaceCommitProbe(preparations: [immediate])
        let recorder = PushCallRecorder()
        let feature = workspaceCommitFeature(probe: probe, pushPreview: { reference, target, root in
            recorder.recordPreview(target)
            return .success(Self.pushPreview(branch: reference.shortName, remote: "origin", upstream: "origin/\(reference.shortName)"))
        })
        defer { feature.reset() }
        await feature.refreshGit()

        #expect(await !feature.commitAndPushStagedChanges(message: "commit", amend: false))

        #expect(probe.stepCount == 0)
        let plan = try #require(feature.pendingSubmoduleCommitPlan)
        #expect(plan.pushDestinations.count == 2)
        #expect(plan.pushDestinations.values.map(\.destination) == ["origin/main", "origin/main"])
        #expect(recorder.previewTargets == [nil, nil])
        #expect(!plan.needsPushTargetChoice)
    }

    @Test
    func divergentUpstreamBlocksContinueUntilAnsweredAndCarriesTheAnswerToCore() async throws {
        let question = GitWorkspacePushTargetQuestion(repositoryId: "A", localBranch: "main", remote: "origin",
            upstream: "origin/release", upstreamBranch: "release")
        let asking = try workspacePreparation(pushTargetQuestions: [question])
        let answer = question.confirmation(for: .upstream)
        let answered = try workspacePreparation(pushTargets: ["A": answer])
        let probe = WorkspaceCommitProbe(
            preparations: [asking, asking, answered, answered],
            steps: [completedWorkspace(answered)])
        let recorder = PushCallRecorder()
        let messages = PushMessageRecorder()
        let feature = workspaceCommitFeature(probe: probe, pushPreview: { reference, _, _ in
            recorder.recordPreview(nil)
            return .success(Self.pushPreview(branch: reference.shortName))
        }, notify: { messages.record($0) })
        defer { feature.reset() }
        await feature.refreshGit()

        #expect(await !feature.commitAndPushStagedChanges(message: "commit", amend: false))
        let pending = try #require(feature.pendingSubmoduleCommitPlan)
        #expect(pending.needsPushTargetChoice)
        #expect(pending.pushQuestion(for: URL(fileURLWithPath: "/workspace/A")) == question)
        // The repository with a pending question is not previewed as if it were settled.
        #expect(pending.pushDestinations.keys.map(\.path) == ["/workspace/A/B"])

        // Continue is refused while the destination is unanswered, and nothing runs.
        #expect(await !feature.confirmPendingSubmoduleCommit())
        #expect(probe.stepCount == 0)
        #expect(messages.values.contains("Choose which branch to update before pushing."))

        await feature.choosePushTarget(.upstream, for: question)
        #expect(probe.requests.last?.pushTargets == ["A": answer])
        let settled = try #require(feature.pendingSubmoduleCommitPlan)
        #expect(!settled.needsPushTargetChoice)
        #expect(settled.confirmedPushTarget(for: URL(fileURLWithPath: "/workspace/A")) == answer)
        // The choice stays changeable after it is answered.
        #expect(settled.pushQuestion(for: URL(fileURLWithPath: "/workspace/A")) == question)

        #expect(await feature.confirmPendingSubmoduleCommit())
        #expect(probe.requests.last?.pushTargets == ["A": answer])
        #expect(probe.stepCount == 1)
    }

    @Test
    func staleAnswerIsDroppedWhenCoreAsksTheQuestionAgain() async throws {
        let question = GitWorkspacePushTargetQuestion(repositoryId: "A", localBranch: "main", remote: "origin",
            upstream: "origin/release", upstreamBranch: "release")
        let movedQuestion = GitWorkspacePushTargetQuestion(repositoryId: "A", localBranch: "main", remote: "origin",
            upstream: "origin/hotfix", upstreamBranch: "hotfix")
        let asking = try workspacePreparation(pushTargetQuestions: [question])
        let askingAgain = try workspacePreparation(pushTargetQuestions: [movedQuestion])
        let probe = WorkspaceCommitProbe(preparations: [asking, askingAgain])
        let feature = workspaceCommitFeature(probe: probe)
        defer { feature.reset() }
        await feature.refreshGit()

        #expect(await !feature.commitAndPushStagedChanges(message: "commit", amend: false))
        await feature.choosePushTarget(.upstream, for: question)

        let plan = try #require(feature.pendingSubmoduleCommitPlan)
        #expect(plan.needsPushTargetChoice)
        #expect(plan.pushQuestion(for: URL(fileURLWithPath: "/workspace/A")) == movedQuestion)
        #expect(plan.confirmedPushTarget(for: URL(fileURLWithPath: "/workspace/A")) == nil)
    }

    @Test
    func confirmedPushTargetsSurviveTheRoundTripThroughCore() throws {
        let question = GitWorkspacePushTargetQuestion(repositoryId: "A", localBranch: "main", remote: "origin",
            upstream: "origin/release", upstreamBranch: "release")
        let preparation = try workspacePreparation(
            pushTargets: ["A": question.confirmation(for: .publish)], pushTargetQuestions: [question])

        let session = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preparation.session)) as? [String: Any]
        let plan = try #require(session?["plan"] as? [String: Any])
        let targets = try #require(plan["pushTargets"] as? [String: [String: String]])
        #expect(targets == ["A": ["choice": "publish", "remote": "origin", "remoteBranch": "main"]])

        let decoded = try JSONDecoder().decode(GitWorkspaceCommitPreparation.self, from: JSONEncoder().encode(preparation))
        #expect(decoded.pushTargetQuestions == [question])
        #expect(decoded.session.plan.pushTargets == preparation.session.plan.pushTargets)

        // Core omits both fields when nothing is pending, so older plans decode unchanged.
        let routine = try workspacePreparation()
        let routineJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(routine.session)) as? [String: Any]
        #expect((routineJSON?["plan"] as? [String: Any])?["pushTargets"] == nil)
        #expect(routine.pushTargetQuestions.isEmpty)
    }

    private func workspacePreparation(
        pathScope: GitWorkspaceCommitPathScope? = nil,
        pushTargets: [String: GitWorkspaceConfirmedPushTarget]? = nil,
        pushTargetQuestions: [GitWorkspacePushTargetQuestion] = []
    ) throws -> GitWorkspaceCommitPreparation {
        struct Fixture: Decodable { let preparation: GitWorkspaceCommitPreparation }
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/git/workspace-commit-workflow-v1.json")
        let preparation = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL)).preparation
        guard pathScope != nil || pushTargets != nil || !pushTargetQuestions.isEmpty else { return preparation }
        let current = preparation.session
        var plan = current.plan
        if let pathScope { plan.pathScope = pathScope }
        plan.pushTargets = pushTargets
        let session = GitWorkspaceCommitSession(plan: plan, states: current.states, results: current.results,
            blocked: current.blocked, cursor: current.cursor, commandFailed: current.commandFailed,
            finished: current.finished, succeeded: current.succeeded, canRetry: current.canRetry)
        return GitWorkspaceCommitPreparation(session: session, reviewChanged: preparation.reviewChanged,
            requiresConfirmation: preparation.requiresConfirmation, pushTargetQuestions: pushTargetQuestions)
    }

    private func completedWorkspace(_ preparation: GitWorkspaceCommitPreparation) -> GitWorkspaceCommitSession {
        var session = preparation.session
        session.finished = true; session.succeeded = true; session.canRetry = false
        session.cursor = session.plan.orderedIds.count
        session.results = ["A": GitWorkspaceRepositoryResult(committed: true, pushed: true, status: "committedAndPushed", detail: ""),
            "A/B": GitWorkspaceRepositoryResult(committed: true, pushed: true, status: "committedAndPushed", detail: "")]
        return session
    }

    private func workspaceCommitFeature(roots: [URL] = [URL(fileURLWithPath: "/workspace/A"), URL(fileURLWithPath: "/workspace/A/B")],
        changes: [GitChange] = [], probe: WorkspaceCommitProbe = WorkspaceCommitProbe(),
        storage: (any GitChangelistStorage)? = nil, stageRecorder: StageCallRecorder? = nil,
        pushPreview: (@Sendable (GitReference, GitPushTargetChoice?, URL) -> Result<GitPushPreview, GitPushFailure>)? = nil,
        pushReviewed: (@Sendable (GitReference, GitPushPreview, GitPushTargetChoice?) -> GitProcessResult?)? = nil,
        notify: @escaping @Sendable (String) -> Void = { _ in }) -> GitFeatureModel {
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotsByRoot: Dictionary(uniqueKeysWithValues: roots.map { root in
                (root.path, GitSnapshot(repositoryRoot: root, branch: "main", changes: changes.filter { $0.repositoryRoot == root }))
            }), repositoryRoots: roots, stageCallRecorder: stageRecorder, workspaceCommitProbe: probe,
            pushPreviewHandler: pushPreview, pushReviewedHandler: pushReviewed)), changelistStorage: storage)
        feature.configure(workspaceURLProvider: { URL(fileURLWithPath: "/workspace") }, isGitLogVisibleProvider: { false },
            notify: notify, onStateRefreshed: {})
        return feature
    }

    @Test
    func linkedWorktreeDetectionUsesPathComponentBoundaries() {
        let primary = URL(fileURLWithPath: "/workspace/op-platform", isDirectory: true)
        let linked = primary.appendingPathComponent(".worktrees/feature", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/workspace/op-platform-extra", isDirectory: true)
        let roots = [primary, linked, sibling]

        #expect(GitRepositoryHierarchy.isLinkedWorktreeRepository(linked, among: roots))
        // A sibling whose name merely shares a prefix must not be nested: a plain
        // string-prefix test would put `op-platform-extra` under `op-platform`.
        #expect(!GitRepositoryHierarchy.isLinkedWorktreeRepository(sibling, among: roots))
        #expect(!GitRepositoryHierarchy.isLinkedWorktreeRepository(primary, among: roots))
    }

    @Test
    func visibleRepositoryRootsHideWorktreesButAlwaysKeepActive() {
        let primary = URL(fileURLWithPath: "/workspace/op-platform", isDirectory: true)
        let linked = primary.appendingPathComponent(".worktrees/feature", isDirectory: true)
        let roots = [primary, linked]

        #expect(GitRepositoryHierarchy.visibleRepositoryRoots(
            roots, activeRoot: primary, showWorktreeRepositories: true
        ) == roots)
        #expect(GitRepositoryHierarchy.visibleRepositoryRoots(
            roots, activeRoot: primary, showWorktreeRepositories: false
        ) == [primary])
        // The active worktree stays visible even though it is normally hidden.
        #expect(GitRepositoryHierarchy.visibleRepositoryRoots(
            roots, activeRoot: linked, showWorktreeRepositories: false
        ) == [primary, linked])
        // A single-repository workspace is never regrouped.
        #expect(GitRepositoryHierarchy.visibleRepositoryRoots(
            [primary], activeRoot: primary, showWorktreeRepositories: false
        ) == [primary])
    }

    @Test
    func gitRepositoryReferencesAggregateAcrossWorkspaceRepositories() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let firstRoot = workspace.appendingPathComponent("service-a", isDirectory: true)
        let secondRoot = workspace.appendingPathComponent("service-b", isDirectory: true)
        let main = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let feature = GitReference(
            fullName: "refs/heads/feature/x",
            shortName: "feature/x",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
        let develop = GitReference(
            fullName: "refs/heads/develop",
            shortName: "develop",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                firstRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: firstRoot, branch: "main", changes: []
                ),
                secondRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: secondRoot, branch: "develop", changes: []
                )
            ],
            repositoryRoots: [firstRoot, secondRoot],
            referencesByRoot: [
                firstRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [main, feature]),
                secondRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [develop])
            ]
        ))
        let featureModel = GitFeatureModel(service: service)
        featureModel.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await featureModel.refreshGit()

        #expect(featureModel.availableRepositoryRoots == [firstRoot, secondRoot])
        #expect(featureModel.gitRepositoryReferences.map(\.repositoryRoot) == [firstRoot, secondRoot])
        #expect(featureModel.gitRepositoryReferences.first?.references.map(\.fullName)
            == ["refs/heads/main", "refs/heads/feature/x"])
        #expect(featureModel.gitRepositoryReferences.last?.references.map(\.fullName)
            == ["refs/heads/develop"])
    }

    @Test
    func gitRepositoryReferencesHoldOneEntryForSingleRepositoryWorkspace() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let root = workspace.appendingPathComponent("service-a", isDirectory: true)
        let main = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                root.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: root, branch: "main", changes: []
                )
            ],
            repositoryRoots: [root],
            referencesByRoot: [
                root.standardizedFileURL.path: GitReferenceSnapshot(references: [main])
            ]
        ))
        let featureModel = GitFeatureModel(service: service)
        featureModel.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await featureModel.refreshGit()

        #expect(featureModel.availableRepositoryRoots == [root])
        #expect(featureModel.gitRepositoryReferences.count == 1)
        #expect(featureModel.gitRepositoryReferences.first?.repositoryRoot == root)
        #expect(featureModel.gitRepositoryReferences.first?.references.map(\.fullName)
            == ["refs/heads/main"])
    }

    @Test
    func visibleHistoryPublishesBeforeRepositoryReferencesLoad() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let firstRoot = workspace.appendingPathComponent("service-a", isDirectory: true)
        let secondRoot = workspace.appendingPathComponent("service-b", isDirectory: true)
        let main = GitReference(
            fullName: "refs/heads/main", shortName: "main", kind: .local,
            isCurrent: true, upstreamShortName: nil
        )
        let develop = GitReference(
            fullName: "refs/heads/develop", shortName: "develop", kind: .local,
            isCurrent: true, upstreamShortName: nil
        )
        let probe = GitReferencesLoadProbe(blocking: secondRoot)
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                firstRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: firstRoot, branch: "main", changes: []
                ),
                secondRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: secondRoot, branch: "develop", changes: []
                )
            ],
            repositoryRoots: [firstRoot, secondRoot],
            referencesByRoot: [
                firstRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [main]),
                secondRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [develop])
            ],
            referencesProbe: probe,
            historyPageValues: [
                "": GitHistoryPage(
                    commits: [makeTestCommit(hash: "visible", subject: "Visible")],
                    nextCursor: nil,
                    hasMore: false
                )
            ]
        ))
        let featureModel = GitFeatureModel(service: service)
        featureModel.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )
        let visiblePublished = GitModuleTestGate()
        let observation = featureModel.$gitCommits.sink { commits in
            if commits.map(\.hash) == ["visible"] { visiblePublished.open() }
        }
        let refresh = Task { await featureModel.refreshGit() }
        defer {
            observation.cancel()
            probe.release.open()
            refresh.cancel()
            featureModel.reset()
        }

        // A blocked reference read in another repository must not hold back the
        // active repository's commit list.
        #expect(await probe.started.waitUntilOpen())
        #expect(await visiblePublished.waitUntilOpen())
        #expect(featureModel.gitCommits.map(\.hash) == ["visible"])
        #expect(!featureModel.isLoadingGitHistory)

        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(featureModel.gitRepositoryReferences.map(\.repositoryRoot) == [firstRoot, secondRoot])
        #expect(probe.requestedRoots.filter { $0 == firstRoot }.count == 1,
                "The active repository must reuse the same reference snapshot as the visible log")
        #expect(probe.requestedRoots.filter { $0 == secondRoot }.count == 1)
    }

    @Test
    func supersededRepositoryReferencesLoadDoesNotPublishAStalePage() async {
        let workspace = URL(fileURLWithPath: "/workspace")
        let firstRoot = workspace.appendingPathComponent("service-a", isDirectory: true)
        let secondRoot = workspace.appendingPathComponent("service-b", isDirectory: true)
        let main = GitReference(
            fullName: "refs/heads/main", shortName: "main", kind: .local,
            isCurrent: true, upstreamShortName: nil
        )
        let releaseBranch = GitReference(
            fullName: "refs/heads/release", shortName: "release", kind: .local,
            isCurrent: false, upstreamShortName: nil
        )
        let develop = GitReference(
            fullName: "refs/heads/develop", shortName: "develop", kind: .local,
            isCurrent: true, upstreamShortName: nil
        )
        let probe = GitReferencesLoadProbe(blocking: secondRoot)
        let service = GitService(operations: TestGitOperations(
            snapshotsByRoot: [
                firstRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: firstRoot, branch: "main", changes: []
                ),
                secondRoot.standardizedFileURL.path: GitSnapshot(
                    repositoryRoot: secondRoot, branch: "develop", changes: []
                )
            ],
            repositoryRoots: [firstRoot, secondRoot],
            referencesByRoot: [
                firstRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [main, releaseBranch]),
                secondRoot.standardizedFileURL.path: GitReferenceSnapshot(references: [develop])
            ],
            referencesProbe: probe,
            historyPageByReferenceHandler: { reference, _ in
                let hash = reference?.shortName == releaseBranch.shortName ? "current-page" : "stale-page"
                return GitHistoryPage(
                    commits: [makeTestCommit(hash: hash, subject: hash)],
                    nextCursor: nil,
                    hasMore: false
                )
            }
        ))
        let featureModel = GitFeatureModel(service: service)
        featureModel.configure(
            workspaceURLProvider: { workspace },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )
        let stalePublished = GitModuleTestGate()
        let observation = featureModel.$gitCommits.sink { commits in
            if commits.map(\.hash) == ["stale-page"] { stalePublished.open() }
        }
        let refresh = Task { await featureModel.refreshGit() }
        defer {
            observation.cancel()
            probe.release.open()
            refresh.cancel()
            featureModel.reset()
        }

        // The first refresh publishes its page, then blocks reading the other
        // repository's references.
        #expect(await probe.started.waitUntilOpen())
        #expect(await stalePublished.waitUntilOpen())
        #expect(featureModel.gitCommits.map(\.hash) == ["stale-page"])

        // Switching branch supersedes the first refresh; its reference read is
        // not blocked and must own the published page.
        await featureModel.selectGitReference(releaseBranch)
        #expect(featureModel.gitCommits.map(\.hash) == ["current-page"])

        // The stale read now returns with an older generation. It must not
        // republish the page it fetched before the switch.
        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(featureModel.gitCommits.map(\.hash) == ["current-page"])
    }

    @Test
    func gitServiceRecordsElapsedTimeForHistoryOperations() async {
        let root = URL(fileURLWithPath: "/workspace")
        let logger = GitPerformanceLogRecorder()
        let service = GitService(
            operations: TestGitOperations(historyValue: GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [],
                hasMore: false
            )),
            performanceLogger: logger
        )

        _ = await service.history(at: root, limit: 30)

        let messages = logger.messages
        #expect(messages.count == 1)
        #expect(messages.first?.contains("operation=history") == true)
        #expect(messages.first?.contains("duration_ms=") == true)
        #expect(messages.first?.contains("status=success") == true)
    }

    @Test
    func gitHistoryPublishesRecentReferencesInCoreOrder() async {
        let root = URL(fileURLWithPath: "/workspace")
        let main = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: "origin/main"
        )
        let featureBranch = GitReference(
            fullName: "refs/heads/feature/recent",
            shortName: "feature/recent",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            historyValue: GitHistorySnapshot(
                references: [featureBranch, main],
                recentReferences: [main, featureBranch],
                commits: [],
                hasMore: false
            )
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()

        #expect(feature.recentGitReferences.map(\.shortName) == ["main", "feature/recent"])
    }

    @Test
    func gitHistoryAppendsTheNextPageWithoutReplacingEarlierCommits() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commits = (0..<3).map { index in
            GitCommit(
                hash: "hash-\(index)",
                shortHash: "short-\(index)",
                parentHashes: [],
                authorName: "Lithe Test",
                authorEmail: "test@example.com",
                date: "2026/09/01 10:0\(index)",
                subject: "commit-\(index)",
                decorations: ""
            )
        }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            referencesValue: GitReferenceSnapshot(
                references: [],
                recentReferences: [],
                identity: GitIdentity(name: "Lithe Test", email: "test@example.com")
            ),
            historyPageValues: [
                "": GitHistoryPage(
                    commits: Array(commits.prefix(2)),
                    nextCursor: "cursor-2",
                    hasMore: true
                ),
                "cursor-2": GitHistoryPage(
                    commits: [commits[2]],
                    nextCursor: nil,
                    hasMore: false
                )
            ]
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == ["hash-0", "hash-1"])
        #expect(feature.canLoadMoreGitHistory)

        await feature.loadMoreGitHistory()

        #expect(feature.gitCommits.map(\.hash) == ["hash-0", "hash-1", "hash-2"])
        #expect(!feature.canLoadMoreGitHistory)
    }

    @Test
    func backgroundRefreshRetainsDeepHistoryAndSelectionWhileExternalCommitsStillAppear() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commits = (0..<300).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let controller = GitPagingRefreshController(commits: commits)
        let clean = GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        let dirty = GitSnapshot(repositoryRoot: root, branch: "main", changes: [
            GitChange(repositoryRoot: root, path: "tracked.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        ])
        let snapshots = GitStatusSnapshotSequence(values: [root: [clean, dirty, dirty, dirty]])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: clean,
            historyPageRequestHandler: { reference, cursor, limit in
                controller.page(reference: reference, cursor: cursor, limit: limit)
            }
        )), snapshotProvider: { await snapshots.next(for: $0) })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true },
                          notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.loadMoreGitHistory()
        await feature.selectGitCommit(commits[199])
        let version = feature.gitCommitsVersion
        let requestCount = controller.visibleLimits.count
        await feature.refreshGit()
        #expect(controller.visibleLimits.count == requestCount, "A file-status edit must not restart history")
        #expect(feature.gitCommitsVersion == version)
        #expect(feature.gitCommits == Array(commits.prefix(200)))

        var publishedCounts: [Int] = []
        let observation = feature.$gitCommits.sink { publishedCounts.append($0.count) }
        defer { observation.cancel() }
        await feature.refreshGitFromMetadataChange()
        #expect(feature.gitCommitsVersion == version, "Unchanged metadata must not invalidate the graph projection")
        #expect(feature.selectedGitCommit?.hash == commits[199].hash)
        #expect(feature.canLoadMoreGitHistory)

        let newHead = makeTestCommit(hash: "external-head", subject: "External commit")
        controller.prepend(newHead)
        await feature.refreshGitFromMetadataChange()
        #expect(feature.gitCommits.first == newHead, "A clean status cannot hide an external commit")
        #expect(feature.gitCommits == [newHead] + Array(commits.prefix(200)))
        #expect(feature.selectedGitCommit?.hash == commits[199].hash, "New heads must not evict the selected loaded tail")
        #expect(publishedCounts == [200, 201], "Background refresh publishes the complete window atomically")
        #expect(controller.visibleLimits == [100, 100, 200, 200, 1])
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits == [newHead] + commits)
    }

    @Test
    func continuousHistoryPagingStopsOnDuplicatePagesAndRefreshesAfterFailure() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(hash: "one", shortHash: "one", parentHashes: [], authorName: "Test",
                               authorEmail: "", date: "", subject: "One", decorations: "")
        for fails in [false, true] {
            var pages = ["": GitHistoryPage(commits: [commit], nextCursor: "next", hasMore: true)]
            if !fails { pages["next"] = GitHistoryPage(commits: [commit, commit], nextCursor: "stuck", hasMore: true) }
            let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), historyPageValues: pages)))
            feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true },
                              notify: { _ in }, onStateRefreshed: {})
            defer { feature.reset() }
            await feature.refreshGit()
            #expect(feature.canLoadMoreGitHistory)
            await feature.loadMoreGitHistory()
            #expect(feature.gitCommits.map(\.hash) == ["one"])
            #expect(!feature.isLoadingMoreGitHistory)
            #expect(feature.gitHistoryPageFailed == fails)
            #expect(feature.canLoadMoreGitHistory == fails)
            // Explicit retry opens a new first-page cursor; no-progress stays exhausted.
            await feature.loadMoreGitHistory()
            #expect(!feature.gitHistoryPageFailed)
            #expect(feature.canLoadMoreGitHistory == fails)
            #expect(feature.gitCommits.map(\.hash) == ["one"])
        }
    }

    @Test
    func historyPageRetryKeepsTheLoadedWindowAndSelection() async {
        let root = URL(fileURLWithPath: "/workspace")
        let commits = (0..<300).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let controller = GitPagingRefreshController(commits: commits)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            historyPageRequestHandler: { reference, cursor, limit in
                controller.page(reference: reference, cursor: cursor, limit: limit)
            }
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true },
                          notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.loadMoreGitHistory()
        await feature.selectGitCommit(commits[150])
        #expect(feature.gitCommits == Array(commits.prefix(200)))

        controller.setFailsContinuations(true)
        await feature.loadMoreGitHistory()
        #expect(feature.gitHistoryPageFailed)
        #expect(feature.gitCommits == Array(commits.prefix(200)))

        controller.setFailsContinuations(false)
        await feature.loadMoreGitHistory()
        #expect(!feature.gitHistoryPageFailed)
        #expect(feature.gitCommits == Array(commits.prefix(200)), "Retry must not shrink the list to the first page")
        #expect(feature.selectedGitCommit?.hash == commits[150].hash, "Retry must not move the selection")
        #expect(feature.canLoadMoreGitHistory)
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits == commits)
    }

    @Test
    func repositoryGraphIsSeparateFromVisiblePagingAndReleasesItsCursor() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        #expect(feature.canLoadMoreGitHistory)
        #expect(probe.closedCursors == ["graph-cursor"])
        #expect(probe.requestedAllReferences)
        let version = feature.gitGraphRepositoryVersion
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        #expect(feature.gitGraphRepositoryVersion == version)

        probe.failGraphRequest()
        await feature.refreshGitHistory()
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(feature.gitGraphRepositoryVersion > version)
    }

    @Test
    func visibleHistoryPublishesBeforeRepositoryGraphCompletes() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe(blockGraph: true)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let visiblePublished = GitModuleTestGate()
        let observation = feature.$gitCommits.sink { commits in
            if commits.map(\.hash) == ["visible"] { visiblePublished.open() }
        }
        let refresh = Task { await feature.refreshGit() }
        defer { observation.cancel(); probe.release.open(); refresh.cancel(); feature.reset() }

        #expect(await probe.started.waitUntilOpen())
        #expect(await visiblePublished.waitUntilOpen())
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(!feature.isLoadingGitHistory)
        #expect(feature.canLoadMoreGitHistory)
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        // Paging remains usable while the repository context is on its worker.
        await feature.loadMoreGitHistory()
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        #expect(feature.gitCommits.map(\.hash) == ["visible", "older"])
        #expect(probe.closedCursors == ["graph-cursor"])
    }

    @Test
    func supersededRepositoryGraphCannotReplaceNewContext() async {
        let root = URL(fileURLWithPath: "/workspace")
        // The first worker deliberately returns after cancellation and after
        // the second refresh, as a native operation racing cancellation can.
        let probe = GitGraphHistoryProbe(blockGraph: true, releaseOnCancel: false)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let refresh = Task { await feature.refreshGit() }
        defer { probe.release.open(); refresh.cancel(); feature.reset() }
        #expect(await probe.started.waitUntilOpen())

        await feature.showAllGitReferences()
        #expect(feature.isShowingAllGitReferences)
        #expect(feature.gitGraphRepositoryCommits.map(\.hash) == ["other-branch", "visible"])
        let version = feature.gitGraphRepositoryVersion
        probe.release.open()
        await refresh.value
        #expect(!probe.didTimeOut)
        #expect(feature.gitGraphRepositoryVersion == version)
        #expect(feature.gitCommits.map(\.hash) == ["visible"])
        #expect(probe.closedCursors.filter { $0 == "graph-cursor" }.count == 2)
    }

    @Test
    func cancelledRepositoryGraphCannotPublishIntoAResetWorkspace() async {
        let root = URL(fileURLWithPath: "/workspace")
        let probe = GitGraphHistoryProbe(blockGraph: true)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []), graphHistoryProbe: probe
        )))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { true }, notify: { _ in }, onStateRefreshed: {})
        let refresh = Task { await feature.refreshGit() }
        defer { probe.release.open(); refresh.cancel(); feature.reset() }
        let started = await probe.started.waitUntilOpen()
        feature.reset()
        probe.release.open()
        await refresh.value
        #expect(started)
        #expect(!probe.didTimeOut)
        #expect(probe.graphWasCancelled)
        #expect(Set(probe.closedCursors) == ["graph-cursor", "visible-cursor"])
        #expect(feature.gitGraphRepositoryCommits.isEmpty)
        #expect(feature.gitCommits.isEmpty)
    }

    @Test
    func successfulRevertRefreshesVisibleGitHistoryAndFocusesCurrentHead() async {
        let root = URL(fileURLWithPath: "/workspace")
        let revertedCommit = makeTestCommit(hash: "original-commit", subject: "Original change")
        let revertCommit = makeTestCommit(hash: "revert-commit", subject: "Revert original change")
        let controller = GitHistoryMutationController(
            before: [revertedCommit],
            after: [revertCommit, revertedCommit]
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            historyPageHandler: { controller.historyPage() },
            revertHandler: { hash in controller.revert(hash) }
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { true },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        #expect(feature.gitCommits.map(\.hash) == [revertedCommit.hash])
        await feature.showAllGitReferences()
        #expect(feature.isShowingAllGitReferences)

        await feature.revert(revertedCommit)

        #expect(feature.gitCommits.map(\.hash) == [revertCommit.hash, revertedCommit.hash])
        #expect(!feature.isShowingAllGitReferences)
        #expect(feature.selectedGitCommit?.hash == revertCommit.hash)
        #expect(controller.revertedHashes == [revertedCommit.hash])
        // Each refresh loads the visible page and independent repository graph.
        #expect(controller.historyCallCount == 8)
    }

    @Test
    func remoteReferenceActionsPreserveIdentityAndPullStrategy() async {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/remotes/origin/feature/demo",
            shortName: "origin/feature/demo",
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.checkoutAndRebase(reference)
        await feature.pullRemoteReference(reference, strategy: .rebase)
        await feature.pullRemoteReference(reference, strategy: .merge)

        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["checkoutAndRebase", reference.fullName],
            ["pull", "rebase", reference.fullName],
            ["pull", "merge", reference.fullName]
        ])
    }

    @Test
    func postInvocationOperationErrorFailsWhileKeepingConsoleTrace() async {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let operationError = "Invalid Git reference"
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            stageResult: GitProcessResult(
                arguments: ["stash", "push", "--include-untracked"],
                output: operationError,
                standardOutput: "No local changes to save\n",
                standardError: "",
                exitCode: 0,
                invocations: [
                    GitProcessInvocation(
                        arguments: ["stash", "push", "--include-untracked"],
                        standardOutput: "No local changes to save\n",
                        standardError: "",
                        exitCode: 0
                    )
                ],
                operationErrorMessage: operationError
            )
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { notifications.append($0) },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectChange(change)
        await feature.stageSelectedChange()

        let result = await service.stage(change)
        #expect(!result.succeeded)
        #expect(notifications == [operationError])
        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["stash", "push", "--include-untracked"]
        ])
        #expect(feature.gitConsoleEntries.first?.succeeded == true)
    }

    @Test(arguments: [false, true])
    func confirmedDiscardSurvivesDialogDismissal(untracked: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil,
                               indexStatus: untracked ? "?" : " ", workTreeStatus: untracked ? "?" : "M")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            discardHandler: { target in
                GitProcessResult(arguments: ["discard", target.path], output: "", standardOutput: "",
                                 standardError: "", exitCode: 0)
            }
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { notifications.append($0) }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestDiscardChange(change)
        let confirmed = try #require(feature.pendingDiscardChange)
        // SwiftUI dismisses the dialog before the button's asynchronous operation starts.
        feature.cancelDiscardChange()
        #expect(feature.gitConsoleEntries.isEmpty)
        await feature.confirmDiscardChange(confirmed)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "target.txt"]])
        #expect(notifications == ["Discarded target.txt"])
        #expect(feature.pendingDiscardChange == nil)
        #expect(feature.gitChanges.isEmpty)
    }

    @Test
    func commitFilesPreparesExactlyTheRequestedIndexAndRejectsMixedChangelists() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = [
            GitChange(repositoryRoot: root, path: "selected.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M"),
            GitChange(repositoryRoot: root, path: "excluded.txt", originalPath: nil, indexStatus: "M", workTreeStatus: " ")
        ]
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: changes)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root],
            stageHandler: { probe.mutate($0, action: "stage") }, unstageHandler: { probe.mutate($0, action: "unstage") })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.saveChangelistName("Selected") == nil)
        let list = try #require(feature.changelists.lists.last?.id)
        feature.moveChanges([changes[0]], toChangelist: list)
        #expect(!feature.canPrepareCommitFiles(changes))
        #expect(await feature.prepareCommitFiles([changes[0]]))
        #expect(feature.changelists.activeID == list)
        #expect(probe.calls.map(\.action) == ["unstage", "stage"])
        #expect(probe.calls.map { $0.change.path } == ["excluded.txt", "selected.txt"])
        #expect(feature.gitChanges.filter(\.isStaged).map(\.path) == ["selected.txt"])
    }

    @Test
    func commitFilesStopsAtFirstFailureAndDoesNotPretendAStaleSnapshotSucceeded() async {
        let root = URL(fileURLWithPath: "/workspace")
        let selected = GitChange(repositoryRoot: root, path: "selected.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let excluded = GitChange(repositoryRoot: root, path: "excluded.txt", originalPath: nil, indexStatus: "M", workTreeStatus: " ")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [selected, excluded])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root],
            stageHandler: { probe.mutate($0, action: "stage") },
            unstageHandler: { probe.mutate($0, action: "unstage", succeeds: false) })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(await !feature.prepareCommitFiles([selected]))
        #expect(probe.calls.map(\.action) == ["unstage"] && !feature.isPreparingCommitFiles)

        let stale = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [selected]),
            stageResult: GitProcessResult(arguments: ["stage"], output: "", exitCode: 0))))
        stale.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { stale.reset() }
        await stale.refreshGit()
        #expect(await !stale.prepareCommitFiles([selected]))
        #expect(!stale.isPreparingCommitFiles)
    }

    @Test(arguments: [false, true])
    func commitFilesBlocksReentryAndStopsAfterCancellationOrReset(reset: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["first.txt", "second.txt"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let gate = TestGitRunGate()
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: changes)
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root], stageHandler: {
                gate.blockFirstRun()
                return probe.mutate($0, action: "stage")
            })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        var result = true
        let task = Task { result = await feature.prepareCommitFiles(changes) }
        defer { gate.releaseFirstRun(); task.cancel(); feature.reset() }
        try #require(await gate.waitUntilFirstRunStarts())
        #expect(feature.isPreparingCommitFiles && feature.changelistEditingDisabled && !feature.canRollbackChanges)
        #expect(await !feature.prepareCommitFiles(changes))
        #expect(feature.beginSetStaging(changes, staged: false).isEmpty)
        if reset { feature.reset() } else { task.cancel() }
        gate.releaseFirstRun()
        try #require(await waitForGitTaskCompletion(task))
        #expect(!result && !feature.isPreparingCommitFiles && !gate.didTimeOut)
        #expect(probe.calls.count == 1)
    }

    @Test(arguments: ["stage", "unstage", "discard", "rollback"])
    func localMutationsPublishBeforeWorkspaceDrainAndNeverScanSiblingRepositories(action: String) async throws {
        let root = URL(fileURLWithPath: "/workspace"), sibling = root.appendingPathComponent("sibling")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil,
            indexStatus: action == "unstage" || action == "rollback" ? "M" : " ", workTreeStatus: "M")
        let directory = GitChange(repositoryRoot: sibling, path: "generated/", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 101)
        let child = GitChange(repositoryRoot: sibling, path: "generated/child.txt", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change, directory])
        let drainEntered = GitModuleTestGate(), releaseDrain = GitModuleTestGate()
        let metadataReads = CleanedPaths()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root, sibling],
            discardHandler: { probe.mutate($0, action: "discard") },
            discardAllHandler: { probe.mutate($0, action: "discard") },
            stageHandler: { probe.mutate($0, action: "stage") }, unstageHandler: { probe.mutate($0, action: "unstage") })),
            stashesProvider: { url in metadataReads.append(url.path); return [] },
            untrackedDirectoryChildrenProvider: { _ in [child] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {},
            onGitOperationEnded: { drainEntered.open(); _ = await releaseDrain.waitUntilOpen() })
        defer { releaseDrain.open(); feature.reset() }
        await feature.refreshGit()
        await feature.toggleUntrackedDirectory(directory)
        await feature.selectChange(change)
        let readCount = probe.snapshotRoots.count, metadataCount = metadataReads.paths.count
        if action == "rollback" { feature.requestRollbackChanges([change], included: [change]) }
        let selection = feature.pendingRollbackSelection
        let task = Task {
            switch action {
            case "stage": await feature.stageChange(change)
            case "unstage": await feature.unstageChange(change)
            case "rollback": if let selection { await feature.confirmRollbackChanges(selection) }
            default: await feature.discardChanges([change])
            }
        }
        defer { task.cancel(); releaseDrain.open() }
        try #require(await drainEntered.waitUntilOpen())
        #expect(Array(probe.snapshotRoots.dropFirst(readCount)) == [root])
        #expect(metadataReads.paths.count == metadataCount)
        #expect(feature.expandedUntrackedDirectoryIDs == [directory.id])
        #expect(feature.gitChanges.filter { $0.repositoryRoot == sibling } == [directory, child])
        #expect(!feature.isRollingBackChanges && !feature.isStagingChanges)
        if action == "stage" || action == "unstage" {
            #expect(feature.gitChanges.first?.isStaged == (action == "stage"))
            #expect(feature.selectedChange == feature.gitChanges.first)
        } else {
            #expect(!feature.gitChanges.contains { $0.repositoryRoot == root })
            #expect(feature.selectedChange == nil)
        }
        releaseDrain.open()
        try #require(await waitForGitTaskCompletion(task))
    }

    @Test
    func oldWorkspaceReadCannotResurrectStatusAfterALocalMutation() async throws {
        let root = URL(fileURLWithPath: "/workspace"), sibling = root.appendingPathComponent("sibling")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let other = GitChange(repositoryRoot: sibling, path: "other.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change, other])
        let oldReadEntered = GitModuleTestGate(), releaseOldRead = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            repositoryRoots: [root, sibling], stageHandler: { probe.mutate($0, action: "stage") })),
            snapshotProvider: { url in
                let snapshot = probe.snapshot(url)
                if url == sibling, probe.snapshotRoots.filter({ $0 == sibling }).count == 2 {
                    oldReadEntered.open()
                    _ = await releaseOldRead.waitUntilOpen()
                }
                return snapshot
            })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { releaseOldRead.open(); feature.reset() }
        await feature.refreshGit()
        let refresh = Task { await feature.refreshGit() }
        defer { refresh.cancel(); releaseOldRead.open() }
        try #require(await oldReadEntered.waitUntilOpen())
        await feature.stageChange(change)
        #expect(feature.gitChanges.first?.isStaged == true)
        var laterStates: [Bool] = []
        let subscription = feature.$gitChanges.sink { changes in
            if let target = changes.first(where: { $0.path == "target.txt" }) { laterStates.append(target.isStaged) }
        }
        defer { subscription.cancel() }
        releaseOldRead.open()
        try #require(await waitForGitTaskCompletion(refresh))
        #expect(!laterStates.isEmpty && laterStates.allSatisfy { $0 })
        #expect(feature.gitChanges.contains(other))
    }

    @Test
    func failedMutationReadRetainsRowsAndPendingCheckboxUntilAConfirmedStatus() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root], stageHandler: { probe.mutate($0, action: "stage") })))
        var messages: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { messages.append($0) }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        probe.failSnapshots()
        let staged = try #require(feature.beginToggleStaging(change) as Bool?)
        #expect(staged)
        await feature.finishToggleStaging(change, staged: staged)
        #expect(feature.gitChanges == [change])
        #expect(feature.pendingStagedStates == [change.id: true])
        #expect(feature.isStagingChanges && !messages.isEmpty)
        probe.restoreSnapshots()
        await feature.refreshGit()
        #expect(feature.gitChanges.first?.isStaged == true)
        #expect(feature.pendingStagedStates.isEmpty && !feature.isStagingChanges)
    }

    @Test(arguments: [false, true])
    func competingLocalMutationsPublishTheLastCompletedCommandAndRejectOldStatus(blockCommand: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change])
        let entered = GitModuleTestGate(), release = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(repositoryRoots: [root],
            stageHandler: { target in
                if blockCommand { entered.open(); guard release.waitSynchronously() else { return nil } }
                return probe.mutate(target, action: "stage")
            }, unstageHandler: { probe.mutate($0, action: "unstage") })), snapshotProvider: { url in
                let snapshot = probe.snapshot(url)
                if !blockCommand, probe.snapshotRoots.count == 2 {
                    entered.open(); _ = await release.waitUntilOpen()
                }
                return snapshot
            })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        let first = Task { await feature.stageChange(change) }
        defer { first.cancel(); release.open(); feature.reset() }
        try #require(await entered.waitUntilOpen())
        await feature.unstageChange(change)
        #expect(feature.gitChanges.first?.isStaged == false)
        release.open()
        try #require(await waitForGitTaskCompletion(first))
        // A blocked command writes last; a blocked read must not resurrect its old snapshot.
        #expect(feature.gitChanges.first?.isStaged == blockCommand)
    }

    @Test
    func resetRefreshCannotFinishOrPublishIntoTheReopenedWorkspace() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let oldChange = GitChange(repositoryRoot: root, path: "old.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let newChange = GitChange(repositoryRoot: root, path: "new.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let oldEntered = GitModuleTestGate(), oldRelease = GitModuleTestGate()
        let newEntered = GitModuleTestGate(), newRelease = GitModuleTestGate()
        let reads = CleanedPaths()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(repositoryRoots: [root])),
            snapshotProvider: { url in
                reads.append(url.path)
                let first = reads.paths.count == 1
                if first { oldEntered.open(); _ = await oldRelease.waitUntilOpen() }
                else { newEntered.open(); _ = await newRelease.waitUntilOpen() }
                return GitSnapshot(repositoryRoot: url, branch: "main", changes: [first ? oldChange : newChange])
            })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        let old = Task { await feature.refreshGit() }
        defer { old.cancel(); oldRelease.open(); newRelease.open(); feature.reset() }
        try #require(await oldEntered.waitUntilOpen())
        feature.reset()
        let reopened = Task { await feature.refreshGit() }
        defer { reopened.cancel(); newRelease.open() }
        try #require(await newEntered.waitUntilOpen())
        oldRelease.open()
        try #require(await waitForGitTaskCompletion(old))
        #expect(feature.isRefreshingGit && feature.gitChanges.isEmpty)
        newRelease.open()
        try #require(await waitForGitTaskCompletion(reopened))
        #expect(!feature.isRefreshingGit && feature.gitChanges == [newChange])
    }

    @Test
    func newerLocalStatusCannotBeOverwrittenByAnOlderExpandedDirectoryRead() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let directory = GitChange(repositoryRoot: root, path: "generated/", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 101)
        let child = GitChange(repositoryRoot: root, path: "generated/child.txt", originalPath: nil, indexStatus: "?", workTreeStatus: "?")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change, directory])
        let entered = GitModuleTestGate(), release = GitModuleTestGate(), listings = CleanedPaths()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, repositoryRoots: [root], stageHandler: { probe.mutate($0, action: "stage") })),
            untrackedDirectoryChildrenProvider: { _ in
                listings.append("read")
                if listings.paths.count == 2 { entered.open(); _ = await release.waitUntilOpen() }
                return [child]
            })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.toggleUntrackedDirectory(directory)
        let first = Task { await feature.stageChange(change) }
        defer { first.cancel(); release.open(); feature.reset() }
        try #require(await entered.waitUntilOpen())
        probe.replaceChanges([])
        await feature.stageChange(change)
        #expect(feature.gitChanges.isEmpty && feature.expandedUntrackedDirectoryIDs.isEmpty)
        release.open()
        try #require(await waitForGitTaskCompletion(first))
        #expect(feature.gitChanges.isEmpty && feature.expandedUntrackedDirectoryIDs.isEmpty)
    }

    @Test
    func supersededRootReadStillConfirmsOtherRootsInTheSameMutation() async throws {
        let root = URL(fileURLWithPath: "/workspace"), sibling = root.appendingPathComponent("sibling")
        let changes = [root, sibling].map {
            GitChange(repositoryRoot: $0, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: changes)
        let entered = GitModuleTestGate(), release = GitModuleTestGate()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            discardHandler: { probe.mutate($0, action: "discard") }, stageHandler: { probe.mutate($0, action: "stage") })),
            snapshotProvider: { url in
                let snapshot = probe.snapshot(url)
                if url == root, probe.snapshotRoots.filter({ $0 == root }).count == 2 {
                    entered.open(); _ = await release.waitUntilOpen()
                }
                return snapshot
            }, repositoryRootsProvider: { _ in [root, sibling] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        let batch = Task { await feature.discardChanges(changes) }
        defer { batch.cancel(); release.open(); feature.reset() }
        try #require(await entered.waitUntilOpen())
        // A new command supersedes only the first root's blocked status read.
        probe.replaceChanges([changes[0]])
        await feature.stageChange(changes[0])
        #expect(feature.gitChanges.first?.isStaged == true)
        release.open()
        try #require(await waitForGitTaskCompletion(batch))
        #expect(feature.gitChanges.count == 1 && feature.gitChanges.first?.repositoryRoot == root)
        #expect(feature.gitChanges.first?.isStaged == true)
        #expect(probe.snapshotRoots.filter { $0 == sibling }.count == 2)
    }

    @Test
    func hostCollapseDuringScopedPublicationCannotReinsertHiddenChildren() async throws {
        let root = URL(fileURLWithPath: "/workspace"), worktree = makeTestWorktree(path: "/workspace", branch: "main")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let directory = GitChange(repositoryRoot: root, path: "generated/", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 101)
        let child = GitChange(repositoryRoot: root, path: "generated/child.txt", originalPath: nil, indexStatus: "?", workTreeStatus: "?")
        let probe = WorktreeChangesProbe(root: URL(fileURLWithPath: "/unused"), changes: [change, directory])
        let entered = GitModuleTestGate(), release = GitModuleTestGate(), listings = CleanedPaths()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotHandler: { probe.snapshot($0) }, stageHandler: { probe.mutate($0, action: "stage") })),
            worktreesProvider: { _ in [worktree] }, repositoryRootsProvider: { [$0] },
            untrackedDirectoryChildrenProvider: { _ in
                listings.append("read")
                if listings.paths.count == 4 { entered.open(); _ = await release.waitUntilOpen() }
                return [child]
            })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        let scoped = feature.commitFeature(for: worktree)
        await feature.toggleUntrackedDirectory(directory); await scoped.toggleUntrackedDirectory(directory)
        let mutation = Task { await feature.stageChange(change) }
        defer { mutation.cancel(); release.open(); feature.reset() }
        try #require(await entered.waitUntilOpen())
        await feature.toggleUntrackedDirectory(directory)
        #expect(feature.expandedUntrackedDirectoryIDs.isEmpty)
        release.open()
        try #require(await waitForGitTaskCompletion(mutation))
        #expect(feature.gitChanges.contains(directory) && !feature.gitChanges.contains(child))
        #expect(scoped.gitChanges.contains(child) && scoped.expandedUntrackedDirectoryIDs == [directory.id])
        #expect(feature.gitChanges.first?.isStaged == true && scoped.gitChanges.first?.isStaged == true)
    }

    @Test(arguments: [false, true])
    func worktreeScopedMutationKeepsExpandedRowsAndHostHistoryWithoutSiblingReads(useScoped: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace"), worktree = makeTestWorktree(path: "/linked", branch: "linked")
        let change = GitChange(repositoryRoot: worktree.url, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let directory = GitChange(repositoryRoot: worktree.url, path: "generated/", originalPath: nil,
            indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 101)
        let child = GitChange(repositoryRoot: worktree.url, path: "generated/child.txt", originalPath: nil, indexStatus: "?", workTreeStatus: "?")
        let probe = WorktreeChangesProbe(root: root, changes: [change, directory])
        let commits = (0..<80).map { makeTestCommit(hash: "worktree-\($0)", subject: "Commit \($0)") }
        let pages = WorktreeHistoryPageProbe(pages: [GitHistoryPage(commits: commits, nextCursor: "older", hasMore: true)])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(snapshotHandler: { probe.snapshot($0) },
            historyValue: GitHistorySnapshot(references: [], commits: Array(commits.prefix(30)), hasMore: true),
            worktreeHistoryProbe: pages, stageHandler: { probe.mutate($0, action: "stage") })),
            worktreesProvider: { _ in [worktree] }, repositoryRootsProvider: { [$0] },
            untrackedDirectoryChildrenProvider: { _ in [child] })
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset(); pages.releaseAll() }
        await feature.refreshGit(); await feature.refreshWorktrees(); await feature.inspectWorktree(worktree)
        await feature.loadMoreWorktreeHistory(for: worktree)
        let scoped = feature.commitFeature(for: worktree)
        await scoped.toggleUntrackedDirectory(directory)
        let reads = probe.snapshotRoots.count
        if useScoped { await scoped.stageChange(change) }
        else { await feature.setWorktreeStaging([change], staged: true, in: worktree) }
        #expect(Array(probe.snapshotRoots.dropFirst(reads)) == [worktree.url])
        #expect(scoped.gitChanges.first?.isStaged == true)
        #expect(scoped.gitChanges.contains(child) && scoped.expandedUntrackedDirectoryIDs == [directory.id])
        #expect(feature.gitWorktreeInspection?.changes.first?.isStaged == true)
        #expect(feature.gitWorktreeInspection?.commits == commits && feature.gitWorktreeInspection?.hasMoreCommits == true)
        #expect(pages.requests.count == 1 && pages.closed.isEmpty)
        #expect(feature.gitChanges.isEmpty && feature.gitRepositoryRoot == root)
    }

    @Test
    func rollbackConfirmationSurvivesDismissalAndStopsAtFirstFailure() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["checked.txt", "blocked.txt", "untouched.txt"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: "M", workTreeStatus: "M")
        }
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: changes),
            discardAllHandler: { change in
                GitProcessResult(arguments: ["discardAll", change.path], output: "Access denied",
                    exitCode: change.path == "blocked.txt" ? 1 : 0)
            }, unstageHandler: { change in
                GitProcessResult(arguments: ["unstage", change.path], output: "Access denied",
                    exitCode: change.path == "blocked.txt" ? 1 : 0)
            })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestRollbackChanges(changes, included: changes)
        let captured = try #require(feature.pendingRollbackSelection)
        feature.cancelRollbackChanges()
        #expect(feature.gitConsoleEntries.isEmpty)
        await feature.confirmRollbackChanges(captured)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [
            ["discardAll", "checked.txt"], ["discardAll", "blocked.txt"]
        ])
        #expect(!feature.isRollingBackChanges && feature.canRollbackChanges)
    }

    @Test(arguments: [false, true])
    func rollbackBlocksReentryAndRejectsLateWritesAfterReset(reset: Bool) async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["first.txt", "second.txt"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: "M", workTreeStatus: "M")
        }
        let gate = TestGitRunGate()
        let calls = CleanedPaths()
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: changes),
            discardAllHandler: { change in
                calls.append(change.path)
                gate.blockFirstRun()
                return GitProcessResult(arguments: ["discardAll", change.path], output: "", exitCode: 0)
            }, unstageHandler: { change in
                return GitProcessResult(arguments: ["unstage", change.path], output: "", exitCode: 0)
            })))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.requestRollbackChanges(changes, included: changes)
        let captured = try #require(feature.pendingRollbackSelection)
        let task = Task { await feature.confirmRollbackChanges(captured) }
        defer { gate.releaseFirstRun(); task.cancel(); feature.reset() }
        try #require(await gate.waitUntilFirstRunStarts())
        #expect(feature.isRollingBackChanges && !feature.canRollbackChanges && feature.changelistEditingDisabled)
        #expect(feature.beginSetStaging(changes, staged: true).isEmpty)
        await feature.confirmRollbackChanges(captured)
        if reset { feature.reset() } else { task.cancel() }
        gate.releaseFirstRun()
        try #require(await waitForGitTaskCompletion(task))
        #expect(!feature.isRollingBackChanges && !gate.didTimeOut)
        #expect(calls.paths == ["first.txt"])
        #expect(!feature.gitConsoleEntries.contains { $0.arguments.first == "unstage" })
    }

    @Test
    func rollbackRejectsOldDialogAfterReplacementOrWorkspaceSwitch() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            discardAllHandler: { target in GitProcessResult(arguments: ["discardAll", target.path], output: "", exitCode: 0) })))
        var workspace = root
        feature.configure(workspaceURLProvider: { workspace }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestRollbackChanges([change], included: [change])
        let old = try #require(feature.pendingRollbackSelection)
        feature.requestRollbackChanges([change], included: [])
        await feature.confirmRollbackChanges(old)
        #expect(feature.gitConsoleEntries.isEmpty)
        feature.requestRollbackChanges([change], included: [change])
        let switched = try #require(feature.pendingRollbackSelection)
        workspace = URL(fileURLWithPath: "/another-workspace")
        await feature.confirmRollbackChanges(switched)
        #expect(feature.gitConsoleEntries.isEmpty)
    }

    @Test
    func batchDiscardRetainsEachFallbackResultAndStopsAtTheFirstFailure() async {
        let root = URL(fileURLWithPath: "/workspace")
        let changes = ["first.txt", "blocked.txt", "untouched.txt"].map {
            GitChange(repositoryRoot: root, path: $0, originalPath: nil, indexStatus: " ", workTreeStatus: "M")
        }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            discardHandler: { change in
                GitProcessResult(arguments: ["discard", change.path],
                    output: change.path == "blocked.txt" ? "Access denied" : "",
                    exitCode: change.path == "blocked.txt" ? 1 : 0)
            }
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        await feature.discardChanges(changes)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "first.txt"], ["discard", "blocked.txt"]])
        #expect(feature.gitConsoleEntries.map(\.exitCode) == [0, 1])
        #expect(feature.gitConsoleEntries.allSatisfy { $0.state == .unconfirmed })
    }

    @Test
    func collapsingASummaryWhileARefreshListsItKeepsItCollapsed() async {
        let root = URL(fileURLWithPath: "/workspace")
        let source = GitChange(repositoryRoot: root, path: "src/App.swift", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let target = GitChange(repositoryRoot: root, path: "target/", originalPath: nil,
                               indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 200)
        let child = GitChange(repositoryRoot: root, path: "target/a.o", originalPath: nil,
                              indexStatus: "?", workTreeStatus: "?")
        let listing = UntrackedDirectoryListing(blockingFromCall: 2)
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations()),
            snapshotProvider: { _ in GitSnapshot(repositoryRoot: root, branch: "main", changes: [source, target]) },
            stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil },
            repositoryRootsProvider: { _ in [] },
            diffDocumentProvider: { _, _ in DiffDocument(rows: [], hunks: []) },
            untrackedDirectoryChildrenProvider: { _ in await listing.list([child]) }
        )
        defer { feature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        await feature.toggleUntrackedDirectory(target)
        #expect(feature.gitChanges.map(\.path) == ["src/App.swift", "target/", "target/a.o"])

        // The refresh lists `target/` again; the user collapses it meanwhile.
        let refresh = Task { await feature.refreshGit() }
        #expect(await listing.started.waitUntilOpen())
        await feature.toggleUntrackedDirectory(target)
        listing.release.open()
        await refresh.value

        #expect(feature.gitChanges.map(\.path) == ["src/App.swift", "target/"])
        #expect(feature.expandedUntrackedDirectoryIDs.isEmpty)
        #expect(feature.gitChangedFileCount == 201)
    }

    @Test
    func shelvingStopsBeforeCleaningWhenAnUntrackedSummaryCannotBeExported() async {
        // Shelve cleans `generated/` as a whole after saving, so a directory
        // patch Git could not export must stop it instead of losing files.
        let root = URL(fileURLWithPath: "/workspace")
        let source = GitChange(repositoryRoot: root, path: "src/App.swift", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let generated = GitChange(repositoryRoot: root, path: "generated/", originalPath: nil,
                                  indexStatus: "?", workTreeStatus: "?", untrackedFileCount: 101)
        func shelve(exportingDirectory: Bool) async -> (cleaned: [String], notifications: [String]) {
            let cleaned = CleanedPaths()
            let service = GitService(operations: TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [source, generated]),
                discardAllHandler: { change in
                    cleaned.append(change.path)
                    return GitProcessResult(arguments: ["clean", change.path], output: "", exitCode: 0)
                },
                diffPatchHandler: { pathspecs, _ in
                    pathspecs == ["generated/"] && !exportingDirectory ? nil : "patch \(pathspecs)"
                }
            ))
            let feature = GitFeatureModel(service: service,
                                          shelveService: ShelveService(storage: TestShelfStorage()))
            var notifications: [String] = []
            feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                              notify: { notifications.append($0) }, onStateRefreshed: {})
            await feature.refreshGit()
            await feature.shelveWorkingTree(message: "WIP")
            return (cleaned.paths, notifications)
        }

        let exported = await shelve(exportingDirectory: true)
        #expect(exported.cleaned == ["src/App.swift", "generated/"])

        let failed = await shelve(exportingDirectory: false)
        #expect(failed.cleaned.isEmpty)
        #expect(failed.notifications == ["Could not create a patch for generated/"])
    }

    @Test
    func discardingAnUntrackedSummaryWithItsListedContentsCleansTheDirectoryOnce() async {
        // Once `target/` is cleaned its listed files are gone, so discarding them
        // again would fail and stop the batch after the directory was removed.
        let root = URL(fileURLWithPath: "/workspace")
        func untracked(_ path: String, count: Int? = nil) -> GitChange {
            GitChange(repositoryRoot: root, path: path, originalPath: nil,
                      indexStatus: "?", workTreeStatus: "?", untrackedFileCount: count)
        }
        let selection = [untracked("target/", count: 200), untracked("target/a.o"),
                         untracked("target/debug/", count: 199), untracked("targets.txt")]
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            discardHandler: { change in
                GitProcessResult(arguments: ["discard", change.path], output: "", exitCode: 0)
            }
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        await feature.discardChanges(selection)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "target/"], ["discard", "targets.txt"]])
    }

    @Test
    func confirmedDiscardHunkSurvivesDialogDismissalAndReportsFailure() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(repositoryRoot: root, path: "target.txt", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let hunk = DiffHunk(id: "h1", header: "@@ -1 +1 @@", patch: "confirmed patch")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [change]),
            applyPatchHandler: { patch, _, mode in
                GitProcessResult(arguments: [mode, patch], output: "Patch no longer applies",
                                 standardOutput: "", standardError: "Patch no longer applies", exitCode: 1)
            }
        ))
        let feature = GitFeatureModel(service: service)
        var notifications: [String] = []
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false },
                          notify: { notifications.append($0) }, onStateRefreshed: {})
        await feature.refreshGit()
        feature.clearGitConsole()
        feature.requestDiscardHunk(hunk, in: change)
        let confirmed = try #require(feature.pendingDiscardHunk)
        feature.cancelDiscardHunk()
        #expect(feature.gitConsoleEntries.isEmpty)
        await feature.confirmDiscardHunk(confirmed)
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["discard", "confirmed patch"]])
        #expect(notifications == ["Patch no longer applies"])
        #expect(feature.pendingDiscardHunk == nil)
        #expect(feature.gitChanges == [change])
    }

    // MARK: Tag management

    @Test
    func gitTagDeletionCapabilityRequiresACommitTarget() {
        let commitTag = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            peelsToCommit: true,
            isCurrent: false,
            upstreamShortName: nil
        )
        let treeTag = GitReference(
            fullName: "refs/tags/tree-tag",
            shortName: "tree-tag",
            kind: .tag,
            peelsToCommit: false,
            isCurrent: false,
            upstreamShortName: nil
        )

        #expect(commitTag.supportsTagDeletion)
        #expect(!treeTag.supportsTagDeletion)
    }

    private func makeTagTestFeature(
        _ operations: TestGitOperations,
        onNotify: @escaping @MainActor (String) -> Void = { _ in }
    ) -> (GitFeatureModel, URL) {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: operations)
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: onNotify,
            onStateRefreshed: {}
        )
        return (feature, root)
    }

    private func makeTagCommit() -> GitCommit {
        GitCommit(
            hash: "abc123def456",
            shortHash: "abc123d",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026/08/30 10:00",
            subject: "Initial",
            decorations: ""
        )
    }

    @Test
    func gitTagNameValidationMatchesTheSharedContractFixture() throws {
        struct TagNames: Decodable {
            let valid: [String]
            let invalid: [String]
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LitheGitModuleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("shared/fixtures/git/tag-names.json")
        let fixture = try JSONDecoder().decode(TagNames.self, from: Data(contentsOf: fixtureURL))

        for name in fixture.valid {
            #expect(GitTagNameValidator.isValid(name), "expected valid tag name: \(name)")
        }
        for name in fixture.invalid {
            #expect(!GitTagNameValidator.isValid(name), "expected invalid tag name: \(name)")
        }
    }

    @Test
    func gitTagDeletionRequiresKindAndMessageToDescribeTheSameTagForm() {
        #expect(GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .lightweight,
            message: nil
        ).hasConsistentKindAndMessage)
        #expect(GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: ""
        ).hasConsistentKindAndMessage)
        #expect(!GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .lightweight,
            message: "release"
        ).hasConsistentKindAndMessage)
        #expect(!GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: nil
        ).hasConsistentKindAndMessage)
    }

    @Test
    func gitTagCreationSucceedsSilentlyForTheDialogAndNotifiesOnSuccess() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "v1.0", "abc123def456"], output: "", exitCode: 0)
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        // An empty result would mean the dialog shows a generic failure, so a
        // successful create must return nil and notify instead.
        let error = await feature.createTag(at: makeTagCommit(), name: "v1.0", message: "")

        #expect(error == nil)
        #expect(notifications == ["Created tag v1.0"])
    }

    @Test
    func gitTagCreationReturnsTheFailureToTheDialogWithoutNotifying() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: [])
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        let error = await feature.createTag(at: makeTagCommit(), name: "v1.0", message: "")

        #expect(error == "Rust Core Git operation failed")
        #expect(notifications.isEmpty)
    }

    @Test
    func gitTagDeletionKeepsARestorableSessionRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .annotated,
                        message: "release"
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)

        #expect(feature.recentlyDeletedTag == GitTagDeletion(
            name: "v1.0",
            deletedTarget: "abc123def456",
            kind: .annotated,
            message: "release"
        ))
        #expect(notifications == ["Deleted tag v1.0"])

        feature.dismissDeletedTagBanner()
        #expect(feature.recentlyDeletedTag == nil)
    }

    @Test
    func gitTagDeletionFailureRecordsNothingAndNotifiesTheError() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "The tag 'v1.0' does not exist",
                    exitCode: 1
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)

        #expect(feature.recentlyDeletedTag == nil)
        #expect(notifications == ["The tag 'v1.0' does not exist"])
    }

    @Test
    func gitTagDeletionFailureKeepsThePreviousRecoveryRecord() async {
        var notifications: [String] = []
        let results = GitProcessResultQueue([
            GitProcessResult(
                arguments: ["tag", "-d", "v1.0"],
                output: "Deleted tag 'v1.0'\n",
                exitCode: 0,
                tagDeletion: GitTagDeletion(
                    name: "v1.0",
                    deletedTarget: "abc123def456",
                    kind: .lightweight,
                    message: nil
                )
            ),
            GitProcessResult(
                arguments: ["tag", "-d", "missing"],
                output: "The tag 'missing' does not exist",
                exitCode: 1
            )
        ])
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResults: results
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        for name in ["v1.0", "missing"] {
            await feature.deleteTag(GitReference(
                fullName: "refs/tags/\(name)",
                shortName: name,
                kind: .tag,
                isCurrent: false,
                upstreamShortName: nil
            ))
        }

        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(notifications == ["Deleted tag v1.0", "The tag 'missing' does not exist"])
    }

    @Test
    func gitTagRestoreReplaysRecordedNameTargetAndMessage() async {
        var notifications: [String] = []
        let recorder = TagCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "-a", "v1.0", "-m", "release", "abc123def456"], output: "", exitCode: 0),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .annotated,
                        message: "release"
                    )
                ),
                tagCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        // Exactly one delete and one restore create must have run, and the
        // restore must replay exactly the recorded deletion record so the
        // rebuilt annotated tag points at the original commit with its
        // message. The delete itself records no revision.
        #expect(recorder.recorded.count == 2)
        #expect(recorder.recorded.first?.name == "v1.0")
        #expect(recorder.recorded.last == TagCallRecorder.Call(
            name: "v1.0",
            revision: "abc123def456",
            message: "release"
        ))
        #expect(feature.recentlyDeletedTag == nil)
        #expect(notifications == ["Deleted tag v1.0", "Restored tag v1.0"])
    }

    @Test
    func gitTagRestoreFailureKeepsTheRecordForARetry() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(
                    arguments: ["tag", "v1.0", "abc123def456"],
                    output: "A tag named 'v1.0' already exists",
                    exitCode: 1
                ),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: nil
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        // The user can retry after fixing the conflict, or close the banner.
        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(notifications == ["Deleted tag v1.0", "A tag named 'v1.0' already exists"])
    }

    @Test
    func gitTagRestoreRejectsAnInconsistentRecoveryRecord() async {
        var notifications: [String] = []
        let recorder = TagCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createTagResult: GitProcessResult(arguments: ["tag", "v1.0"], output: "", exitCode: 0),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: "unexpected annotation"
                    )
                ),
                tagCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        await feature.restoreRecentlyDeletedTag()

        #expect(feature.recentlyDeletedTag == nil)
        #expect(recorder.recorded.count == 1, "invalid recovery data must not issue createTag")
        #expect(notifications == ["Deleted tag v1.0", "The deleted tag recovery record is invalid"])
    }

    @Test
    func gitFeatureModelResetClearsTheRestorableTagRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteTagResult: GitProcessResult(
                    arguments: ["tag", "-d", "v1.0"],
                    output: "Deleted tag 'v1.0'\n",
                    exitCode: 0,
                    tagDeletion: GitTagDeletion(
                        name: "v1.0",
                        deletedTarget: "abc123def456",
                        kind: .lightweight,
                        message: nil
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteTag(reference)
        #expect(feature.recentlyDeletedTag != nil)

        // Project close resets the model; the deletion record must not survive
        // into the next session.
        feature.reset()
        #expect(feature.recentlyDeletedTag == nil)
    }

    // MARK: Branch deletion restore

    @Test
    func gitBranchDeletionKeepsARestorableSessionRecord() async {
        var notifications: [String] = []
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResult: GitProcessResult(
                    arguments: ["branch", "-d", "--", "feature/short-lived"],
                    output: "Deleted branch feature/short-lived\n",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    )
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)

        #expect(feature.recentlyDeletedBranch == GitBranchDeletion(
            name: "feature/short-lived",
            deletedTarget: "abc123def456"
        ))
        #expect(feature.gitConsoleEntries.map(\.arguments) == [["branch", "-d", "--", "feature/short-lived"]])
        #expect(notifications == ["Deleted branch feature/short-lived"])

        feature.dismissDeletedBranchBanner()
        #expect(feature.recentlyDeletedBranch == nil)
    }

    @Test
    func gitBranchConfigCleanupFailureKeepsTheRestorableDeletionRecord() async {
        var notifications: [String] = []
        let warning = "Could not remove configuration for deleted branch 'feature/short-lived'"
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResult: GitProcessResult(
                    arguments: ["update-ref", "-d", "refs/heads/feature/short-lived"],
                    output: "",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    ),
                    warnings: [GitOperationWarning(
                        code: "branch_config_cleanup_failed",
                        message: warning
                    )]
                )
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)

        #expect(feature.recentlyDeletedBranch == GitBranchDeletion(
            name: "feature/short-lived",
            deletedTarget: "abc123def456"
        ))
        #expect(notifications == ["Deleted branch feature/short-lived: \(warning)"])
    }

    @Test
    func gitBranchDeletionFailureKeepsThePreviousRecoveryRecord() async {
        var notifications: [String] = []
        let results = GitProcessResultQueue([
            GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/a"],
                output: "Deleted branch feature/a\n",
                exitCode: 0,
                branchDeletion: GitBranchDeletion(name: "feature/a", deletedTarget: "abc123def456")
            ),
            GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/b"],
                output: "The branch 'feature/b' does not exist",
                exitCode: 1
            )
        ])
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                deleteBranchResults: results
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()

        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/a",
            shortName: "feature/a",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))
        #expect(feature.recentlyDeletedBranch?.name == "feature/a")

        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/b",
            shortName: "feature/b",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))

        #expect(feature.recentlyDeletedBranch?.name == "feature/a")
        #expect(notifications == ["Deleted branch feature/a", "The branch 'feature/b' does not exist"])
    }

    @Test
    func gitTagAndBranchRecoveryRecordsCanCoexist() async {
        let (feature, _) = makeTagTestFeature(TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
            deleteTagResult: GitProcessResult(
                arguments: ["tag", "-d", "v1.0"],
                output: "Deleted tag 'v1.0'\n",
                exitCode: 0,
                tagDeletion: GitTagDeletion(
                    name: "v1.0",
                    deletedTarget: "abc123def456",
                    kind: .lightweight,
                    message: nil
                )
            ),
            deleteBranchResult: GitProcessResult(
                arguments: ["branch", "-d", "--", "feature/a"],
                output: "Deleted branch feature/a\n",
                exitCode: 0,
                branchDeletion: GitBranchDeletion(name: "feature/a", deletedTarget: "abc123def456")
            )
        ))
        await feature.refreshGit()

        await feature.deleteTag(GitReference(
            fullName: "refs/tags/v1.0",
            shortName: "v1.0",
            kind: .tag,
            isCurrent: false,
            upstreamShortName: nil
        ))
        await feature.deleteBranch(GitReference(
            fullName: "refs/heads/feature/a",
            shortName: "feature/a",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        ))

        #expect(feature.recentlyDeletedTag?.name == "v1.0")
        #expect(feature.recentlyDeletedBranch?.name == "feature/a")
    }

    /// IDEA's Update on a branch that is not checked out fast-forwards it from
    /// its upstream in place. Git prints refusals in the user's locale, so the
    /// message comes from the branch's own counts, never from parsing output.
    @Test(arguments: [
        (0, GitProcessResult(arguments: ["fetch"], output: "", exitCode: 0), "Updated feature/a"),
        (1, GitProcessResult(arguments: ["fetch"], output: " ! [已拒绝]  feature/a -> feature/a  (非快进)\n", exitCode: 1),
         "feature/a has diverged from origin/feature/a. Check it out to merge or rebase."),
        (0, GitProcessResult(arguments: ["fetch"], output: "fatal: couldn't find remote ref feature/a\n", exitCode: 128),
         "fatal: couldn't find remote ref feature/a")
    ])
    func nonCurrentBranchUpdateFastForwardsInPlace(ahead: Int, result: GitProcessResult, message: String) async {
        var notifications: [String] = []
        let recorder = BranchCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                updateBranchResult: result,
                branchCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        await feature.updateBranch(GitReference(fullName: "refs/heads/feature/a", shortName: "feature/a", kind: .local,
                                                isCurrent: false, upstreamShortName: "origin/feature/a",
                                                ahead: ahead, behind: 2))

        #expect(recorder.recorded == [BranchCallRecorder.Call(name: "update", reference: "refs/heads/feature/a", checkout: false)])
        #expect(notifications == [message])
        #expect(!feature.isPerformingBranchOperation)
    }

    @Test
    func nonCurrentBranchCheckedOutInAnotherWorktreeIsNotFetchedInto() async {
        var notifications: [String] = []
        let recorder = BranchCallRecorder()
        let root = URL(fileURLWithPath: "/workspace")
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
                branchCallRecorder: recorder
            )),
            worktreesProvider: { _ in [makeTestWorktree(path: "/workspace-feature", branch: "feature/a")] }
        )
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { notifications.append($0) },
            onStateRefreshed: {}
        )
        await feature.refreshGit()
        // The Worktrees tab never loaded, so the published list is empty.
        #expect(feature.gitWorktrees.isEmpty)
        await feature.updateBranch(GitReference(fullName: "refs/heads/feature/a", shortName: "feature/a", kind: .local,
                                                isCurrent: false, upstreamShortName: "origin/feature/a", behind: 2))

        #expect(recorder.recorded.isEmpty)
        #expect(notifications == ["feature/a is checked out in another worktree. Update it there."])
    }

    @Test
    func nonCurrentBranchWithoutUpstreamIsNotUpdated() async {
        var notifications: [String] = []
        let recorder = BranchCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                branchCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        await feature.updateBranch(GitReference(fullName: "refs/heads/local-only", shortName: "local-only", kind: .local,
                                                isCurrent: false, upstreamShortName: nil))

        #expect(recorder.recorded.isEmpty)
        #expect(notifications == ["local-only tracks no remote branch"])
    }

    @Test
    func gitBranchRestoreReplaysRecordedNameAndTarget() async {
        var notifications: [String] = []
        let recorder = BranchCallRecorder()
        let (feature, _) = makeTagTestFeature(
            TestGitOperations(
                snapshotValue: GitSnapshot(repositoryRoot: URL(fileURLWithPath: "/workspace"), branch: "main", changes: []),
                createBranchResult: GitProcessResult(arguments: ["branch", "feature/short-lived", "abc123def456"], output: "", exitCode: 0),
                deleteBranchResult: GitProcessResult(
                    arguments: ["branch", "-d", "--", "feature/short-lived"],
                    output: "Deleted branch feature/short-lived\n",
                    exitCode: 0,
                    branchDeletion: GitBranchDeletion(
                        name: "feature/short-lived",
                        deletedTarget: "abc123def456"
                    )
                ),
                branchCallRecorder: recorder
            ),
            onNotify: { notifications.append($0) }
        )
        await feature.refreshGit()
        let reference = GitReference(
            fullName: "refs/heads/feature/short-lived",
            shortName: "feature/short-lived",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )

        await feature.deleteBranch(reference)
        await feature.restoreRecentlyDeletedBranch()

        // The restore replays createBranch against the recorded commit without
        // checking the branch out.
        #expect(Array(recorder.recorded.suffix(1)) == [
            BranchCallRecorder.Call(name: "feature/short-lived", reference: "abc123def456", checkout: false)
        ])
        #expect(feature.recentlyDeletedBranch == nil)
        #expect(notifications == ["Deleted branch feature/short-lived", "Restored branch feature/short-lived"])

        // Project close drops the restorable record as well.
        feature.reset()
        #expect(feature.recentlyDeletedBranch == nil)
    }

    @Test
    func gitServicePreservesExecutedArgumentsAndWorkingDirectory() async {        let root = URL(fileURLWithPath: "/workspace")
        let change = GitChange(
            repositoryRoot: root,
            path: "README.md",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let service = GitService(operations: TestGitOperations(
            stageResult: GitProcessResult(
                arguments: ["add", "--", "README.md"],
                output: "staged",
                exitCode: 0,
                warnings: [
                    GitOperationWarning(
                        code: "git_follow_up_failed",
                        message: "The main operation succeeded",
                        details: "follow-up diagnostic"
                    )
                ]
            )
        ))

        let result = await service.stage(change)

        #expect(result.workingDirectory == root)
        #expect(result.arguments == ["add", "--", "README.md"])
        #expect(result.output == "staged")
        #expect(result.succeeded)
        #expect(result.warnings == [
            GitOperationWarning(
                code: "git_follow_up_failed",
                message: "The main operation succeeded",
                details: "follow-up diagnostic"
            )
        ])
    }

    @Test
    func gitConsoleLoadsGitVersionOnlyOnce() async {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.loadGitConsoleIfNeeded()
        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.first?.workingDirectory == root)
        #expect(feature.gitConsoleEntries.first?.arguments == ["version"])
        #expect(feature.gitConsoleEntries.first?.output == "git version 2.55.0\n")
    }

    @Test
    func commitSelectionLoadsFilesWithoutSelectingTheFirstFile() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:00:00+08:00",
            subject: "Selected commit",
            decorations: ""
        )
        let nextCommit = GitCommit(
            hash: "2222222222222222",
            shortHash: "2222222",
            parentHashes: [commit.hash],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:01:00+08:00",
            subject: "Next commit",
            decorations: ""
        )
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesValue: files
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectGitCommit(commit)

        #expect(feature.selectedGitCommit == commit)
        #expect(feature.selectedGitCommitFiles == files)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        #expect(feature.selectedGitCommitFile == nil)

        feature.previewGitCommitSelection(nextCommit)

        #expect(feature.selectedGitCommit == nextCommit)
        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.selectedGitCommitFilesLoadState == .loading)
        #expect(feature.selectedGitCommitFile == nil)
        #expect(feature.selectedGitCommitDiffContext == nil)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func failedCommitFileReadIsNotCachedAndRetryRecovers() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = makeTestCommit(hash: "1111111111111111", subject: "Retry commit")
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let filesGate = GitFilesLoadGate(results: [nil, files])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesGate: filesGate
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        feature.previewGitCommitSelection(commit)
        #expect(feature.selectedGitCommitFilesLoadState == .loading)

        let failedLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: commit)
        }
        defer { failedLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))
        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await waitForGitTaskCompletion(failedLoad))

        #expect(feature.selectedGitCommitFiles.isEmpty)
        #expect(feature.selectedGitCommitFilesLoadState == .failed)

        let retryLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: commit)
        }
        defer { retryLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(1))
        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        try #require(await waitForGitTaskCompletion(retryLoad))

        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callHashes == [commit.hash, commit.hash])
        #expect(feature.selectedGitCommitFiles == files)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func repeatedCommitSelectionReusesCachedFilesAndResetInvalidatesCache() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = GitCommit(
            hash: "1111111111111111",
            shortHash: "1111111",
            parentHashes: [],
            authorName: "Ada Lovelace",
            authorEmail: "ada@example.com",
            date: "2026-08-28T16:00:00+08:00",
            subject: "Cached commit",
            decorations: ""
        )
        let files = [GitCommitFile(status: "M", path: "README.md")]
        let filesRecorder = GitFilesCallRecorder()
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesValue: files,
            filesRecorder: filesRecorder
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.selectGitCommit(commit)
        await feature.selectGitCommit(commit)

        #expect(filesRecorder.callCount == 1)
        #expect(feature.selectedGitCommitFiles == files)

        feature.reset()
        await feature.refreshGit()
        await feature.selectGitCommit(commit)

        #expect(filesRecorder.callCount == 2)
        #expect(feature.selectedGitCommitFiles == files)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func selectedAndQueryDemandCoalescesWhilePrefetchRemainsBounded() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let blocker = makeTestCommit(hash: "1111111111111111", subject: "Blocker")
        let shared = makeTestCommit(hash: "2222222222222222", subject: "Shared demand")
        let trailing = makeTestCommit(hash: "3333333333333333", subject: "Trailing prefetch")
        let blockerFiles = [GitCommitFile(status: "M", path: "blocker.txt")]
        let sharedFiles = [GitCommitFile(status: "A", path: "shared.txt")]
        let trailingFiles = [GitCommitFile(status: "D", path: "trailing.txt")]
        let filesGate = GitFilesLoadGate(results: [blockerFiles, sharedFiles, trailingFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            filesGate: filesGate
        ))
        let loader = GitCommitFilesLoader(service: service)

        loader.replacePrefetchCandidates([blocker, shared], at: root)
        try #require(await filesGate.waitUntilCallStarts(0))

        let queryLoad = Task { @MainActor in
            await loader.loadQueryFiles(for: shared, at: root)
        }
        defer { queryLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(1))

        let selectedLoad = loader.requestSelectedFiles(for: shared, at: root)
        defer { selectedLoad.cancel() }
        loader.replacePrefetchCandidates([trailing], at: root)

        #expect(filesGate.callHashes == [blocker.hash, shared.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        let queryOutcome = try #require(await waitForGitCommitFilesOutcome(queryLoad))
        let selectedOutcome = try #require(await waitForGitCommitFilesOutcome(selectedLoad))
        #expect(queryOutcome == .ready(sharedFiles))
        #expect(selectedOutcome == .ready(sharedFiles))

        // The active speculative read keeps the next prefetch queued, so the
        // loader never spends both physical slots on cache warming.
        #expect(filesGate.callCount == 2)
        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await filesGate.waitUntilCallStarts(2))
        #expect(filesGate.callHashes == [blocker.hash, shared.hash, trailing.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)
        filesGate.releaseCall(2)
        try #require(await filesGate.waitUntilCallFinishes(2))

        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callCount == 3)
        #expect(loader.cachedFiles(for: shared, at: root) == sharedFiles)
        try #require(await waitForGitWorkToBecomeIdle {
            loader.hasActiveWork
        })
    }

    @Test
    func latestSelectionStartsBeforeBlockedPreviousSelectionFinishes() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let previous = makeTestCommit(hash: "1111111111111111", subject: "Previous")
        let latest = makeTestCommit(hash: "2222222222222222", subject: "Latest")
        let previousFiles = [GitCommitFile(status: "M", path: "previous.txt")]
        let latestFiles = [GitCommitFile(status: "A", path: "latest.txt")]
        let filesGate = GitFilesLoadGate(results: [previousFiles, latestFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: []),
            filesGate: filesGate
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        feature.previewGitCommitSelection(previous)
        let previousLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: previous)
        }
        defer { previousLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))

        feature.previewGitCommitSelection(latest)
        let latestLoad = Task { @MainActor in
            await feature.loadGitCommitFiles(for: latest)
        }
        defer { latestLoad.cancel() }

        // The second selection must consume the free physical slot instead of
        // waiting for the stale synchronous read to return.
        try #require(await filesGate.waitUntilCallStarts(1))
        #expect(filesGate.callHashes == [previous.hash, latest.hash])
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        try #require(await waitForGitTaskCompletion(latestLoad))
        #expect(feature.selectedGitCommit == latest)
        #expect(feature.selectedGitCommitFiles == latestFiles)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)

        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        try #require(await waitForGitTaskCompletion(previousLoad))
        #expect(feature.selectedGitCommit == latest)
        #expect(feature.selectedGitCommitFiles == latestFiles)
        #expect(feature.selectedGitCommitFilesLoadState == .ready)
        #expect(!filesGate.didTimeOut)
        try #require(await waitForGitWorkToBecomeIdle {
            feature.hasActiveModuleWork
        })
    }

    @Test
    func resetSupersedesStaleGenerationAndRetriesWithinPhysicalLimit() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let commit = makeTestCommit(hash: "1111111111111111", subject: "Reset commit")
        let staleFiles = [GitCommitFile(status: "M", path: "stale.txt")]
        let replacementFiles = [GitCommitFile(status: "A", path: "replacement.txt")]
        let filesGate = GitFilesLoadGate(results: [staleFiles, replacementFiles])
        defer { filesGate.releaseAll() }
        let service = GitService(operations: TestGitOperations(
            filesGate: filesGate
        ))
        let loader = GitCommitFilesLoader(service: service)

        let staleLoad = loader.requestSelectedFiles(for: commit, at: root)
        defer { staleLoad.cancel() }
        try #require(await filesGate.waitUntilCallStarts(0))

        loader.reset()
        let replacementLoad = loader.requestSelectedFiles(for: commit, at: root)
        defer { replacementLoad.cancel() }

        let staleOutcome = try #require(await waitForGitCommitFilesOutcome(staleLoad))
        #expect(staleOutcome == .superseded)
        try #require(await filesGate.waitUntilCallStarts(1))
        #expect(filesGate.maximumConcurrentCalls == 2)

        filesGate.releaseCall(1)
        try #require(await filesGate.waitUntilCallFinishes(1))
        let replacementOutcome = try #require(await waitForGitCommitFilesOutcome(replacementLoad))
        #expect(replacementOutcome == .ready(replacementFiles))

        filesGate.releaseCall(0)
        try #require(await filesGate.waitUntilCallFinishes(0))
        #expect(!filesGate.didTimeOut)
        #expect(filesGate.callHashes == [commit.hash, commit.hash])
        #expect(loader.cachedFiles(for: commit, at: root) == replacementFiles)
        try #require(await waitForGitWorkToBecomeIdle {
            loader.hasActiveWork
        })
    }

    @Test
    func commitFilesPrefetchPrioritizesTheNextOlderAndNewerCommits() {
        let commits = (0..<6).map { index in
            let hash = String(index)
            return GitCommit(
                hash: hash,
                shortHash: hash,
                parentHashes: [],
                authorName: "Test Author",
                authorEmail: "author@example.com",
                date: "2026-08-28T16:00:00+08:00",
                subject: hash,
                decorations: ""
            )
        }

        let candidates = GitCommitFilesPrefetchPlan.candidates(
            in: commits,
            centeredAt: "2",
            radius: 3
        )

        #expect(candidates.map(\.hash) == ["3", "1", "4", "0", "5"])
        #expect(GitCommitFilesPrefetchPlan.candidates(
            in: commits,
            centeredAt: "missing",
            radius: 3
        ).isEmpty)
    }

    @Test
    func clearingGitConsoleDoesNotTriggerInitialLoadAgain() async {
        let root = URL(fileURLWithPath: "/workspace")
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
        ))
        let feature = GitFeatureModel(service: service)
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        await feature.loadGitConsoleIfNeeded()
        feature.clearGitConsole()
        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.isEmpty)
    }

    @Test
    func switchingRepositoriesDiscardsStaleInitialGitConsoleOutput() async throws {
        let firstRoot = URL(fileURLWithPath: "/first-workspace")
        let secondRoot = URL(fileURLWithPath: "/second-workspace")
        let runGate = TestGitRunGate()
        let service = GitService(operations: TestGitOperations(runGate: runGate))
        let feature = GitFeatureModel(
            service: service,
            snapshotProvider: { root in
                GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
            }
        )
        var workspaceURL = firstRoot
        feature.configure(
            workspaceURLProvider: { workspaceURL },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        await feature.refreshGit()
        let initialLoad = Task { @MainActor in await feature.loadGitConsoleIfNeeded() }
        defer {
            initialLoad.cancel()
            runGate.releaseFirstRun()
        }
        try #require(await runGate.waitUntilFirstRunStarts())
        workspaceURL = secondRoot
        await feature.refreshGit()
        runGate.releaseFirstRun()
        try #require(await waitForGitTaskCompletion(initialLoad))
        #expect(!runGate.didTimeOut)

        #expect(feature.gitConsoleEntries.isEmpty)

        await feature.loadGitConsoleIfNeeded()

        #expect(feature.gitConsoleEntries.count == 1)
        #expect(feature.gitConsoleEntries.first?.workingDirectory == secondRoot)
    }

    @Test
    func worktreeInspectionPublishesHistoryBeforeStatusScanFinishes() async throws {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let change = GitChange(
            repositoryRoot: URL(fileURLWithPath: worktree.path),
            path: "Sources/App.swift",
            originalPath: nil,
            indexStatus: " ",
            workTreeStatus: "M"
        )
        let commit = makeTestCommit(hash: "history-commit", subject: "Show history first")
        let snapshotGate = GitModuleTestGate()
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(
                repositoryRoot: URL(fileURLWithPath: worktree.path),
                branch: "feature/history",
                changes: [change]
            ),
            historyValue: GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [commit],
                hasMore: false
            ),
            snapshotGate: snapshotGate
        ))
        let feature = GitFeatureModel(service: service)
        let inspectionTask = Task { @MainActor in
            await feature.inspectWorktree(worktree)
        }
        defer {
            inspectionTask.cancel()
            snapshotGate.open()
        }

        let partialInspection = await waitForGitWorktreeInspection(feature)
        try #require(partialInspection != nil)
        #expect(partialInspection?.commits == [commit])
        #expect(partialInspection?.hasLoadedChanges == false)
        #expect(partialInspection?.changes.isEmpty == true)

        snapshotGate.open()
        try #require(await waitForGitTaskCompletion(inspectionTask))
        #expect(feature.gitWorktreeInspection?.changes == [change])
        #expect(feature.gitWorktreeInspection?.hasLoadedChanges == true)
    }

    @Test
    func worktreeHistoryAppendsBoundedCursorPagesAndStopsOnNoProgress() async {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let commits = (0..<160).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let initial = GitHistorySnapshot(references: [], commits: Array(commits.prefix(30)), hasMore: true)
        let probe = WorktreeHistoryPageProbe(pages: [
            GitHistoryPage(commits: Array(commits.prefix(80)), nextCursor: "older-80", hasMore: true),
            GitHistoryPage(commits: Array(commits[79..<130]), nextCursor: "older-130", hasMore: true),
            GitHistoryPage(commits: [commits[129], commits[129]], nextCursor: "no-progress", hasMore: true)
        ])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            historyValue: initial, worktreeHistoryProbe: probe)))
        defer { feature.reset(); probe.releaseAll() }
        await feature.inspectWorktree(worktree)
        #expect(probe.requests.isEmpty, "Inspection must not eagerly warm a second history window")
        for _ in 0..<4 { await feature.loadMoreWorktreeHistory(for: worktree, automatically: true) }
        #expect(probe.requests.map(\.cursor) == [nil, "older-80", "older-130"])
        #expect(probe.requests.map(\.limit) == [80, 50, 50])
        #expect(probe.requests.allSatisfy { $0.reference?.fullName == worktree.branch })
        #expect(feature.gitWorktreeInspection?.commits == Array(commits.prefix(130)))
        #expect(feature.gitWorktreeInspection?.hasMoreCommits == false)
        #expect(probe.closed == ["no-progress"])
    }

    @Test
    func worktreeHistoryClampsTheFinalCursorPageToTheLoadedWindowLimit() async {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let commits = (0..<5_000).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let probe = WorktreeHistoryPageProbe(pages: [
            GitHistoryPage(commits: Array(commits.prefix(4_990)), nextCursor: "last-page", hasMore: true),
            GitHistoryPage(commits: Array(commits.suffix(10)), nextCursor: "beyond-budget", hasMore: true)
        ])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            historyValue: GitHistorySnapshot(references: [], commits: Array(commits.prefix(4_940)), hasMore: true),
            worktreeHistoryProbe: probe)))
        defer { feature.reset(); probe.releaseAll() }
        await feature.inspectWorktree(worktree)
        for _ in 0..<3 { await feature.loadMoreWorktreeHistory(for: worktree, automatically: true) }
        #expect(probe.requests.map(\.limit) == [4_990, 10])
        #expect(feature.gitWorktreeInspection?.commits.count == 5_000)
        #expect(feature.gitWorktreeInspection?.hasMoreCommits == false)
        #expect(probe.closed == ["beyond-budget"])
    }

    @Test
    func worktreeHistoryFailurePausesUntilExplicitRetryAndClosesCursor() async {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let commits = (0..<4).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let probe = WorktreeHistoryPageProbe(pages: [nil,
            GitHistoryPage(commits: [commits[0], commits[1], commits[1]], nextCursor: "retry-page", hasMore: true)])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            historyValue: GitHistorySnapshot(references: [], commits: [commits[0]], hasMore: true),
            worktreeHistoryProbe: probe)))
        defer { feature.reset(); probe.releaseAll() }
        await feature.inspectWorktree(worktree)
        await feature.loadMoreWorktreeHistory(for: worktree, automatically: true)
        #expect(feature.worktreeHistoryPageFailed)
        #expect(feature.gitWorktreeInspection?.commits == [commits[0]])
        await feature.loadMoreWorktreeHistory(for: worktree, automatically: true)
        #expect(probe.requests.count == 1)
        await feature.loadMoreWorktreeHistory(for: worktree)
        #expect(!feature.worktreeHistoryPageFailed)
        #expect(feature.gitWorktreeInspection?.commits == Array(commits.prefix(2)))
        #expect(probe.requests.map(\.cursor) == [nil, nil], "A consumed failed cursor cannot be retried")
        feature.cancelWorktreeHistoryLoading()
        #expect(probe.closed == ["retry-page"])
        #expect(!feature.isLoadingMoreWorktreeHistory)
    }

    @Test
    func worktreeHistoryDeduplicatesInflightAndRejectsCancelledSelection() async throws {
        let old = makeTestWorktree(path: "/workspace-old", branch: "feature/old")
        let new = makeTestWorktree(path: "/workspace-new", branch: "feature/new")
        let commit = makeTestCommit(hash: "initial", subject: "Initial")
        let probe = WorktreeHistoryPageProbe(pages: [
            GitHistoryPage(commits: [commit, makeTestCommit(hash: "stale", subject: "Stale")],
                           nextCursor: "stale-cursor", hasMore: true)
        ], blockedIndices: [0])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            historyValue: GitHistorySnapshot(references: [], commits: [commit], hasMore: true),
            worktreeHistoryProbe: probe)))
        defer { feature.reset(); probe.releaseAll() }
        await feature.inspectWorktree(old)
        let task = Task { @MainActor in await feature.loadMoreWorktreeHistory(for: old, automatically: true) }
        defer { task.cancel(); probe.releaseAll() }
        try #require(await probe.started.waitUntilOpen())
        await feature.loadMoreWorktreeHistory(for: old, automatically: true)
        #expect(probe.requests.count == 1)
        await feature.inspectWorktree(new)
        #expect(probe.cancelled.count == 1)
        probe.releaseAll()
        try #require(await waitForGitTaskCompletion(task))
        #expect(feature.gitWorktreeInspection?.worktreeID == new.id)
        #expect(feature.gitWorktreeInspection?.commits == [commit])
        #expect(probe.closed == ["stale-cursor"])
        #expect(!feature.isLoadingMoreWorktreeHistory)
        #expect(!probe.timedOut)
    }

    @Test
    func worktreeHistoryAppendPreservesPendingChangesScan() async throws {
        let worktree = makeTestWorktree(path: "/workspace-feature", branch: "feature/history")
        let commits = (0..<3).map { makeTestCommit(hash: "commit-\($0)", subject: "Commit \($0)") }
        let change = GitChange(repositoryRoot: worktree.url, path: "App.swift", originalPath: nil,
                               indexStatus: " ", workTreeStatus: "M")
        let snapshotGate = GitModuleTestGate()
        let probe = WorktreeHistoryPageProbe(pages: [GitHistoryPage(commits: commits, nextCursor: nil, hasMore: false)])
        let feature = GitFeatureModel(service: GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: worktree.url, branch: "feature/history", changes: [change]),
            historyValue: GitHistorySnapshot(references: [], commits: [commits[0]], hasMore: true),
            worktreeHistoryProbe: probe, snapshotGate: snapshotGate)))
        let task = Task { @MainActor in await feature.inspectWorktree(worktree) }
        defer { task.cancel(); snapshotGate.open(); probe.releaseAll(); feature.reset() }
        try #require(await waitForGitWorktreeInspection(feature) != nil)
        await feature.loadMoreWorktreeHistory(for: worktree, automatically: true)
        #expect(feature.gitWorktreeInspection?.hasLoadedChanges == false)
        snapshotGate.open()
        try #require(await waitForGitTaskCompletion(task))
        #expect(feature.gitWorktreeInspection?.commits == commits)
        #expect(feature.gitWorktreeInspection?.changes == [change])
        #expect(feature.gitWorktreeInspection?.hasLoadedChanges == true)
    }

    @Test
    func staleWorktreeInspectionCannotClearNewLoadingState() async throws {
        let oldWorktree = makeTestWorktree(path: "/workspace-old", branch: "feature/old")
        let newWorktree = makeTestWorktree(path: "/workspace-new", branch: "feature/new")
        let controller = GitHistoryLoadController(results: [
            GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [makeTestCommit(hash: "old-history", subject: "Old")],
                hasMore: false
            ),
            GitHistorySnapshot(
                references: [],
                recentReferences: [],
                commits: [makeTestCommit(hash: "new-history", subject: "New")],
                hasMore: false
            )
        ])
        let feature = GitFeatureModel(service: GitService(
            operations: TestGitOperations(historyController: controller)
        ))
        let oldInspection = Task { @MainActor in
            await feature.inspectWorktree(oldWorktree)
        }
        defer {
            oldInspection.cancel()
            controller.releaseAll()
        }

        try #require(await controller.waitUntilCallStarts(0))
        let newInspection = Task { @MainActor in
            await feature.inspectWorktree(newWorktree)
        }
        defer { newInspection.cancel() }
        try #require(await controller.waitUntilCallStarts(1))
        #expect(feature.gitWorktreeInspectionLoadState == .loading)

        controller.releaseCall(0)
        try #require(await waitForGitTaskCompletion(oldInspection))
        #expect(feature.gitWorktreeInspectionLoadState == .loading)

        controller.releaseCall(1)
        try #require(await waitForGitTaskCompletion(newInspection))
        #expect(feature.gitWorktreeInspectionLoadState == .ready)
        #expect(feature.gitWorktreeInspection?.worktreeID == newWorktree.id)
        #expect(!controller.didTimeOut)
    }

    @Test
    func newerWorktreeRefreshWinsWhenAnOlderRequestFinishesLast() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let oldWorktree = makeTestWorktree(path: "/workspace-old", branch: "feature/old")
        let newWorktree = makeTestWorktree(path: "/workspace-new", branch: "feature/new")
        let loader = GitWorktreeLoadController(results: [[oldWorktree], [newWorktree]])
        let feature = GitFeatureModel(
            service: GitService(operations: TestGitOperations()),
            snapshotProvider: { root in
                GitSnapshot(repositoryRoot: root, branch: "main", changes: [])
            },
            worktreesProvider: { root in await loader.load(root) }
        )
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )
        await feature.refreshGit()

        let firstRefresh = Task { @MainActor in await feature.refreshWorktrees() }
        try #require(await loader.waitUntilCallStarts(0))
        let secondRefresh = Task { @MainActor in await feature.refreshWorktrees() }
        defer {
            firstRefresh.cancel()
            secondRefresh.cancel()
            loader.releaseAll()
        }
        try #require(await loader.waitUntilCallStarts(1))
        loader.releaseCall(1)
        try #require(await waitForGitTaskCompletion(secondRefresh))
        loader.releaseCall(0)
        try #require(await waitForGitTaskCompletion(firstRefresh))

        #expect(!loader.didTimeOut)
        #expect(feature.gitWorktreeLoadState == .ready)
        #expect(feature.gitWorktrees == [newWorktree])
    }

    @Test
    func successfulWorktreeRemovalResetsItsLogScopeAndRefreshesGitState() async {
        let root = URL(fileURLWithPath: "/workspace")
        let removedWorktree = makeTestWorktree(path: "/workspace-maim", branch: "maim")
        let remainingWorktree = GitWorktree(
            path: root.path,
            head: "2222222222222222222222222222222222222222",
            branch: "refs/heads/preview",
            isCurrent: true,
            isPrimary: true,
            isBare: false,
            isDetached: false,
            isLocked: false,
            lockReason: nil,
            isPrunable: false,
            pruneReason: nil
        )
        let preview = GitReference(
            fullName: "refs/heads/preview",
            shortName: "preview",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let maim = GitReference(
            fullName: "refs/heads/maim",
            shortName: "maim",
            kind: .local,
            isCurrent: false,
            upstreamShortName: nil
        )
        let currentCommit = makeTestCommit(
            hash: "2222222222222222",
            subject: "Current checkout history"
        )
        let service = GitService(operations: TestGitOperations(
            snapshotValue: GitSnapshot(repositoryRoot: root, branch: "preview", changes: []),
            referencesValue: GitReferenceSnapshot(
                references: [preview, maim],
                recentReferences: [preview, maim]
            ),
            historyPageValues: [
                "": GitHistoryPage(
                    commits: [currentCommit],
                    nextCursor: nil,
                    hasMore: false
                )
            ],
            removeWorktreeResult: GitProcessResult(
                arguments: ["worktree", "remove", "--", removedWorktree.path],
                output: "",
                exitCode: 0
            )
        ))
        let feature = GitFeatureModel(
            service: service,
            worktreesProvider: { _ in [remainingWorktree] }
        )
        feature.configure(
            workspaceURLProvider: { root },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )
        await feature.refreshGit()
        feature.selectedGitReference = maim

        await feature.removeWorktree(removedWorktree, force: false)

        #expect(feature.selectedGitReference == nil)
        #expect(!feature.isShowingAllGitReferences)
        #expect(feature.gitWorktrees == [remainingWorktree])
        #expect(feature.gitReferences == [preview, maim])
        #expect(feature.gitCommits == [currentCommit])
    }

    @Test
    func gitConsolePreservesStandardErrorColorForSuccessfulCommands() {
        let entry = GitConsoleEntry(
            workingDirectory: URL(fileURLWithPath: "/workspace"),
            arguments: ["checkout", "-b", "feature"],
            output: "Switched to a new branch 'feature'\n",
            standardOutput: "",
            standardError: "Switched to a new branch 'feature'\n",
            exitCode: 0
        )

        #expect(entry.succeeded)
        #expect(entry.outputLines == [
            GitConsoleOutputLine(
                stream: .standardError,
                text: "Switched to a new branch 'feature'"
            )
        ])
    }


    @Test
    func workingTreeComparisonMergesTrackedAndUntrackedFiles() async {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: "origin/main"
        )
        let snapshot = GitSnapshot(repositoryRoot: root, branch: "main", changes: [
            GitChange(
                repositoryRoot: root,
                path: "README.md",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "M"
            ),
            GitChange(
                repositoryRoot: root,
                path: "src/UserRepository.java",
                originalPath: nil,
                indexStatus: " ",
                workTreeStatus: "D"
            ),
            GitChange(
                repositoryRoot: root,
                path: "qa-untracked.txt",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            )
        ])
        let trackedComparison = GitBranchComparison(reference: reference, files: [
            GitBranchComparisonFile(status: "D", path: "src/UserRepository.java"),
            GitBranchComparisonFile(status: "M", path: "README.md")
        ])
        let service = GitService(operations: TestGitOperations(
            snapshotValue: snapshot,
            comparisonValue: trackedComparison
        ))

        let comparison = await service.comparisonWithWorkingTree(for: reference, at: root)

        #expect(comparison.files.map(\.path) == [
            "README.md",
            "qa-untracked.txt",
            "src/UserRepository.java"
        ])
        #expect(comparison.files.count == 3)
        #expect(comparison.files.first(where: { $0.path == "qa-untracked.txt" })?.isUntracked == true)
        #expect(comparison.files.first(where: { $0.path == "README.md" })?.isUntracked == false)
    }

    @Test
    func untrackedComparisonFileUsesUntrackedDiffDocument() async throws {
        let root = URL(fileURLWithPath: "/workspace")
        let reference = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let untrackedDocument = DiffDocument(rows: [
            DiffRow(
                oldLine: nil,
                newLine: 1,
                left: nil,
                right: "untracked contents",
                kind: .addition
            )
        ], hunks: [])
        let comparisonDocument = DiffDocument(rows: [
            DiffRow(
                oldLine: 1,
                newLine: 1,
                left: "before",
                right: "tracked contents",
                kind: .changed
            )
        ], hunks: [])
        let service = GitService(operations: TestGitOperations(
            untrackedDiffDocumentValue: untrackedDocument,
            comparisonDiffDocumentValue: comparisonDocument
        ))

        let untrackedRows = await service.diff(
            for: GitBranchComparisonFile(
                status: "A",
                path: "qa-untracked.txt",
                isUntracked: true
            ),
            against: reference,
            at: root
        )
        let trackedRows = await service.diff(
            for: GitBranchComparisonFile(status: "M", path: "README.md"),
            against: reference,
            at: root
        )

        #expect(try #require(untrackedRows.first).rightText == "untracked contents")
        #expect(try #require(untrackedRows.first).kind == .addition)
        #expect(try #require(trackedRows.first).rightText == "tracked contents")
    }

    @Test
    func referenceComparisonDoesNotIncludeWorkingTreeUntrackedFiles() async {
        let root = URL(fileURLWithPath: "/workspace")
        let source = GitReference(
            fullName: "refs/heads/main",
            shortName: "main",
            kind: .local,
            isCurrent: true,
            upstreamShortName: nil
        )
        let target = GitReference(
            fullName: "refs/remotes/origin/main",
            shortName: "origin/main",
            kind: .remote,
            isCurrent: false,
            upstreamShortName: nil
        )
        let snapshot = GitSnapshot(repositoryRoot: root, branch: "main", changes: [
            GitChange(
                repositoryRoot: root,
                path: "qa-untracked.txt",
                originalPath: nil,
                indexStatus: "?",
                workTreeStatus: "?"
            )
        ])
        let payload = GitBranchComparison(reference: source, files: [
            GitBranchComparisonFile(status: "M", path: "src/Tracked.java")
        ])
        let service = GitService(operations: TestGitOperations(
            snapshotValue: snapshot,
            typedComparisonValue: payload
        ))

        let comparison = await service.comparison(from: source, to: target, at: root)

        #expect(comparison.files.map(\.path) == ["src/Tracked.java"])
        #expect(comparison.targetReference == target)
    }

    @Test
    func disabledGitDoesNotConstructFactoryOrServiceGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.git)) {
            _ = try await runtime.activateCapability(.gitWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.storageFactoryCalls == 0)
        #expect(try !runtime.snapshot(for: .git).isInstantiated)
    }

    @Test
    func sleepReleasesFeatureAndWakeCreatesANewGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: GitModule.moduleManifest, contributions: GitModule.moduleContributions) {
            recorder.factoryCalls += 1
            return makeModule(recorder: recorder)
        })

        var first: GitFeatureModel? = try #require(
            (try await runtime.activateCapability(.gitWorkspace) as? GitModuleCapability)?.feature
        )
        weak var released = first
        first = nil
        try await runtime.sleep(.git)

        #expect(released == nil)
        #expect(runtime.capability(.gitWorkspace) == nil)
        #expect(try runtime.snapshot(for: .git).activity.activeResourceCount == 0)

        let second = try #require(
            (try await runtime.activateCapability(.gitWorkspace) as? GitModuleCapability)?.feature
        )
        #expect(second !== released)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.storageFactoryCalls == 2)
    }

    private func makeModule(recorder: Recorder) -> GitModule {
        recorder.storageFactoryCalls += 1
        return GitModule(operations: TestGitOperations(), shelfStorage: TestShelfStorage())
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyWorkspaceModule()
        }
    }
}

@MainActor private final class Recorder { var factoryCalls = 0; var storageFactoryCalls = 0 }
@MainActor private final class EmptyWorkspaceModule: LitheModule {
    let manifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

private struct TestShelfStorage: GitShelfStorage {
    func applicationSupportDirectory() -> URL { URL(fileURLWithPath: "/tmp/lithe-git-module-test") }
    func fileExists(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readData(from url: URL) throws -> Data { Data() }
    func writeData(_ data: Data, to url: URL) throws {}
    func createDirectory(at url: URL) throws {}
    func removeItem(at url: URL) throws {}
}

private final class TestGitRunGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstRunStarted = GitModuleTestGate()
    private let firstRunRelease = GitModuleTestGate()
    private var hasBlockedFirstRun = false
    private var didTimeOutValue = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOutValue
    }

    func blockFirstRun() {
        lock.lock()
        let shouldBlock = !hasBlockedFirstRun
        hasBlockedFirstRun = true
        lock.unlock()
        guard shouldBlock else { return }
        firstRunStarted.open()
        guard firstRunRelease.waitSynchronously() else {
            lock.lock()
            didTimeOutValue = true
            lock.unlock()
            return
        }
    }

    func waitUntilFirstRunStarts() async -> Bool {
        await firstRunStarted.waitUntilOpen()
    }

    func releaseFirstRun() {
        firstRunRelease.open()
    }
}

private final class GitFilesCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func recordCall() {
        lock.lock()
        calls += 1
        lock.unlock()
    }
}

private func makeTestCommit(hash: String, subject: String) -> GitCommit {
    GitCommit(
        hash: hash,
        shortHash: String(hash.prefix(7)),
        parentHashes: [],
        authorName: "Test Author",
        authorEmail: "author@example.com",
        date: "2026-08-28T16:00:00+08:00",
        subject: subject,
        decorations: ""
    )
}

private final class GitHistoryMutationController: @unchecked Sendable {
    private let lock = NSLock()
    private let before: [GitCommit]
    private let after: [GitCommit]
    private var didMutate = false
    private var historyCalls = 0
    private var revertedHashValues: [String] = []

    init(before: [GitCommit], after: [GitCommit]) {
        self.before = before
        self.after = after
    }

    var historyCallCount: Int {
        lock.withLock { historyCalls }
    }

    var revertedHashes: [String] {
        lock.withLock { revertedHashValues }
    }

    func historyPage() -> GitHistoryPage {
        lock.withLock {
            historyCalls += 1
            return GitHistoryPage(
                commits: didMutate ? after : before,
                nextCursor: nil,
                hasMore: false
            )
        }
    }

    func revert(_ hash: String) -> GitProcessResult {
        lock.withLock {
            revertedHashValues.append(hash)
            didMutate = true
        }
        return GitProcessResult(arguments: ["revert", hash], output: "", exitCode: 0)
    }
}

private final class GitPagingRefreshController: @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [GitCommit]
    private var limits: [Int] = []
    private var failsContinuations = false
    init(commits: [GitCommit]) { self.commits = commits }
    var visibleLimits: [Int] { lock.withLock { limits } }
    func prepend(_ commit: GitCommit) { lock.withLock { commits.insert(commit, at: 0) } }
    /// Makes every request that continues from a cursor fail, like a consumed Core cursor.
    func setFailsContinuations(_ fails: Bool) { lock.withLock { failsContinuations = fails } }
    func page(reference: GitReference?, cursor: String?, limit: Int) -> GitHistoryPage? {
        lock.withLock {
            if failsContinuations, cursor != nil { return nil }
            if reference != nil { limits.append(limit) }
            let offset = cursor.flatMap(Int.init) ?? 0
            let page = Array(commits.dropFirst(offset).prefix(limit))
            let end = offset + page.count
            return GitHistoryPage(commits: page, nextCursor: end < commits.count ? String(end) : nil,
                                  hasMore: end < commits.count)
        }
    }
}

private func makeTestWorktree(path: String, branch: String) -> GitWorktree {
    GitWorktree(
        path: path,
        head: "1111111111111111111111111111111111111111",
        branch: "refs/heads/\(branch)",
        isCurrent: false,
        isPrimary: false,
        isBare: false,
        isDetached: false,
        isLocked: false,
        lockReason: nil,
        isPrunable: false,
        pruneReason: nil
    )
}

/// A diff document whose content a test can change between refreshes.
private final class MutableDiffDocumentSource: @unchecked Sendable {
    private let lock = NSLock()
    private let includesPatch: Bool
    private var text: String
    /// `includesPatch: false` mirrors comparisons against HEAD, which carry rows only.
    init(text: String, includesPatch: Bool = true) { self.text = text; self.includesPatch = includesPatch }
    func set(text: String) { lock.withLock { self.text = text } }
    func document() -> DiffDocument {
        let text = lock.withLock { self.text }
        return DiffDocument(patch: includesPatch ? text : "",
            rows: [DiffRow(oldLine: 1, newLine: 1, left: "old", right: text, kind: .changed)], hunks: [])
    }
}

private actor RepositoryDiffDocumentProbe {
    private let blockedCall: Int
    private var calls = 0
    nonisolated let started = GitModuleTestGate()
    nonisolated let release = GitModuleTestGate()
    init(blockedCall: Int) { self.blockedCall = blockedCall }
    func read() async -> DiffDocument {
        calls += 1
        let blocked = calls == blockedCall
        if blocked {
            started.open()
            #expect(await release.waitUntilOpen(), "Blocked Diff read was not released")
        }
        let text = blocked ? "stale" : "fresh"
        return DiffDocument(patch: text,
            rows: [DiffRow(oldLine: 1, newLine: 1, left: "old", right: text, kind: .changed)], hunks: [])
    }
}

private final class GitModuleTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var asyncWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    func open() {
        condition.lock()
        isOpen = true
        let waiters = Array(asyncWaiters.values)
        let tasks = Array(timeoutTasks.values)
        asyncWaiters.removeAll()
        timeoutTasks.removeAll()
        condition.broadcast()
        condition.unlock()
        tasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(returning: true) }
    }

    func waitSynchronously(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !isOpen {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func waitUntilOpen(timeout: Duration = .seconds(2)) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                guard !isOpen else {
                    condition.unlock()
                    continuation.resume(returning: true)
                    return
                }
                asyncWaiters[waiterID] = continuation
                condition.unlock()

                let timeoutTask = Task { [weak self] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog bounds a failed event-driven Git test without controlling successful execution order.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishAsyncWaiter(waiterID, result: false)
                }
                condition.lock()
                if asyncWaiters[waiterID] == nil {
                    condition.unlock()
                    timeoutTask.cancel()
                } else {
                    timeoutTasks[waiterID] = timeoutTask
                    condition.unlock()
                }
                if Task.isCancelled {
                    finishAsyncWaiter(waiterID, result: false)
                }
            }
        } onCancel: {
            finishAsyncWaiter(waiterID, result: false)
        }
    }

    private func finishAsyncWaiter(_ waiterID: UUID, result: Bool) {
        condition.lock()
        let waiter = asyncWaiters.removeValue(forKey: waiterID)
        let timeoutTask = timeoutTasks.removeValue(forKey: waiterID)
        condition.unlock()
        timeoutTask?.cancel()
        waiter?.resume(returning: result)
    }
}

private final class WorktreeHistoryPageProbe: @unchecked Sendable {
    struct Request {
        let reference: GitReference?
        let cursor: String?
        let limit: Int
    }
    private let lock = NSLock()
    private let pages: [GitHistoryPage?]
    private let blockedIndices: Set<Int>
    let started = GitModuleTestGate()
    private let release = GitModuleTestGate()
    private var recorded: [Request] = []
    private var closedValues: [String] = []
    private var cancelledValues: [String] = []
    private var didTimeOut = false
    init(pages: [GitHistoryPage?], blockedIndices: Set<Int> = []) {
        self.pages = pages
        self.blockedIndices = blockedIndices
    }
    var requests: [Request] { lock.withLock { recorded } }
    var closed: [String] { lock.withLock { closedValues } }
    var cancelled: [String] { lock.withLock { cancelledValues } }
    var timedOut: Bool { lock.withLock { didTimeOut } }
    func close(_ cursor: String) { lock.withLock { closedValues.append(cursor) } }
    func cancel(_ operationID: String) { lock.withLock { cancelledValues.append(operationID) } }
    func releaseAll() { release.open() }
    func page(reference: GitReference?, cursor: String?, limit: Int) -> GitHistoryPage? {
        let index = lock.withLock {
            let index = recorded.count
            recorded.append(Request(reference: reference, cursor: cursor, limit: limit))
            return index
        }
        started.open()
        if blockedIndices.contains(index), !release.waitSynchronously() {
            lock.withLock { didTimeOut = true }
            return nil
        }
        return pages.indices.contains(index) ? pages[index] : nil
    }
}

private final class GitHistoryLoadController: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [GitHistorySnapshot]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private var calls = 0
    private var timedOut = false

    init(results: [GitHistorySnapshot]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        let callIndex: Int
        lock.lock()
        callIndex = calls
        calls += 1
        lock.unlock()
        guard results.indices.contains(callIndex) else { return nil }
        startedGates[callIndex].open()
        guard releaseGates[callIndex].waitSynchronously() else {
            lock.lock()
            timedOut = true
            lock.unlock()
            return nil
        }
        return results[callIndex]
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }
}

private final class GitWorktreeLoadController: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [[GitWorktree]?]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private var calls = 0
    private var timedOut = false

    init(results: [[GitWorktree]?]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func load(_ root: URL) async -> [GitWorktree]? {
        let callIndex = reserveCall()
        guard results.indices.contains(callIndex) else { return nil }
        startedGates[callIndex].open()
        guard await releaseGates[callIndex].waitUntilOpen() else {
            recordTimeout()
            return nil
        }
        return results[callIndex]
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }

    private func reserveCall() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let callIndex = calls
        calls += 1
        return callIndex
    }

    private func recordTimeout() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class GitFilesLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [[GitCommitFile]?]
    private let startedGates: [GitModuleTestGate]
    private let releaseGates: [GitModuleTestGate]
    private let finishedGates: [GitModuleTestGate]
    private var calls = 0
    private var activeCalls = 0
    private var peakConcurrentCalls = 0
    private var hashes: [String] = []
    private var timedOut = false

    init(results: [[GitCommitFile]?]) {
        self.results = results
        startedGates = results.map { _ in GitModuleTestGate() }
        releaseGates = results.map { _ in GitModuleTestGate() }
        finishedGates = results.map { _ in GitModuleTestGate() }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakConcurrentCalls
    }

    var callHashes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hashes
    }

    func loadFiles(for commit: GitCommit) -> [GitCommitFile]? {
        lock.lock()
        let callIndex = calls
        calls += 1
        activeCalls += 1
        peakConcurrentCalls = max(peakConcurrentCalls, activeCalls)
        hashes.append(commit.hash)
        lock.unlock()

        guard results.indices.contains(callIndex) else {
            finishCall(callIndex, timedOut: true)
            return nil
        }
        startedGates[callIndex].open()
        guard releaseGates[callIndex].waitSynchronously() else {
            finishCall(callIndex, timedOut: true)
            return nil
        }
        let result = results[callIndex]
        finishCall(callIndex, timedOut: false)
        return result
    }

    func waitUntilCallStarts(_ index: Int) async -> Bool {
        guard startedGates.indices.contains(index) else { return false }
        return await startedGates[index].waitUntilOpen()
    }

    func waitUntilCallFinishes(_ index: Int) async -> Bool {
        guard finishedGates.indices.contains(index) else { return false }
        return await finishedGates[index].waitUntilOpen()
    }

    func releaseCall(_ index: Int) {
        guard releaseGates.indices.contains(index) else { return }
        releaseGates[index].open()
    }

    func releaseAll() {
        releaseGates.forEach { $0.open() }
    }

    private func finishCall(_ index: Int, timedOut: Bool) {
        lock.lock()
        activeCalls = max(0, activeCalls - 1)
        self.timedOut = self.timedOut || timedOut
        lock.unlock()
        guard finishedGates.indices.contains(index) else { return }
        finishedGates[index].open()
    }
}

private func waitForGitCommitFilesOutcome(
    _ task: Task<GitCommitFilesLoadOutcome, Never>,
    timeout: Duration = .seconds(2)
) async -> GitCommitFilesLoadOutcome? {
    await withTaskGroup(of: GitCommitFilesLoadOutcome?.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for a loader outcome.
            try? await Task.sleep(for: timeout)
            task.cancel()
            return nil
        }
        let result = await group.next() ?? nil
        if result == nil {
            task.cancel()
        }
        group.cancelAll()
        return result
    }
}

private final class CleanedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var paths: [String] { lock.withLock { values } }
    func append(_ path: String) { lock.withLock { values.append(path) } }
}

/// Answers directory listings, holding the listing from `blockingFromCall`
/// on until the test releases it.
private final class UntrackedDirectoryListing: @unchecked Sendable {
    let started = GitModuleTestGate()
    let release = GitModuleTestGate()
    private let lock = NSLock()
    private let blockingFromCall: Int
    private var calls = 0

    init(blockingFromCall: Int) { self.blockingFromCall = blockingFromCall }

    func list(_ children: [GitChange]) async -> [GitChange]? {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call >= blockingFromCall else { return children }
        started.open()
        guard await release.waitUntilOpen() else { return nil }
        return children
    }
}

private actor UntrackedDirectorySnapshots {
    private var snapshot: GitSnapshot

    init(_ snapshot: GitSnapshot) { self.snapshot = snapshot }

    func current() -> GitSnapshot { snapshot }
    func replace(with snapshot: GitSnapshot) { self.snapshot = snapshot }
}

private func waitForGitTaskCompletion(
    _ task: Task<Void, Never>,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            // test-stability: allow(swift-real-sleep) reason: this task is the bounded failure deadline for an event-driven Git task.
            try? await Task.sleep(for: timeout)
            task.cancel()
            return false
        }
        let completed = await group.next() ?? false
        if !completed {
            task.cancel()
        }
        group.cancelAll()
        return completed
    }
}

@MainActor
private func waitForGitWorktreeInspection(
    _ feature: GitFeatureModel,
    timeout: Duration = .seconds(2)
) async -> GitWorktreeInspection? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while feature.gitWorktreeInspection == nil, clock.now < deadline {
        await Task.yield()
    }
    return feature.gitWorktreeInspection
}

@MainActor
private func waitForGitWorkToBecomeIdle(
    timeout: Duration = .seconds(2),
    isActive: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while isActive(), clock.now < deadline {
        await Task.yield()
    }
    return !isActive()
}

private final class GitPerformanceLogRecorder: GitPerformanceLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessages: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessages
    }

    func record(_ message: String) {
        lock.lock()
        recordedMessages.append(message)
        lock.unlock()
    }
}

/// Records each repository commit so multi-repository submission can assert
/// that one Git commit is issued per independent index.
private final class CommitCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let root: URL
        let message: String
        let amend: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Records the parent gitlink restage issued after a child submodule commit.
private final class StageCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let root: URL
        let path: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ change: GitChange) {
        lock.lock()
        calls.append(Call(root: change.repositoryRoot, path: change.path))
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Records tag create/delete arguments so restore flows can be asserted on
/// the exact parameters the feature model replays.
private final class TagCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let revision: String
        let message: String?
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Records branch create/delete arguments for the branch restore flow.
private final class BranchCallRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let reference: String
        let checkout: Bool
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    var recorded: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Supplies deterministic per-call results for consecutive Git mutations.
private final class GitProcessResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [GitProcessResult]

    init(_ results: [GitProcessResult]) {
        self.results = results
    }

    func next() -> GitProcessResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}

/// Controls the native synchronous operation boundary on GitService's worker
/// queue. The existing gate bounds failures and exposes an async start event.
private final class GitGraphHistoryProbe: @unchecked Sendable {
    let started = GitModuleTestGate()
    let release = GitModuleTestGate()
    private let lock = NSLock()
    private let blockGraph: Bool
    private let releaseOnCancel: Bool
    private var graphRequests = 0
    private var failed = false
    private var closed: [String] = []
    private var cancelled: [String] = []
    private var graphOperationID: String?
    private var allReferences = false
    private var timedOut = false

    init(blockGraph: Bool = false, releaseOnCancel: Bool = true) {
        self.blockGraph = blockGraph
        self.releaseOnCancel = releaseOnCancel
    }
    var closedCursors: [String] { lock.withLock { closed } }
    var cancelledOperationIDs: [String] { lock.withLock { cancelled } }
    var requestedAllReferences: Bool { lock.withLock { allReferences } }
    var didTimeOut: Bool { lock.withLock { timedOut } }
    var graphWasCancelled: Bool { lock.withLock { graphOperationID.map(cancelled.contains) ?? false } }
    func failGraphRequest() { lock.withLock { failed = true } }
    func close(cursor: String) { lock.withLock { closed.append(cursor) } }
    func cancel(operationID: String) {
        lock.withLock { cancelled.append(operationID) }
        if releaseOnCancel { release.open() }
    }

    func page(reference: GitReference?, cursor: String?, limit: Int, operationID: String) -> GitHistoryPage? {
        if limit == 5_000 {
            let shouldBlock = lock.withLock {
                graphOperationID = operationID
                allReferences = reference == nil && cursor == nil
                graphRequests += 1
                return blockGraph && graphRequests == 1
            }
            started.open()
            if shouldBlock, !release.waitSynchronously() { lock.withLock { timedOut = true } }
            guard !lock.withLock({ failed }) else { return nil }
            return GitHistoryPage(commits: [makeTestCommit(hash: "other-branch", subject: "Other branch"),
                                           makeTestCommit(hash: "visible", subject: "Visible")],
                                  nextCursor: "graph-cursor", hasMore: true)
        }
        return GitHistoryPage(commits: [makeTestCommit(hash: cursor == nil ? "visible" : "older", subject: "Visible history")],
                              nextCursor: cursor == nil ? "visible-cursor" : nil, hasMore: cursor == nil)
    }
}

/// Blocks the first `references(at:)` read for one repository, then lets later
/// reads pass. Used to hold a stale per-repository reference load open while a
/// superseding refresh completes.
private final class GitReferencesLoadProbe: @unchecked Sendable {
    let started = GitModuleTestGate()
    let release = GitModuleTestGate()
    private let lock = NSLock()
    private let blockedRootPath: String
    private var blockedCalls = 0
    private var timedOut = false
    private var roots: [URL] = []

    init(blocking root: URL) {
        blockedRootPath = root.standardizedFileURL.path
    }

    var didTimeOut: Bool { lock.withLock { timedOut } }
    var requestedRoots: [URL] { lock.withLock { roots } }

    func references(at rootURL: URL, resolved: GitReferenceSnapshot?) -> GitReferenceSnapshot? {
        lock.withLock { roots.append(rootURL) }
        guard rootURL.standardizedFileURL.path == blockedRootPath else { return resolved }
        let shouldBlock = lock.withLock {
            blockedCalls += 1
            return blockedCalls == 1
        }
        guard shouldBlock else { return resolved }
        started.open()
        guard release.waitSynchronously() else {
            lock.withLock { timedOut = true }
            return nil
        }
        return resolved
    }
}

private actor GitStatusSnapshotSequence {
    private var values: [URL: [GitSnapshot?]]

    init(values: [URL: [GitSnapshot?]]) { self.values = values }

    func next(for root: URL) -> GitSnapshot? {
        guard var remaining = values[root], !remaining.isEmpty else {
            Issue.record("Unexpected repository snapshot request")
            return nil
        }
        let snapshot = remaining.removeFirst()
        values[root] = remaining
        return snapshot
    }
}

private actor GitRepositorySwitchSnapshots {
    let started = GitModuleTestGate()
    let release = GitModuleTestGate()
    private var blocksNext = false

    func blockNext() { blocksNext = true }

    func next(_ root: URL) async -> GitSnapshot? {
        if blocksNext {
            blocksNext = false
            started.open()
            guard await release.waitUntilOpen() else { return nil }
        }
        return GitSnapshot(repositoryRoot: root, branch: "\(root.lastPathComponent)-only", changes: [])
    }
}

private final class GitRepositoryHistoryProbe: @unchecked Sendable {
    struct Request: Sendable {
        let root: URL
        let reference: String?
    }
    struct ClosedCursor: Sendable {
        let root: URL
        let cursor: String
    }
    private let lock = NSLock()
    private var requestValues: [Request] = []
    private var closedCursorValues: [ClosedCursor] = []
    private let failedRoot: URL?

    init(failedRoot: URL? = nil) { self.failedRoot = failedRoot }
    var requests: [Request] { lock.withLock { requestValues } }
    var closedCursors: [ClosedCursor] { lock.withLock { closedCursorValues } }

    func reference(for root: URL) -> GitReference {
        GitReference(fullName: "refs/heads/\(root.lastPathComponent)-only",
            shortName: "\(root.lastPathComponent)-only", kind: .local,
            isCurrent: true, upstreamShortName: nil)
    }

    func page(at root: URL, reference: GitReference?) -> GitHistoryPage? {
        lock.withLock { requestValues.append(Request(root: root, reference: reference?.fullName)) }
        guard root != failedRoot else { return nil }
        // A branch from another repository fails just as real Git would.
        guard reference == nil || reference?.fullName == "HEAD"
            || reference?.fullName == self.reference(for: root).fullName else { return nil }
        return GitHistoryPage(
            commits: [makeTestCommit(hash: "\(root.lastPathComponent)-commit", subject: "Fixture")],
            nextCursor: reference == nil ? nil : "\(root.lastPathComponent)-cursor",
            hasMore: reference != nil)
    }

    func close(at root: URL, cursor: String) {
        lock.withLock { closedCursorValues.append(ClosedCursor(root: root, cursor: cursor)) }
    }
}

private final class WorktreeChangesProbe: @unchecked Sendable {
    struct Call { let action: String; let change: GitChange }
    private let lock = NSLock()
    private let root: URL
    private var changes: [GitChange]
    private var recorded: [Call] = []
    private var snapshotsFail = false
    private var readRoots: [URL] = []
    init(root: URL, changes: [GitChange]) { self.root = root; self.changes = changes }
    var calls: [Call] { lock.withLock { recorded } }
    var snapshotRoots: [URL] { lock.withLock { readRoots } }
    func replaceChanges(_ changes: [GitChange]) { lock.withLock { self.changes = changes } }
    func failSnapshots() { lock.withLock { snapshotsFail = true } }
    func restoreSnapshots() { lock.withLock { snapshotsFail = false } }
    func snapshot(_ target: URL) -> GitSnapshot? {
        lock.withLock {
            readRoots.append(target)
            guard !snapshotsFail else { return nil }
            return GitSnapshot(repositoryRoot: target, branch: "main",
                changes: target == root ? [] : changes.filter { $0.repositoryRoot == target })
        }
    }
    func mutate(_ change: GitChange, action: String, succeeds: Bool = true) -> GitProcessResult {
        lock.withLock {
            recorded.append(Call(action: action, change: change))
            if succeeds {
                changes = changes.compactMap { current in
                    guard current.id == change.id else { return current }
                    if action == "discard" { return nil }
                    return GitChange(repositoryRoot: current.repositoryRoot, path: current.path, originalPath: current.originalPath,
                        indexStatus: action == "stage" ? "M" : " ", workTreeStatus: action == "stage" ? " " : "M")
                }
            }
            return GitProcessResult(arguments: [action, "--", change.path], output: succeeds ? "" : "operation failed", exitCode: succeeds ? 0 : 1)
        }
    }
}

private struct TestGitOperations: GitOperations {
    private let snapshotValue: GitSnapshot?
    private let snapshotHandler: (@Sendable (URL) -> GitSnapshot?)?
    private let snapshotsByRoot: [String: GitSnapshot]
    private let repositoryRoots: [URL]?
    private let comparisonValue: GitBranchComparison?
    private let typedComparisonValue: GitBranchComparison?
    private let comparisonRead: (@Sendable () -> GitBranchComparison?)?
    private let comparisonRowsRead: (@Sendable () -> DiffDocument?)?
    private let filesValue: [GitCommitFile]?
    private let untrackedDiffDocumentValue: DiffDocument?
    private let comparisonDiffDocumentValue: DiffDocument?
    private let typedComparisonDiffDocumentValue: DiffDocument?
    private let historyValue: GitHistorySnapshot?
    private let referencesValue: GitReferenceSnapshot?
    private let referencesByRoot: [String: GitReferenceSnapshot]?
    private let referencesProbe: GitReferencesLoadProbe?
    private let historyPageRequestHandler: (@Sendable (GitReference?, String?, Int) -> GitHistoryPage?)?
    private let historyPageValues: [String: GitHistoryPage]?
    private let historyPageHandler: (@Sendable () -> GitHistoryPage?)?
    private let historyPageByReferenceHandler: (@Sendable (GitReference?, String?) -> GitHistoryPage?)?
    private let repositoryHistoryProbe: GitRepositoryHistoryProbe?
    private let graphHistoryProbe: GitGraphHistoryProbe?
    private let historyController: GitHistoryLoadController?
    private let worktreeHistoryProbe: WorktreeHistoryPageProbe?
    private let snapshotGate: GitModuleTestGate?
    private let discardHandler: (@Sendable (GitChange) -> GitProcessResult?)?
    private let discardAllHandler: (@Sendable (GitChange) -> GitProcessResult?)?
    private let diffPatchHandler: (@Sendable ([String], Bool) -> String?)?
    private let applyPatchHandler: (@Sendable (String, URL, String) -> GitProcessResult?)?
    private let stageResult: GitProcessResult?
    private let stageHandler: (@Sendable (GitChange) -> GitProcessResult?)?
    private let unstageHandler: (@Sendable (GitChange) -> GitProcessResult?)?
    private let commitResult: GitProcessResult?
    private let commitCallRecorder: CommitCallRecorder?
    private let stageCallRecorder: StageCallRecorder?
    private let gitlinkPathsByRoot: [String: [String]]
    private let workspaceCommitProbe: WorkspaceCommitProbe
    private let revertHandler: (@Sendable (String) -> GitProcessResult?)?
    private let runGate: TestGitRunGate?
    private let filesRecorder: GitFilesCallRecorder?
    private let filesGate: GitFilesLoadGate?
    private let createTagResult: GitProcessResult?
    private let deleteTagResult: GitProcessResult?
    private let deleteTagResults: GitProcessResultQueue?
    private let tagCallRecorder: TagCallRecorder?
    private let createBranchResult: GitProcessResult?
    private let deleteBranchResult: GitProcessResult?
    private let deleteBranchResults: GitProcessResultQueue?
    private let updateBranchResult: GitProcessResult?
    private let branchCallRecorder: BranchCallRecorder?
    private let exportPatchHandler: (@Sendable ([String], Bool) -> Result<GitPatchExport, GitPatchFailure>)?
    private let removeWorktreeResult: GitProcessResult?
    private let fetchPlanValue: GitFetchPlan?
    private let fetchHandler: (@Sendable (GitFetchOptions, String) -> GitProcessResult?)?
    private let pushPreviewHandler: (@Sendable (GitReference, GitPushTargetChoice?, URL) -> Result<GitPushPreview, GitPushFailure>)?
    private let pushReviewedHandler: (@Sendable (GitReference, GitPushPreview, GitPushTargetChoice?) -> GitProcessResult?)?

    init(
        snapshotValue: GitSnapshot? = nil,
        snapshotsByRoot: [String: GitSnapshot] = [:],
        snapshotHandler: (@Sendable (URL) -> GitSnapshot?)? = nil,
        repositoryRoots: [URL]? = nil,
        comparisonValue: GitBranchComparison? = nil,
        typedComparisonValue: GitBranchComparison? = nil,
        comparisonRead: (@Sendable () -> GitBranchComparison?)? = nil,
        comparisonRowsRead: (@Sendable () -> DiffDocument?)? = nil,
        historyValue: GitHistorySnapshot? = nil,
        referencesValue: GitReferenceSnapshot? = nil,
        referencesByRoot: [String: GitReferenceSnapshot]? = nil,
        referencesProbe: GitReferencesLoadProbe? = nil,
        historyPageRequestHandler: (@Sendable (GitReference?, String?, Int) -> GitHistoryPage?)? = nil,
        historyPageValues: [String: GitHistoryPage]? = nil,
        historyPageHandler: (@Sendable () -> GitHistoryPage?)? = nil,
        historyPageByReferenceHandler: (@Sendable (GitReference?, String?) -> GitHistoryPage?)? = nil,
        repositoryHistoryProbe: GitRepositoryHistoryProbe? = nil,
        graphHistoryProbe: GitGraphHistoryProbe? = nil,
        historyController: GitHistoryLoadController? = nil,
        worktreeHistoryProbe: WorktreeHistoryPageProbe? = nil,
        filesValue: [GitCommitFile]? = nil,
        untrackedDiffDocumentValue: DiffDocument? = nil,
        comparisonDiffDocumentValue: DiffDocument? = nil,
        typedComparisonDiffDocumentValue: DiffDocument? = nil,
        snapshotGate: GitModuleTestGate? = nil,
        discardHandler: (@Sendable (GitChange) -> GitProcessResult?)? = nil,
        discardAllHandler: (@Sendable (GitChange) -> GitProcessResult?)? = nil,
        diffPatchHandler: (@Sendable ([String], Bool) -> String?)? = nil,
        applyPatchHandler: (@Sendable (String, URL, String) -> GitProcessResult?)? = nil,
        stageResult: GitProcessResult? = nil,
        stageHandler: (@Sendable (GitChange) -> GitProcessResult?)? = nil,
        unstageHandler: (@Sendable (GitChange) -> GitProcessResult?)? = nil,
        commitResult: GitProcessResult? = nil,
        commitCallRecorder: CommitCallRecorder? = nil,
        stageCallRecorder: StageCallRecorder? = nil,
        gitlinkPathsByRoot: [String: [String]] = [:],
        workspaceCommitProbe: WorkspaceCommitProbe? = nil,
        revertHandler: (@Sendable (String) -> GitProcessResult?)? = nil,
        runGate: TestGitRunGate? = nil,
        filesRecorder: GitFilesCallRecorder? = nil,
        filesGate: GitFilesLoadGate? = nil,
        createTagResult: GitProcessResult? = nil,
        deleteTagResult: GitProcessResult? = nil,
        deleteTagResults: GitProcessResultQueue? = nil,
        tagCallRecorder: TagCallRecorder? = nil,
        createBranchResult: GitProcessResult? = nil,
        deleteBranchResult: GitProcessResult? = nil,
        deleteBranchResults: GitProcessResultQueue? = nil,
        updateBranchResult: GitProcessResult? = nil,
        branchCallRecorder: BranchCallRecorder? = nil,
        exportPatchHandler: (@Sendable ([String], Bool) -> Result<GitPatchExport, GitPatchFailure>)? = nil,
        removeWorktreeResult: GitProcessResult? = nil,
        fetchPlan: GitFetchPlan? = nil,
        fetchHandler: (@Sendable (GitFetchOptions, String) -> GitProcessResult?)? = nil,
        pushPreviewHandler: (@Sendable (GitReference, GitPushTargetChoice?, URL) -> Result<GitPushPreview, GitPushFailure>)? = nil,
        pushReviewedHandler: (@Sendable (GitReference, GitPushPreview, GitPushTargetChoice?) -> GitProcessResult?)? = nil
    ) {
        self.snapshotValue = snapshotValue
        self.snapshotHandler = snapshotHandler
        self.snapshotsByRoot = snapshotsByRoot
        self.repositoryRoots = repositoryRoots
        self.comparisonValue = comparisonValue
        self.typedComparisonValue = typedComparisonValue
        self.comparisonRead = comparisonRead
        self.comparisonRowsRead = comparisonRowsRead
        self.historyValue = historyValue
        self.referencesValue = referencesValue
        self.referencesByRoot = referencesByRoot
        self.referencesProbe = referencesProbe
        self.historyPageRequestHandler = historyPageRequestHandler
        self.historyPageValues = historyPageValues
        self.historyPageHandler = historyPageHandler
        self.historyPageByReferenceHandler = historyPageByReferenceHandler
        self.repositoryHistoryProbe = repositoryHistoryProbe
        self.graphHistoryProbe = graphHistoryProbe
        self.historyController = historyController
        self.worktreeHistoryProbe = worktreeHistoryProbe
        self.filesValue = filesValue
        self.untrackedDiffDocumentValue = untrackedDiffDocumentValue
        self.comparisonDiffDocumentValue = comparisonDiffDocumentValue
        self.typedComparisonDiffDocumentValue = typedComparisonDiffDocumentValue
        self.snapshotGate = snapshotGate
        self.discardHandler = discardHandler
        self.discardAllHandler = discardAllHandler
        self.diffPatchHandler = diffPatchHandler
        self.applyPatchHandler = applyPatchHandler
        self.stageResult = stageResult
        self.stageHandler = stageHandler
        self.unstageHandler = unstageHandler
        self.commitResult = commitResult
        self.commitCallRecorder = commitCallRecorder
        self.stageCallRecorder = stageCallRecorder
        self.gitlinkPathsByRoot = gitlinkPathsByRoot
        self.workspaceCommitProbe = workspaceCommitProbe ?? WorkspaceCommitProbe()
        self.revertHandler = revertHandler
        self.runGate = runGate
        self.filesRecorder = filesRecorder
        self.filesGate = filesGate
        self.createTagResult = createTagResult
        self.deleteTagResult = deleteTagResult
        self.deleteTagResults = deleteTagResults
        self.tagCallRecorder = tagCallRecorder
        self.createBranchResult = createBranchResult
        self.deleteBranchResult = deleteBranchResult
        self.deleteBranchResults = deleteBranchResults
        self.updateBranchResult = updateBranchResult
        self.branchCallRecorder = branchCallRecorder
        self.exportPatchHandler = exportPatchHandler
        self.removeWorktreeResult = removeWorktreeResult
        self.fetchPlanValue = fetchPlan
        self.fetchHandler = fetchHandler
        self.pushPreviewHandler = pushPreviewHandler
        self.pushReviewedHandler = pushReviewedHandler
    }

    func pushPreview(_ reference: GitReference, pushTarget: GitPushTargetChoice?, at rootURL: URL) -> Result<GitPushPreview, GitPushFailure> {
        pushPreviewHandler?(reference, pushTarget, rootURL) ?? .failure(GitPushFailure("Push preview unavailable"))
    }

    func pushReviewed(_ reference: GitReference, preview: GitPushPreview, pushTarget: GitPushTargetChoice?, at rootURL: URL) -> GitProcessResult? {
        pushReviewedHandler?(reference, preview, pushTarget)
    }

    func exportPatch(at rootURL: URL, source: GitPatchSource, paths: [String], base: String?, target: String?, metadataOnly: Bool) -> Result<GitPatchExport, GitPatchFailure> {
        exportPatchHandler?(paths, metadataOnly) ?? .failure(GitPatchFailure("Patch export unavailable"))
    }

    func run(arguments: [String], workingDirectory: String, input: String?) -> GitProcessResult {
        runGate?.blockFirstRun()
        let standardOutput: String
        if arguments == ["ls-files", "--stage", "-z"] {
            let paths = gitlinkPathsByRoot[URL(fileURLWithPath: workingDirectory).standardizedFileURL.path] ?? []
            standardOutput = paths.map { "160000 abc123 0\t\($0)\0" }.joined()
        } else {
            standardOutput = "git version 2.55.0\n"
        }
        return GitProcessResult(
            arguments: arguments,
            output: standardOutput,
            standardOutput: standardOutput,
            standardError: "",
            exitCode: 0
        )
    }

    func snapshot(at rootURL: URL) -> GitSnapshot? {
        _ = snapshotGate?.waitSynchronously()
        if let snapshotHandler { return snapshotHandler(rootURL) }
        if let snapshot = snapshotsByRoot[rootURL.standardizedFileURL.path] {
            return snapshot
        }
        return snapshotValue
    }
    func repositories(in workspaceURL: URL) -> [URL] {
        repositoryRoots ?? (snapshot(at: workspaceURL).map { [$0.repositoryRoot] } ?? [])
    }
    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func worktrees(at rootURL: URL) -> [GitWorktree]? { nil }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? {
        untracked ? untrackedDiffDocumentValue : nil
    }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? {
        diffPatchHandler?(pathspecs, staged)
    }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { comparisonRowsRead?() ?? comparisonDiffDocumentValue }
    func comparisonDiffDocument(at rootURL: URL, reference: GitReference, targetReference: GitReference?, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { comparisonRowsRead?() ?? typedComparisonDiffDocumentValue }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? {
        applyPatchHandler?(patch, rootURL, mode)
    }
    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? {
        if let historyController {
            return historyController.history(at: rootURL, reference: reference, limit: limit)
        }
        return historyValue
    }
    func references(at rootURL: URL, operationID: String) -> GitReferenceSnapshot? {
        let resolved: GitReferenceSnapshot?
        if let referencesValue {
            resolved = referencesValue
        } else if let perRoot = referencesByRoot?[rootURL.standardizedFileURL.path] {
            resolved = perRoot
        } else if let historyValue {
            resolved = GitReferenceSnapshot(
                references: historyValue.references,
                recentReferences: historyValue.recentReferences,
                identity: historyValue.identity
            )
        } else {
            resolved = nil
        }
        guard let referencesProbe else { return resolved }
        return referencesProbe.references(at: rootURL, resolved: resolved)
    }
    func historyPage(
        at rootURL: URL,
        reference: GitReference?,
        cursor: String?,
        limit: Int,
        operationID: String
    ) -> GitHistoryPage? {
        if let historyPageRequestHandler { return historyPageRequestHandler(reference, cursor, limit) }
        if let worktreeHistoryProbe {
            return worktreeHistoryProbe.page(reference: reference, cursor: cursor, limit: limit)
        }
        if let repositoryHistoryProbe {
            return repositoryHistoryProbe.page(at: rootURL, reference: reference)
        }
        if let graphHistoryProbe {
            return graphHistoryProbe.page(reference: reference, cursor: cursor, limit: limit, operationID: operationID)
        }
        if let historyPageByReferenceHandler {
            return historyPageByReferenceHandler(reference, cursor)
        }
        if let historyPageHandler { return historyPageHandler() }
        if let historyPageValues { return historyPageValues[cursor ?? ""] }
        guard let historyValue else { return nil }
        let offset = cursor.flatMap(Int.init) ?? 0
        let commits = Array(historyValue.commits.dropFirst(offset).prefix(limit))
        let hasMore = historyValue.commits.count > offset + commits.count || historyValue.hasMore
        return GitHistoryPage(
            commits: commits,
            nextCursor: hasMore ? String(offset + commits.count) : nil,
            hasMore: hasMore
        )
    }
    func closeHistoryCursor(at rootURL: URL, cursor: String) -> Bool {
        worktreeHistoryProbe?.close(cursor)
        repositoryHistoryProbe?.close(at: rootURL, cursor: cursor)
        graphHistoryProbe?.close(cursor: cursor)
        return graphHistoryProbe != nil || repositoryHistoryProbe != nil || worktreeHistoryProbe != nil
    }
    func cancel(operationID: String) -> Bool {
        worktreeHistoryProbe?.cancel(operationID)
        graphHistoryProbe?.cancel(operationID: operationID)
        return graphHistoryProbe != nil || worktreeHistoryProbe != nil
    }
    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? {
        filesRecorder?.recordCall()
        if let filesGate {
            return filesGate.loadFiles(for: commit)
        }
        return filesValue
    }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { comparisonRead?() ?? comparisonValue }
    func comparison(from reference: GitReference, to target: GitReference, at rootURL: URL) -> GitBranchComparison? { comparisonRead?() ?? typedComparisonValue }
    func stashes(at rootURL: URL) -> [GitStash]? { nil }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { nil }
    func stage(_ change: GitChange) -> GitProcessResult? {
        stageCallRecorder?.record(change)
        return stageHandler?(change) ?? stageResult
    }
    func unstage(_ change: GitChange) -> GitProcessResult? { unstageHandler?(change) }
    func discard(_ change: GitChange) -> GitProcessResult? { discardHandler?(change) }
    func discardAll(_ change: GitChange) -> GitProcessResult? { discardAllHandler?(change) }
    func prepareWorkspaceCommit(_ request: GitWorkspaceCommitRequest) -> Result<GitWorkspaceCommitPreparation, GitWorkspaceCommitFailure> {
        workspaceCommitProbe.prepare(request)
    }
    func stepWorkspaceCommit(_ session: GitWorkspaceCommitSession) -> Result<GitWorkspaceCommitSession, GitWorkspaceCommitFailure> {
        workspaceCommitProbe.step()
    }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? {
        commitCallRecorder?.record(CommitCallRecorder.Call(root: rootURL, message: message, amend: amend))
        return commitResult
    }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { revertHandler?(hash) }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? {
        branchCallRecorder?.record(BranchCallRecorder.Call(name: name, reference: reference.fullName, checkout: checkout))
        return createBranchResult
    }
    func createWorktree(named name: String, from reference: GitReference, revision: String?, at destination: URL, repositoryRoot: URL) -> GitProcessResult? { nil }
    func removeWorktree(_ worktree: GitWorktree, force: Bool, at rootURL: URL) -> GitProcessResult? {
        removeWorktreeResult
    }
    func lockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func unlockWorktree(_ worktree: GitWorktree, at rootURL: URL) -> GitProcessResult? { nil }
    func repairWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func pruneWorktrees(at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        branchCallRecorder?.record(BranchCallRecorder.Call(name: reference.shortName, reference: reference.fullName, checkout: false))
        return deleteBranchResults?.next() ?? deleteBranchResult
    }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutAndRebase(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        GitProcessResult(
            arguments: ["checkoutAndRebase", reference.fullName],
            output: "",
            exitCode: 0
        )
    }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func updateBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? {
        branchCallRecorder?.record(BranchCallRecorder.Call(name: "update", reference: reference.fullName, checkout: false))
        return updateBranchResult
    }
    func pullRemoteReference(
        _ reference: GitReference,
        strategy: GitPullStrategy,
        at rootURL: URL
    ) -> GitProcessResult? {
        GitProcessResult(
            arguments: ["pull", strategy.rawValue, reference.fullName],
            output: "",
            exitCode: 0
        )
    }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { fetchHandler?(fetchPlanValue?.options ?? GitFetchOptions(), "default-fetch-fixture") }
    func executionSettings(_ request: GitConfigurationEdit, save: Bool) -> Result<GitExecutionSettingsSnapshot, GitFetchFailure> {
        .success(GitExecutionSettingsSnapshot(executable: nil, version: "git fixture", scope: "local", entries: [], fields: [], temporaryConfig: [],
            fetchOptions: fetchPlanValue?.options ?? GitFetchOptions(), fetchError: nil, credentialHelperEnabled: true, interactiveAuthentication: false))
    }
    func fetchPlan(options: GitFetchOptions) -> Result<GitFetchPlan, GitFetchFailure> {
        fetchPlanValue.map(Result.success) ?? .failure(GitFetchFailure("Fetch preview unavailable"))
    }
    func fetch(at rootURL: URL, options: GitFetchOptions, operationID: String) -> GitProcessResult? {
        fetchHandler?(options, operationID)
    }
    func checkout(_ reference: GitReference, at rootURL: URL, force: Bool, autoStash: Bool) -> GitProcessResult? { nil }
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] { [] }
    func operationState(at rootURL: URL) -> GitOperationState? { nil }
    func continueOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func abortOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func skipOperationStep(at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? { nil }
    func push(_ reference: GitReference, pushTarget: String?, at rootURL: URL) -> GitProcessResult? { GitProcessResult(output: "Pushed", exitCode: 0) }
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? { nil }
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func stageAll(at rootURL: URL) -> GitProcessResult? { nil }
    func createTag(named name: String, at revision: String, message: String?, rootURL: URL) -> GitProcessResult? {
        tagCallRecorder?.record(TagCallRecorder.Call(name: name, revision: revision, message: message))
        return createTagResult
    }
    func deleteTag(named name: String, rootURL: URL) -> GitProcessResult? {
        tagCallRecorder?.record(TagCallRecorder.Call(name: name, revision: "", message: nil))
        return deleteTagResults?.next() ?? deleteTagResult
    }
}

/// Synchronous GitOperations test state; the production service reads it on workers.
/// Scripted Core responses only: ordering, dependencies and retry policy are
/// exercised in Rust instead of reimplemented in this native test double.
private final class PushCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPreviewTargets: [GitPushTargetChoice?] = []
    private var recordedPushes: [(preview: GitPushPreview, target: GitPushTargetChoice?)] = []
    func recordPreview(_ target: GitPushTargetChoice?) { lock.lock(); recordedPreviewTargets.append(target); lock.unlock() }
    func recordPush(_ preview: GitPushPreview, _ target: GitPushTargetChoice?) {
        lock.lock(); recordedPushes.append((preview, target)); lock.unlock()
    }
    var previewTargets: [GitPushTargetChoice?] { lock.lock(); defer { lock.unlock() }; return recordedPreviewTargets }
    var pushes: [(preview: GitPushPreview, target: GitPushTargetChoice?)] { lock.lock(); defer { lock.unlock() }; return recordedPushes }
}

private final class PushMessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ message: String) { lock.lock(); recorded.append(message); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
}

private final class WorkspaceCommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var preparations: [GitWorkspaceCommitPreparation]
    private var steps: [GitWorkspaceCommitSession]
    private var recordedRequests: [GitWorkspaceCommitRequest] = []
    private var recordedSteps = 0
    private let started: GitModuleTestGate?
    private let release: GitModuleTestGate?
    private let prepareStarted: GitModuleTestGate?
    private let prepareRelease: GitModuleTestGate?
    init(preparations: [GitWorkspaceCommitPreparation] = [], steps: [GitWorkspaceCommitSession] = [],
        started: GitModuleTestGate? = nil, release: GitModuleTestGate? = nil,
        prepareStarted: GitModuleTestGate? = nil, prepareRelease: GitModuleTestGate? = nil) {
        self.preparations = preparations; self.steps = steps
        self.started = started; self.release = release
        self.prepareStarted = prepareStarted; self.prepareRelease = prepareRelease
    }
    func prepare(_ request: GitWorkspaceCommitRequest) -> Result<GitWorkspaceCommitPreparation, GitWorkspaceCommitFailure> {
        lock.lock()
        recordedRequests.append(request)
        let preparation = preparations.isEmpty ? nil : preparations.removeFirst()
        lock.unlock()
        prepareStarted?.open()
        guard prepareRelease?.waitSynchronously() ?? true else { return .failure(GitWorkspaceCommitFailure("Preparation gate timed out")) }
        guard let preparation else { return .failure(GitWorkspaceCommitFailure("No scripted preparation")) }
        return .success(preparation)
    }
    func step() -> Result<GitWorkspaceCommitSession, GitWorkspaceCommitFailure> {
        started?.open()
        guard release?.waitSynchronously() ?? true else { return .failure(GitWorkspaceCommitFailure("Test gate timed out")) }
        lock.lock(); defer { lock.unlock() }
        recordedSteps += 1
        guard !steps.isEmpty else { return .failure(GitWorkspaceCommitFailure("No scripted step")) }
        return .success(steps.removeFirst())
    }
    var requests: [GitWorkspaceCommitRequest] { lock.lock(); defer { lock.unlock() }; return recordedRequests }
    var stepCount: Int { lock.lock(); defer { lock.unlock() }; return recordedSteps }
}

@MainActor
private final class ChangelistStorageProbe: GitChangelistStorage {
    var states: [URL: GitLocalChangelists] = [:]
    var failLoad = false
    var failSave = false
    func load(workspace: URL) throws -> GitLocalChangelists? {
        if failLoad { throw GitWorkspaceCommitFailure("Corrupt metadata") }
        return states[workspace]
    }
    func save(_ state: GitLocalChangelists, workspace: URL) throws {
        if failSave { throw GitWorkspaceCommitFailure("Write rejected") }
        states[workspace] = state
    }
}
