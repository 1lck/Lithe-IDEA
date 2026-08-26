import Foundation
import LitheApplicationKernel
@testable import LitheGitModule
import LitheModuleAPI
import Testing

@MainActor
struct GitModuleTests {
    @Test
    func treeStatusProjectsExactFilesAndHighestPriorityDirectories() {
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
        #expect(projection.kind(relativePath: "Sources/Feature", isDirectory: true) == .conflicted)
        #expect(projection.kind(relativePath: "Sources", isDirectory: true) == .conflicted)
        #expect(projection.kind(relativePath: "Tests", isDirectory: true) == nil)
        #expect(projection.kind(relativePath: "", isDirectory: true) == .conflicted)
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
            date: "2026-08-18T00:00:00+08:00",
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
            comparisonValue: payload
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

private struct TestGitOperations: GitOperations {
    private let snapshotValue: GitSnapshot?
    private let comparisonValue: GitBranchComparison?
    private let untrackedDiffDocumentValue: DiffDocument?
    private let comparisonDiffDocumentValue: DiffDocument?

    init(
        snapshotValue: GitSnapshot? = nil,
        comparisonValue: GitBranchComparison? = nil,
        untrackedDiffDocumentValue: DiffDocument? = nil,
        comparisonDiffDocumentValue: DiffDocument? = nil
    ) {
        self.snapshotValue = snapshotValue
        self.comparisonValue = comparisonValue
        self.untrackedDiffDocumentValue = untrackedDiffDocumentValue
        self.comparisonDiffDocumentValue = comparisonDiffDocumentValue
    }

    func snapshot(at rootURL: URL) -> GitSnapshot? { snapshotValue }
    func watchContext(at rootURL: URL) -> GitWatchContext? { nil }
    func diffDocument(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> DiffDocument? {
        untracked ? untrackedDiffDocumentValue : nil
    }
    func diffPatch(at rootURL: URL, pathspecs: [String], staged: Bool, untracked: Bool, whitespace: GitDiffWhitespaceMode) -> String? { nil }
    func commitDiffDocument(at rootURL: URL, commit: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { nil }
    func comparisonDiffDocument(at rootURL: URL, reference: String, pathspecs: [String], whitespace: GitDiffWhitespaceMode) -> DiffDocument? { comparisonDiffDocumentValue }
    func applyPatch(_ patch: String, at rootURL: URL, mode: String) -> GitProcessResult? { nil }
    func history(at rootURL: URL, reference: GitReference?, limit: Int) -> GitHistorySnapshot? { nil }
    func files(in commit: GitCommit, at rootURL: URL) -> [GitCommitFile]? { nil }
    func commit(at rootURL: URL, hash: String) -> GitCommit? { nil }
    func comparison(for reference: GitReference, at rootURL: URL) -> GitBranchComparison? { comparisonValue }
    func stashes(at rootURL: URL) -> [GitStash]? { nil }
    func blame(at rootURL: URL, relativePath: String) -> [GitBlameLine]? { nil }
    func stage(_ change: GitChange) -> GitProcessResult? { nil }
    func unstage(_ change: GitChange) -> GitProcessResult? { nil }
    func discard(_ change: GitChange) -> GitProcessResult? { nil }
    func discardAll(_ change: GitChange) -> GitProcessResult? { nil }
    func commit(at rootURL: URL, message: String, amend: Bool) -> GitProcessResult? { nil }
    func cherryPick(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func revert(_ hash: String, at rootURL: URL) -> GitProcessResult? { nil }
    func resetCurrentBranch(to hash: String, mode: String, at rootURL: URL) -> GitProcessResult? { nil }
    func createBranch(named name: String, from reference: GitReference, checkout: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func renameBranch(_ reference: GitReference, to name: String, at rootURL: URL) -> GitProcessResult? { nil }
    func deleteBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func mergeBranch(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func rebaseCurrentBranch(onto reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func updateCurrentBranch(at rootURL: URL, strategy: GitPullStrategy) -> GitProcessResult? { nil }
    func pullPreflight(at rootURL: URL) -> GitPullPreflightState? { nil }
    func conflictMarkerPaths(at rootURL: URL) -> [String] { [] }
    func integrationPreflight(for target: GitIntegrationTarget, operation: GitIntegrationOperation, at rootURL: URL) -> GitIntegrationPreflightState? { nil }
    func fetch(at rootURL: URL) -> GitProcessResult? { nil }
    func checkout(_ reference: GitReference, at rootURL: URL, force: Bool, autoStash: Bool) -> GitProcessResult? { nil }
    func checkoutBlockingPaths(for reference: GitReference, at rootURL: URL) -> [String] { [] }
    func operationState(at rootURL: URL) -> GitOperationState? { nil }
    func continueOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func abortOperation(at rootURL: URL) -> GitProcessResult? { nil }
    func skipOperationStep(at rootURL: URL) -> GitProcessResult? { nil }
    func checkoutRevision(_ revision: String, at rootURL: URL) -> GitProcessResult? { nil }
    func push(_ reference: GitReference, at rootURL: URL) -> GitProcessResult? { nil }
    func cloneRepository(from remote: String, to destination: URL) -> GitProcessResult? { nil }
    func stash(message: String, includeUntracked: Bool, at rootURL: URL) -> GitProcessResult? { nil }
    func applyStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func popStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func dropStash(_ stash: GitStash, at rootURL: URL) -> GitProcessResult? { nil }
    func stageAll(at rootURL: URL) -> GitProcessResult? { nil }
}
