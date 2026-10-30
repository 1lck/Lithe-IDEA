import Foundation
@testable import LitheGitModule
import LitheSearchModule
import Testing
@testable import Lithe

@Suite("Git status observation", .serialized)
struct GitStatusObservationTests {
    @Test @MainActor
    func realGitCommitFilesPreparesOnlySelectedFilesAndPreservesTheirPartialIndex() async throws {
        let fixture = try GitObservationFixture(label: "prepare-commit-files")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        let head = try await fixture.git(["rev-parse", "HEAD"], at: root)
        try Data("staged content\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("unrelated staged content\n".utf8).write(to: root.appendingPathComponent("excluded.txt"))
        try await fixture.git(["add", "."], at: root)
        try Data("unstaged content\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("selected new content\n".utf8).write(to: root.appendingPathComponent("included.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let selected = feature.gitChanges.filter { ["tracked.txt", "included.txt"].contains($0.path) }
        #expect(selected.count == 2 && feature.canPrepareCommitFiles(selected))
        #expect(await feature.prepareCommitFiles(selected))
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root) == "included.txt\ntracked.txt")
        #expect(try await fixture.git(["show", ":tracked.txt"], at: root) == "staged content")
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "unstaged content\n")
        #expect(try String(contentsOf: root.appendingPathComponent("excluded.txt"), encoding: .utf8) == "unrelated staged content\n")
        #expect(try await fixture.git(["rev-parse", "HEAD"], at: root) == head, "Preparation never creates a commit")
    }

    @Test @MainActor
    func realGitCommitFilesAcceptsAnUntrackedDirectoryExpandingIntoIndexEntries() async throws {
        let fixture = try GitObservationFixture(label: "prepare-commit-directory")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new/sub"), withIntermediateDirectories: true)
        let paths = ["new/sub/two.txt"] + (1...101).map { "new/file-\($0).txt" }
        for path in paths {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let directory = try #require(feature.gitChanges.first { $0.isUntrackedDirectory })
        #expect(await feature.prepareCommitFiles([directory]))
        let staged = try await fixture.git(["diff", "--cached", "--name-only"], at: root)
        #expect(Set(staged.split(separator: "\n").map(String.init)) == Set(paths))
    }

    @Test @MainActor
    func realGitCommitFilesUnstagesAnExcludedCopyWithoutUnstagingItsSelectedSource() async throws {
        let fixture = try GitObservationFixture(label: "prepare-commit-copy")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try await fixture.git(["config", "status.renames", "copies"], at: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("copy.txt"))
        try Data("source staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "."], at: root)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        #expect(feature.gitChanges.contains { $0.indexStatus == "C" })
        let source = try #require(feature.gitChanges.first { $0.path == "tracked.txt" })
        #expect(await feature.prepareCommitFiles([source]))
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root) == "tracked.txt")
        #expect(try await fixture.git(["show", ":tracked.txt"], at: root) == "source staged")
        #expect(try String(contentsOf: root.appendingPathComponent("copy.txt"), encoding: .utf8) == "initial\n")
    }

    @Test @MainActor
    func realGitDeleteRefusesADirectoryContainingAnIndependentNestedRepository() async throws {
        let fixture = try GitObservationFixture(label: "delete-nested-repository")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for number in 1...101 {
            try Data("ordinary content\n".utf8).write(to: root.appendingPathComponent("folder/file-\(number).txt"))
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let directory = try #require(feature.gitChanges.first { $0.repositoryRoot == root && $0.path == "folder/" })
        // The menu captured a safe directory summary before a nested checkout
        // appeared. A fresh ownership check must protect that checkout.
        try await fixture.initializeRepository(at: root.appendingPathComponent("folder/nested"))
        var writes = 0
        #expect(await !feature.deleteCommitFiles([directory]) { writes += 1; return true })
        #expect(writes == 0 && !feature.isDeletingCommitFiles)
    }

    @Test(arguments: [false, true]) @MainActor
    func realGitDeleteRefreshesMissingAdditionsAndPreservesTrackedDeletionAndUnrelatedIndex(partialFailure: Bool) async throws {
        let fixture = try GitObservationFixture(label: "delete-refresh")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try Data("keep staged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        for path in ["deleted.txt", "retained.txt", "unrelated.txt"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        try await fixture.git(["add", "."], at: root)
        try Data("keep unstaged\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let targets = feature.gitChanges.filter { ["deleted.txt", "retained.txt", "untracked.txt", "tracked.txt"].contains($0.path) }
        #expect(targets.count == 4)
        // Only fixture files are removed; native Trash ownership is tested separately.
        let result = await feature.deleteCommitFiles(targets) {
            for path in ["deleted.txt", "untracked.txt"] + (partialFailure ? [] : ["retained.txt", "tracked.txt"]) {
                do { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
                catch { Issue.record(error); return false }
            }
            return !partialFailure
        }
        #expect(result != partialFailure)
        #expect(!feature.gitChanges.contains { ["deleted.txt", "untracked.txt"].contains($0.path) })
        #expect(feature.gitChanges.contains { $0.path == "retained.txt" } == partialFailure)
        let tracked = try #require(feature.gitChanges.first { $0.path == "tracked.txt" })
        #expect(tracked.workTreeStatus == (partialFailure ? "M" : "D"))
        #expect(try await fixture.git(["show", ":tracked.txt"], at: root) == "keep staged")
        #expect(try await fixture.git(["show", ":unrelated.txt"], at: root) == "unrelated.txt")
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root)
            == (partialFailure ? "retained.txt\ntracked.txt\nunrelated.txt" : "tracked.txt\nunrelated.txt"))
    }

    @Test @MainActor
    func realGitDeleteOfACopyNeverUnstagesItsIndependentlyModifiedSource() async throws {
        let fixture = try GitObservationFixture(label: "delete-copy-refresh")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try await fixture.git(["config", "status.renames", "copies"], at: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("copy.txt"))
        try Data("staged source\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "."], at: root)
        try Data("unstaged source\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let copy = try #require(feature.gitChanges.first { $0.path == "copy.txt" && $0.indexStatus == "C" })
        #expect(await feature.deleteCommitFiles([copy]) {
            do { try FileManager.default.removeItem(at: root.appendingPathComponent("copy.txt")); return true }
            catch { Issue.record(error); return false }
        })
        #expect(feature.gitChanges.map(\.path) == ["tracked.txt"])
        #expect(try await fixture.git(["show", ":tracked.txt"], at: root) == "staged source")
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "unstaged source\n")
    }

    @Test
    @MainActor
    func realGitRollbackCheckedFilesRestoresIndexAndWorktreeButNotUncheckedEdits() async throws {
        let fixture = try GitObservationFixture(label: "rollback-checked")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        for path in ["second.txt", "unchecked.txt"] {
            try Data("initial\n".utf8).write(to: root.appendingPathComponent(path))
        }
        try await fixture.git(["add", "."], at: root)
        try await fixture.git(["commit", "-qm", "three files"], at: root)
        for path in ["tracked.txt", "second.txt", "unchecked.txt"] {
            try Data("staged edit\n".utf8).write(to: root.appendingPathComponent(path))
        }
        try await fixture.git(["add", "tracked.txt", "second.txt"], at: root)
        try Data("partially staged edit\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let included = GitRollbackSelection.initialTargets(changes: feature.gitChanges, selectedIDs: [])
        #expect(Set(included.map(\.path)) == ["tracked.txt", "second.txt"])
        let before = try await fixture.git(["diff", "--cached"], at: root)
        feature.requestRollbackChanges(feature.gitChanges, included: included)
        feature.cancelRollbackChanges()
        #expect(try await fixture.git(["diff", "--cached"], at: root) == before)
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "partially staged edit\n")
        feature.requestRollbackChanges(feature.gitChanges, included: included)
        let captured = try #require(feature.pendingRollbackSelection)
        feature.cancelRollbackChanges()
        await feature.confirmRollbackChanges(captured)
        for path in ["tracked.txt", "second.txt"] {
            #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "initial\n")
        }
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root).isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("unchecked.txt"), encoding: .utf8) == "staged edit\n")
        #expect(feature.gitChanges.map(\.path) == ["unchecked.txt"])
    }

    @Test(arguments: [false, true])
    @MainActor
    func realGitRollbackAddedFilesRequiresExplicitDeletion(deleteAdded: Bool) async throws {
        let fixture = try GitObservationFixture(label: "rollback-added")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        for path in ["added.txt", "untracked.txt", "intent.txt"] {
            try Data("keep new content\n".utf8).write(to: root.appendingPathComponent(path))
        }
        try await fixture.git(["add", "added.txt"], at: root)
        try await fixture.git(["add", "-N", "intent.txt"], at: root)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        feature.requestRollbackChanges(feature.gitChanges, included: feature.gitChanges)
        var captured = try #require(feature.pendingRollbackSelection)
        #expect(!captured.deleteAddedFiles && captured.hasIncludedAdditions)
        captured.deleteAddedFiles = deleteAdded
        await feature.confirmRollbackChanges(captured)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root).isEmpty)
        for path in ["added.txt", "untracked.txt", "intent.txt"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) != deleteAdded)
            if !deleteAdded {
                #expect(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) == "keep new content\n")
            }
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func realGitRollbackCopyNeverRestoresOrUnstagesItsUncheckedSource(deleteAdded: Bool) async throws {
        let fixture = try GitObservationFixture(label: "rollback-copy")
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        try await fixture.git(["config", "status.renames", "copies"], at: root)
        try Data("initial\n".utf8).write(to: root.appendingPathComponent("copy.txt"))
        try Data("staged source edit\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "."], at: root)
        try Data("unstaged source edit\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        let copy = try #require(feature.gitChanges.first { $0.indexStatus == "C" })
        #expect(copy.path == "copy.txt" && copy.originalPath == "tracked.txt")
        let before = try await fixture.git(["diff", "--cached", "--", "tracked.txt"], at: root)
        feature.requestRollbackChanges(feature.gitChanges, included: [copy])
        var captured = try #require(feature.pendingRollbackSelection)
        #expect(captured.hasIncludedAdditions)
        captured.deleteAddedFiles = deleteAdded
        await feature.confirmRollbackChanges(captured)
        #expect(try await fixture.git(["diff", "--cached", "--", "tracked.txt"], at: root) == before)
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "unstaged source edit\n")
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: root) == "tracked.txt")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("copy.txt").path) != deleteAdded)
    }

    @Test(arguments: ["rename", "delete", "retained-delete"])
    @MainActor
    func realGitRollbackRestoresRenameAndDeletionIncludingRetainedDiskCopy(kind: String) async throws {
        let fixture = try GitObservationFixture(label: "rollback-" + kind)
        let root = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: root)
        if kind == "rename" { try await fixture.git(["mv", "tracked.txt", "renamed.txt"], at: root) }
        else if kind == "delete" { try await fixture.git(["rm", "tracked.txt"], at: root) }
        else {
            try await fixture.git(["rm", "--cached", "tracked.txt"], at: root)
            try Data("retained edit\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        feature.requestRollbackChanges(feature.gitChanges, included: feature.gitChanges)
        await feature.confirmRollbackChanges(try #require(feature.pendingRollbackSelection))
        #expect(try String(contentsOf: root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "initial\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        #expect(try await fixture.git(["status", "--porcelain"], at: root).isEmpty)
    }

    @Test
    @MainActor
    func realGitRollbackLinkedWorktreeNeverChangesPrimaryIndexOrFiles() async throws {
        let fixture = try GitObservationFixture(label: "rollback-worktree")
        let primary = fixture.url.appendingPathComponent("primary", isDirectory: true)
        let linked = fixture.url.appendingPathComponent("linked", isDirectory: true)
        try await fixture.initializeRepository(at: primary)
        try await fixture.git(["worktree", "add", "-qb", "rollback-test", linked.path], at: primary)
        for root in [primary, linked] {
            try Data("staged edit\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try await fixture.git(["add", "tracked.txt"], at: root)
        }
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { primary }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        let worktree = try #require(feature.gitWorktrees.first { $0.url.standardizedFileURL == linked })
        await feature.inspectWorktree(worktree)
        let scoped = feature.commitFeature(for: worktree)
        scoped.requestRollbackChanges(scoped.gitChanges, included: scoped.gitChanges)
        await scoped.confirmRollbackChanges(try #require(scoped.pendingRollbackSelection))
        #expect(try await fixture.git(["status", "--porcelain"], at: linked).isEmpty)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: primary) == "tracked.txt")
        #expect(try String(contentsOf: primary.appendingPathComponent("tracked.txt"), encoding: .utf8) == "staged edit\n")
    }

    @Test(arguments: [false, true])
    @MainActor
    func realGitWorktreeRefreshAndStageAllExcludeIndependentNestedRepositories(linkedCheckout: Bool) async throws {
        let fixture = try GitObservationFixture(label: "worktree-nested-repository")
        let primary = fixture.url.appendingPathComponent("primary", isDirectory: true)
        let linked = fixture.url.appendingPathComponent("linked", isDirectory: true)
        try await fixture.initializeRepository(at: primary)
        try await fixture.git(["config", "user.name", "Lithe Tests"], at: primary)
        try await fixture.git(["config", "user.email", "tests@lithe.local"], at: primary)
        try await fixture.git(["config", "commit.gpgsign", "false"], at: primary)
        try await fixture.git(["config", "core.hooksPath", "/dev/null"], at: primary)
        try await fixture.git(["worktree", "add", "-q", "-b", "nested-test", linked.path], at: primary)
        let checkout = linkedCheckout ? linked : primary
        let nested = checkout.appendingPathComponent("nested", isDirectory: true)
        try await fixture.initializeRepository(at: nested)
        try Data("nested staged edit\n".utf8).write(to: nested.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "tracked.txt"], at: nested)
        let nestedHEAD = try await fixture.git(["rev-parse", "HEAD"], at: nested)
        let nestedIndex = try await fixture.git(["ls-files", "--stage"], at: nested)
        try Data("checkout edit\n".utf8).write(to: checkout.appendingPathComponent("tracked.txt"))
        try Data("checkout addition\n".utf8).write(to: checkout.appendingPathComponent("new.txt"))
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { primary }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        let worktree = try #require(feature.gitWorktrees.first { $0.url.standardizedFileURL == checkout })
        let expectedPaths: Set<String> = ["tracked.txt", "new.txt"]
        await feature.inspectWorktree(worktree)
        #expect(Set(feature.gitWorktreeInspection?.changes.map(\.path) ?? []) == expectedPaths)
        await feature.refreshWorktreeChanges(worktree)
        #expect(Set(feature.gitWorktreeInspection?.changes.map(\.path) ?? []) == expectedPaths)
        await feature.refreshWorktrees()
        #expect(Set(feature.gitWorktreeInspection?.changes.map(\.path) ?? []) == expectedPaths)
        let scoped = feature.commitFeature(for: worktree)
        #expect(Set(scoped.gitChanges.map(\.path)) == expectedPaths)
        // Worktrees' toolbar stages through the host; Commit's checkbox batch
        // uses the scoped model. Neither entry point may add the nested root.
        await feature.setWorktreeStaging(scoped.activeChangelistChanges, staged: true, in: worktree)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: checkout) == "new.txt\ntracked.txt")
        #expect(try await !fixture.git(["ls-files", "--stage"], at: checkout).contains("160000"))
        let staged = try #require(feature.gitWorktreeInspection?.changes)
        await feature.setWorktreeStaging(staged, staged: false, in: worktree)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: checkout).isEmpty)
        await scoped.refreshGit()
        #expect(scoped.availableRepositoryRoots == [checkout])
        #expect(Set(scoped.gitChanges.map(\.path)) == expectedPaths)
        let stageAll = scoped.beginSetStaging(scoped.activeChangelistChanges, staged: true, includeWorkingTreeChanges: true)
        await scoped.finishSetStaging(stageAll, staged: true)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: checkout) == "new.txt\ntracked.txt")
        #expect(try await !fixture.git(["ls-files", "--stage"], at: checkout).contains("160000"))
        #expect(await scoped.commitStagedChanges(message: "Keep nested repository independent", amend: false))
        #expect(try await fixture.git(["log", "-1", "--format=%s"], at: checkout) == "Keep nested repository independent")
        #expect(try await !fixture.git(["ls-tree", "-r", "HEAD"], at: checkout).contains("160000"))
        #expect(!FileManager.default.fileExists(atPath: checkout.appendingPathComponent(".gitmodules").path))
        #expect(try await fixture.git(["rev-parse", "HEAD"], at: nested) == nestedHEAD)
        #expect(try await fixture.git(["ls-files", "--stage"], at: nested) == nestedIndex)
        #expect(scoped.gitChanges.isEmpty && feature.gitWorktreeInspection?.changes.isEmpty == true)
    }

    @Test
    @MainActor
    func realGitWorktreeComposerCommitsOnlySelectedCheckout() async throws {
        let fixture = try GitObservationFixture(label: "worktree-composer")
        let primary = fixture.url.appendingPathComponent("primary", isDirectory: true)
        let linked = fixture.url.appendingPathComponent("linked", isDirectory: true)
        try await fixture.initializeRepository(at: primary)
        try await fixture.git(["config", "user.name", "Lithe Tests"], at: primary)
        try await fixture.git(["config", "user.email", "tests@lithe.local"], at: primary)
        try await fixture.git(["config", "commit.gpgsign", "false"], at: primary)
        try await fixture.git(["config", "core.hooksPath", "/dev/null"], at: primary)
        try await fixture.git(["worktree", "add", "-q", "-b", "composer", linked.path], at: primary)
        for root in [primary, linked] {
            try Data("Changed in \(root.lastPathComponent)\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
            try await fixture.git(["add", "tracked.txt"], at: root)
        }
        let originalHEAD = try await fixture.git(["rev-parse", "HEAD"], at: primary)
        let feature = GitFeatureModel(service: GitService(operations: RustGitOperations(core: RustCoreBridge())))
        feature.configure(workspaceURLProvider: { primary }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})
        defer { feature.reset() }
        await feature.refreshGit()
        await feature.refreshWorktrees()
        let worktree = try #require(feature.gitWorktrees.first { $0.url.standardizedFileURL == linked })
        await feature.inspectWorktree(worktree)
        let scoped = feature.commitFeature(for: worktree)
        #expect(scoped.activeChangelistChanges.contains { $0.isStaged })
        #expect(await scoped.commitStagedChanges(message: "Selected checkout only", amend: false))
        #expect(try await fixture.git(["rev-parse", "HEAD"], at: primary) == originalHEAD)
        #expect(try await fixture.git(["diff", "--cached", "--name-only"], at: primary) == "tracked.txt")
        #expect(try await fixture.git(["rev-parse", "HEAD"], at: linked) != originalHEAD)
        #expect(try await fixture.git(["log", "-1", "--format=%s"], at: linked) == "Selected checkout only")
        #expect(try await fixture.git(["status", "--porcelain"], at: linked).isEmpty)
        #expect(feature.gitRepositoryRoot == primary && scoped.gitChanges.isEmpty)
        #expect(feature.gitWorktreeInspection?.changes.isEmpty == true)
    }

    @Test(arguments: [false, true])
    @MainActor
    func realGitRemovedFromIndexFileRefreshesWithoutCrashing(staged: Bool) async throws {
        // Exercise real Git -> Rust Core -> Swift feature refresh, using the
        // valid duplicate-path status that triggered issue #1033 on project open.
        let fixture = try GitObservationFixture(label: "removed-from-index")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        try await fixture.git(["rm", "--cached", "tracked.txt"], at: repository)
        let model = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge()))
        )
        defer { model.reset() }
        model.configure(workspaceURLProvider: { repository }, isGitLogVisibleProvider: { false },
            notify: { _ in }, onStateRefreshed: {})

        await model.refreshGit()

        #expect(model.gitChanges.count == 2)
        #expect(model.gitChanges.allSatisfy { $0.path == "tracked.txt" })
        #expect(Set(model.gitChanges.map(\.id)).count == 1)
        #expect(model.gitChanges.filter(\.isStaged).count == 1)
        #expect(model.gitChanges.filter(\.isUntracked).count == 1)
        let initialChanges = model.gitChanges
        await model.refreshGit()
        #expect(model.gitChanges == initialChanges)
        #expect(!model.isStagingChanges)

        let target = try #require(model.gitChanges.first { $0.isStaged != staged })
        #expect(model.beginToggleStaging(target) == staged)
        await model.finishToggleStaging(target, staged: staged)

        // Both restoring the original index entry and adding the unchanged
        // retained file leave a clean repository with no status records.
        #expect(model.gitChanges.isEmpty)
        #expect(!model.isStagingChanges)
    }

    @Test
    @MainActor
    func identicalGitRefreshSkipsExpensiveDownstreamWork() async {
        let repository = URL(fileURLWithPath: "/tmp/lithe-identical-git-refresh")
        let snapshot = GitSnapshot(
            repositoryRoot: repository,
            branch: "main",
            changes: [
                GitChange(
                    repositoryRoot: repository,
                    path: "tracked.txt",
                    originalPath: nil,
                    indexStatus: " ",
                    workTreeStatus: "M"
                )
            ]
        )
        let model = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            snapshotProvider: { _ in snapshot },
            stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil },
            diffDocumentProvider: { _, _ in DiffDocument(rows: [], hunks: []) }
        )
        var downstreamRefreshCount = 0
        model.configure(
            workspaceURLProvider: { repository },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: { downstreamRefreshCount += 1 }
        )

        await model.refreshGit()
        #expect(downstreamRefreshCount == 1)

        await model.refreshGit()
        #expect(downstreamRefreshCount == 1)
    }

    @Test
    @MainActor
    func pendingRefreshTakesOverAfterRunningRefreshIsCancelled() async {
        let repository = URL(fileURLWithPath: "/tmp/lithe-cancelled-git-refresh")
        let snapshotProvider = ControlledGitSnapshotProvider()
        let model = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            snapshotProvider: { _ in await snapshotProvider.nextSnapshot() },
            stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil },
            diffDocumentProvider: { _, _ in DiffDocument(rows: [], hunks: []) }
        )
        model.configure(
            workspaceURLProvider: { repository },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        let firstRefresh = Task { @MainActor in await model.refreshGit() }
        #expect(await snapshotProvider.waitForRequestCount(1))

        let pendingRefresh = Task { @MainActor in await model.refreshGit() }
        await Task.yield()
        firstRefresh.cancel()
        await snapshotProvider.resumeNext(
            with: GitSnapshot(repositoryRoot: repository, branch: "stale", changes: [])
        )
        await firstRefresh.value

        let pendingRefreshTookOver = await snapshotProvider.waitForRequestCount(2)
        #expect(pendingRefreshTookOver)
        if pendingRefreshTookOver {
            await snapshotProvider.resumeNext(
                with: GitSnapshot(repositoryRoot: repository, branch: "current", changes: [])
            )
        } else {
            pendingRefresh.cancel()
        }
        await pendingRefresh.value

        #expect(model.currentBranch == "current")
    }

    @Test
    @MainActor
    func cancelledPendingRefreshDoesNotScheduleAnotherPass() async {
        let repository = URL(fileURLWithPath: "/tmp/lithe-cancelled-pending-git-refresh")
        let snapshotProvider = ControlledGitSnapshotProvider()
        let model = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge())),
            snapshotProvider: { _ in await snapshotProvider.nextSnapshot() },
            stashesProvider: { _ in [] },
            operationStateProvider: { _ in nil },
            diffDocumentProvider: { _, _ in DiffDocument(rows: [], hunks: []) }
        )
        model.configure(
            workspaceURLProvider: { repository },
            isGitLogVisibleProvider: { false },
            notify: { _ in },
            onStateRefreshed: {}
        )

        let runningRefresh = Task { @MainActor in await model.refreshGit() }
        #expect(await snapshotProvider.waitForRequestCount(1))

        let cancelledRefresh = Task { @MainActor in await model.refreshGit() }
        await Task.yield()
        cancelledRefresh.cancel()
        await cancelledRefresh.value
        await snapshotProvider.resumeNext(
            with: GitSnapshot(repositoryRoot: repository, branch: "current", changes: [])
        )

        let scheduledAnotherPass = await snapshotProvider.waitForRequestCount(
            2,
            timeout: .milliseconds(200)
        )
        if scheduledAnotherPass {
            await snapshotProvider.resumeNext(
                with: GitSnapshot(repositoryRoot: repository, branch: "unexpected", changes: [])
            )
        }
        await runningRefresh.value

        #expect(!scheduledAnotherPass)
        #expect(model.currentBranch == "current")
    }

    @Test
    @MainActor
    func visibleWorkspaceEditStillUsesTheWorkspacePipelineAndRefreshesGit() async throws {
        let fixture = try GitObservationFixture(label: "visible-edit")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: repository, recorder: recorder)

        let tracked = repository.appendingPathComponent("tracked.txt")
        try Data("changed\n".utf8).write(to: tracked)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed)
        #expect(recorder.externalChangeBatches.flatMap { $0 }.contains(tracked.standardizedFileURL))
    }

    @Test
    @MainActor
    func externalCommitRefreshesGitWithoutEnteringTheWorkspacePipeline() async throws {
        let fixture = try GitObservationFixture(label: "ordinary-commit")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        try Data("staged\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "tracked.txt"], at: repository)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: repository, recorder: recorder)

        try await fixture.git(["commit", "-q", "-m", "external commit"], at: repository)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "A metadata-only commit must request a Git refresh")
        try await Task.sleep(for: .milliseconds(750))
        #expect(recorder.gitRefreshCount == 1, "A commit event burst should be coalesced")
        #expect(recorder.externalChangeBatches.isEmpty)
        #expect(recorder.projectServiceReloadCount == 0)
    }

    @Test
    @MainActor
    func trackedFileInsideHiddenDirectoryRefreshesOnlyGit() async throws {
        let fixture = try GitObservationFixture(label: "hidden-tracked-file")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        let hiddenDirectory = repository.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent("bundle.js")
        try Data("initial\n".utf8).write(to: hiddenFile)
        try await fixture.git(["add", "dist/bundle.js"], at: repository)
        try await fixture.git(["commit", "-q", "-m", "track hidden output"], at: repository)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: repository, recorder: recorder)

        try Data("changed\n".utf8).write(to: hiddenFile)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "Tracked hidden paths still affect Git status")
        #expect(recorder.externalChangeBatches.isEmpty)
        #expect(recorder.projectServiceReloadCount == 0)
    }

    @Test
    @MainActor
    func linkedWorktreeStageRefreshesGitFromItsExternalGitDirectory() async throws {
        let fixture = try GitObservationFixture(label: "linked-worktree")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        let worktree = fixture.url.appendingPathComponent("linked-worktree", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        try await fixture.git(
            ["worktree", "add", "-q", "-b", "observation-worktree", worktree.path],
            at: repository
        )
        try Data("changed\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: worktree, recorder: recorder)

        try await fixture.git(["add", "tracked.txt"], at: worktree)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "A linked worktree index lives outside the workspace root")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func separateGitDirectoryStageRefreshesGit() async throws {
        let fixture = try GitObservationFixture(label: "separate-git-dir")
        let workspace = fixture.url.appendingPathComponent("workspace", isDirectory: true)
        let gitDirectory = fixture.url.appendingPathComponent("metadata/repository.git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: gitDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await fixture.git(
            ["init", "-q", "--separate-git-dir=\(gitDirectory.path)", workspace.path],
            at: fixture.url
        )
        try Data("initial\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "tracked.txt"], at: workspace)
        try await fixture.git(["commit", "-q", "-m", "initial"], at: workspace)
        try Data("changed\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: workspace, recorder: recorder)

        try await fixture.git(["add", "tracked.txt"], at: workspace)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "A separate Git directory must be observed outside the workspace")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func directlyOpenedSubmoduleStageRefreshesItsOwnGitState() async throws {
        let fixture = try GitObservationFixture(label: "direct-submodule")
        let source = fixture.url.appendingPathComponent("source", isDirectory: true)
        let parent = fixture.url.appendingPathComponent("parent", isDirectory: true)
        try await fixture.initializeRepository(at: source)
        try await fixture.initializeRepository(at: parent)
        try await fixture.git(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                source.path, "modules/child"
            ],
            at: parent
        )
        try await fixture.git(["commit", "-q", "-am", "add submodule"], at: parent)
        let submodule = parent.appendingPathComponent("modules/child", isDirectory: true)
        try Data("changed\n".utf8).write(to: submodule.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: submodule, recorder: recorder)

        try await fixture.git(["add", "tracked.txt"], at: submodule)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "A submodule index lives in the parent repository metadata")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func parentRepositoryRefreshesWhenSubmoduleHeadAdvances() async throws {
        let fixture = try GitObservationFixture(label: "parent-submodule")
        let source = fixture.url.appendingPathComponent("source", isDirectory: true)
        let parent = fixture.url.appendingPathComponent("parent", isDirectory: true)
        try await fixture.initializeRepository(at: source)
        try await fixture.initializeRepository(at: parent)
        try await fixture.git(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                source.path, "modules/child"
            ],
            at: parent
        )
        try await fixture.git(["commit", "-q", "-am", "add submodule"], at: parent)
        let submodule = parent.appendingPathComponent("modules/child", isDirectory: true)
        try Data("changed\n".utf8).write(to: submodule.appendingPathComponent("tracked.txt"))
        try await fixture.git(["add", "tracked.txt"], at: submodule)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: parent, recorder: recorder)

        try await fixture.git(["commit", "-q", "-m", "advance submodule"], at: submodule)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "The parent repository must refresh its submodule gitlink state")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func editOutsideOpenedSubdirectoryRefreshesRepositoryGitStateOnly() async throws {
        let fixture = try GitObservationFixture(label: "repository-subdirectory")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try await fixture.initializeRepository(at: repository)
        let workspace = repository.appendingPathComponent("apps/opened", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("inside\n".utf8).write(to: workspace.appendingPathComponent("inside.txt"))
        try Data("outside\n".utf8).write(to: repository.appendingPathComponent("outside.txt"))
        try await fixture.git(["add", "."], at: repository)
        try await fixture.git(["commit", "-q", "-m", "repository layout"], at: repository)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: workspace, recorder: recorder)

        try Data("changed outside workspace\n".utf8).write(
            to: repository.appendingPathComponent("outside.txt")
        )

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "Git status covers the repository root, not only the opened subdirectory")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func gitInitAfterWorkspaceOpenIsDiscoveredWithoutReopeningTheProject() async throws {
        let fixture = try GitObservationFixture(label: "dynamic-git-init")
        let workspace = fixture.url.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("plain workspace\n".utf8).write(to: workspace.appendingPathComponent("file.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: workspace, recorder: recorder)

        try await fixture.git(["init", "-q"], at: workspace)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "Creating .git must re-resolve the watch context and refresh Git")
        #expect(recorder.externalChangeBatches.isEmpty)
    }
    @Test
    @MainActor
    func staleSnapshotDoesNotClearOptimisticStagingState() {
        let repository = URL(fileURLWithPath: "/tmp/lithe-staging-state-test", isDirectory: true)
        let unstaged = GitChange(
            repositoryRoot: repository,
            path: "new-file.txt",
            originalPath: nil,
            indexStatus: "?",
            workTreeStatus: "?"
        )
        let staged = GitChange(
            repositoryRoot: repository,
            path: "new-file.txt",
            originalPath: nil,
            indexStatus: "A",
            workTreeStatus: " "
        )
        let model = GitFeatureModel(
            service: GitService(operations: RustGitOperations(core: RustCoreBridge()))
        )

        #expect(model.selectedChange == nil)
        #expect(model.beginToggleStaging(unstaged) == true)
        #expect(model.selectedChange == nil)
        model.reconcilePendingStagingStates(with: [unstaged], successfullyReadRepositoryRoots: [repository])
        #expect(model.effectiveStagingState(for: unstaged))

        model.reconcilePendingStagingStates(with: [staged], successfullyReadRepositoryRoots: [repository])
        #expect(model.effectiveStagingState(for: staged))
        model.selectedChange = unstaged
        #expect(model.beginToggleStaging(staged) == false)
        #expect(model.selectedChange == unstaged)
    }
}

@MainActor
private final class GitObservationRecorder {
    var gitRefreshCount = 0
    var externalChangeBatches: [[URL]] = []
    var projectServiceReloadCount = 0

    func reset() {
        gitRefreshCount = 0
        externalChangeBatches = []
        projectServiceReloadCount = 0
    }
}

private final class GitObservationFixture {
    let url: URL

    init(label: String) throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/lithe-git-observation-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.standardizedFileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func initializeRepository(at repository: URL) async throws {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await git(["init", "-q"], at: repository)
        try Data("initial\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try await git(["add", "tracked.txt"], at: repository)
        try await git(["commit", "-q", "-m", "initial"], at: repository)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) async throws -> String {
        let result = try await TestProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "user.email=tests@lithe.local", "-c", "user.name=Lithe Tests",
                        "-c", "core.autocrlf=false"] + arguments,
            currentDirectoryURL: directory
        )
        guard result.terminationStatus == 0 else {
            throw GitObservationTestError.gitFailed(
                arguments: arguments,
                output: String(decoding: result.output, as: UTF8.self)
            )
        }
        return String(decoding: result.output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor ControlledGitSnapshotProvider {
    private var continuations: [CheckedContinuation<GitSnapshot?, Never>] = []
    private var requestCount = 0

    func nextSnapshot() async -> GitSnapshot? {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForRequestCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while requestCount < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return requestCount >= expectedCount
    }

    func resumeNext(with snapshot: GitSnapshot?) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: snapshot)
    }
}

private enum GitObservationTestError: Error {
    case gitFailed(arguments: [String], output: String)
    case workspaceUnavailable
}

private struct GitObservationWatchContextProvider: GitWatchContextProviding {
    func watchContext(for workspace: URL) async -> GitWatchContext? {
        // Resolve all three paths from one Git process; each output line corresponds to an option.
        guard let result = try? await TestProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["rev-parse", "--path-format=absolute", "--show-toplevel",
                        "--absolute-git-dir", "--git-common-dir"],
            currentDirectoryURL: workspace
        ), result.terminationStatus == 0 else { return nil }
        let paths = String(decoding: result.output, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard paths.count == 3 else { return nil }
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        return GitWatchContext(repositoryRoot: urls[0], gitDirectory: urls[1], gitCommonDirectory: urls[2])
    }
}

@MainActor
private func makeObservationModel(recorder: GitObservationRecorder) -> WorkspaceFeatureModel {
    let model = WorkspaceFeatureModel(
        operations: GitObservationWorkspaceOperations(),
        fileOperations: MacWorkspaceFileOperations(),
        fileStorage: MacFileStorage(),
        gitWatchContextProvider: GitObservationWatchContextProvider(),
        directoryWatcherFactory: GitObservationDirectoryWatcherFactory(),
        workspaceSessionStore: WorkspaceSessionStore(store: GitObservationKeyValueStore())
    )
    model.configure(
        documentsProvider: { [] },
        activeDocumentProvider: { nil },
        selectedSidebarProvider: { "project" },
        setSelectedSidebar: { _ in },
        restoreSession: { _, _ in },
        openFile: { _ in },
        notify: { _ in },
        recordHistory: { _, _ in },
        relocateHistory: { _, _ in },
        relocateOpenDocuments: { _, _ in },
        closeDocuments: { _ in },
        processExternalChanges: { urls in
            recorder.externalChangeBatches.append(urls)
            return false
        },
        reloadProjectServices: {
            recorder.projectServiceReloadCount += 1
        },
        refreshGit: {
            recorder.gitRefreshCount += 1
        },
        updateHistoryVisibilityRules: { _ in },
        onSnapshotLoaded: { _, _, _ in }
    )
    return model
}

@MainActor
private func startObservation(
    _ model: WorkspaceFeatureModel,
    at workspace: URL,
    recorder: GitObservationRecorder
) async throws {
    model.beginWorkspace(at: workspace, visibilityRules: .default)
    let result = await model.rebuild(
        at: workspace,
        rules: .default,
        isCurrent: { true }
    )
    guard case .loaded = result else {
        throw GitObservationTestError.workspaceUnavailable
    }
    // Create a new path only after stream installation. Rewriting a marker
    // created before installation can coalesce with its pre-stream event and
    // be excluded by the stream's SinceNow boundary.
    // Wait for this marker to traverse the real watcher and refresh pipeline.
    let marker = workspace.appendingPathComponent("watcher-ready-\(UUID().uuidString).txt").standardizedFileURL
    let initialRefreshCount = recorder.gitRefreshCount
    try Data("ready\n".utf8).write(to: marker)
    try #require(await waitUntil {
        recorder.externalChangeBatches.flatMap { $0 }.contains(marker)
            && recorder.gitRefreshCount > initialRefreshCount
    }, "The watcher did not process its readiness marker; refreshes: \(initialRefreshCount) → \(recorder.gitRefreshCount), batches: \(recorder.externalChangeBatches)")
    recorder.reset()
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}

private struct GitObservationDirectoryWatcherFactory: DirectoryWatcherFactory {
    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        MacDirectoryWatcher(
            configuration: configuration,
            visibilityRules: visibilityRules,
            onChange: onChange
        )
    }
}

private struct GitObservationWorkspaceOperations: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        FileSystemWorkspaceSnapshotBuilder().snapshot(
            at: rootURL,
            visibilityRules: visibilityRules
        )
    }

    func search(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> [FileSearchResult]? { nil }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private struct GitObservationKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
