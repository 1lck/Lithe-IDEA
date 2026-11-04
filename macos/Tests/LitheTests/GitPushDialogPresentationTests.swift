@testable import Lithe
@testable import LitheGitModule
import Foundation
import Testing

struct GitPushDialogPresentationTests {
    @Test
    func publishingANewRemoteBranchSaysWhereItIsCreated() {
        let presentation = GitPushDialogPresentation(
            preview: pushPreview(branch: "feature/recent", kind: .publish, upstream: nil, createsRemoteBranch: true)
        )

        #expect(presentation.destination == "origin/feature/recent")
        #expect(presentation.note == "Creates a new branch on origin")
        #expect(presentation.actionTitle == "Publish Branch")
    }

    @Test
    func trackedBranchShowsItsDestinationWithoutAnExtraNote() {
        let presentation = GitPushDialogPresentation(
            preview: pushPreview(branch: "main", kind: .tracking, upstream: "origin/main")
        )

        #expect(presentation.destination == "origin/main")
        #expect(presentation.note == nil)
        #expect(presentation.actionTitle == "Push")
    }

    @Test
    func existingRemoteBranchWithoutUpstreamTellsThatPushingSetsOne() {
        let presentation = GitPushDialogPresentation(
            preview: pushPreview(branch: "main", kind: .publish, upstream: nil, createsRemoteBranch: false)
        )

        #expect(presentation.destination == "origin/main")
        #expect(presentation.note == "Sets origin/main as the upstream")
        #expect(presentation.actionTitle == "Push")
    }

    @Test
    func destinationNamesTheRemoteBranchTheUpstreamChoiceUpdates() {
        let presentation = GitPushDialogPresentation(
            preview: pushPreview(branch: "topic", remoteBranch: "release", kind: .divergent, upstream: "origin/release")
        )

        #expect(presentation.destination == "origin/release")
    }
}

@MainActor
struct GitPushDialogModelTests {
    @Test
    func loadingShowsTheDestinationAndSelectsTheFirstCommit() async {
        let preview = pushPreview(branch: "topic", commits: [commit("c1"), commit("c2")])
        let model = GitPushDialogModel(actions: actions(PushDialogScript(previews: [.success(preview)])))

        await model.load()

        #expect(model.phase == .ready(preview))
        #expect(model.selectedCommit?.hash == "c1")
        #expect(model.canPush)
    }

    @Test
    func previewFailureOffersNoPush() async {
        let model = GitPushDialogModel(actions: actions(PushDialogScript(previews: [.failure(GitPushFailure("No remote"))])))

        await model.load()

        #expect(model.phase == .failed("No remote"))
        #expect(!model.canPush)
        #expect(await !model.push())
    }

    @Test
    func differentlyNamedUpstreamIsNeverPushedWithoutAChoice() async {
        let divergent = pushPreview(branch: "topic", remoteBranch: "topic", kind: .divergent, upstream: "origin/main")
        let script = PushDialogScript(previews: [.success(divergent), .success(divergent)])
        let model = GitPushDialogModel(actions: actions(script))

        await model.load()

        #expect(model.needsTargetChoice)
        #expect(!model.canPush)
        #expect(await !model.push())
        #expect(script.pushes.isEmpty)

        await model.choose(.upstream)

        #expect(script.previewTargets == [nil, .upstream])
        #expect(!model.needsTargetChoice)
        #expect(model.canPush)
    }

    @Test
    func choiceIsDroppedWhenTheDestinationChangesUnderIt() async {
        let first = pushPreview(branch: "topic", remoteBranch: "main", kind: .divergent, upstream: "origin/main")
        let moved = pushPreview(branch: "topic", remoteBranch: "release", kind: .divergent, upstream: "origin/release")
        // The upstream moves between the confirmation and the push-time reload.
        let script = PushDialogScript(previews: [.success(first), .success(first), .success(moved), .success(moved)])
        let model = GitPushDialogModel(actions: actions(script))

        await model.load()
        await model.choose(.upstream)
        #expect(model.canPush)

        await model.load()

        // The answer named origin/main, so it cannot authorize origin/release.
        #expect(model.pushTarget == nil)
        #expect(model.needsTargetChoice)
        #expect(!model.canPush)
        #expect(model.preview?.destination == "origin/release")
    }

    @Test
    func pushSendsExactlyTheReviewedPreviewAndChoice() async {
        let divergent = pushPreview(branch: "topic", kind: .divergent, upstream: "origin/main")
        let script = PushDialogScript(previews: [.success(divergent), .success(divergent)], pushResults: [nil])
        let model = GitPushDialogModel(actions: actions(script))
        await model.load()
        await model.choose(.publish)

        let pushed = await model.push()

        #expect(pushed)
        #expect(script.pushes.map(\.preview) == [divergent])
        #expect(script.pushes.map(\.target) == [.publish])
        #expect(model.pushError == nil)
        #expect(!model.isPushing)
    }

    @Test
    func rejectedPushReloadsTheRepositoryAndShowsWhy() async {
        let before = pushPreview(branch: "topic", commits: [commit("c1")])
        let after = pushPreview(branch: "topic", commits: [commit("c2"), commit("c1")])
        let script = PushDialogScript(
            previews: [.success(before), .success(after)],
            pushResults: [GitPushFailure("Git push preview is stale; refresh and try again.")]
        )
        let model = GitPushDialogModel(actions: actions(script))
        await model.load()

        let pushed = await model.push()

        #expect(!pushed)
        #expect(model.pushError == "Git push preview is stale; refresh and try again.")
        #expect(model.preview == after)
        #expect(!model.isPushing)
    }

    @Test
    func publishingABranchWithoutNewCommitsIsStillAPush() async {
        let publish = pushPreview(branch: "topic", kind: .publish, upstream: nil, createsRemoteBranch: true, commits: [])
        let model = GitPushDialogModel(actions: actions(PushDialogScript(previews: [.success(publish)])))

        await model.load()

        #expect(model.canPush)
    }

    @Test
    func nothingToPushOffersNoPush() async {
        let upToDate = pushPreview(branch: "topic", commits: [])
        let model = GitPushDialogModel(actions: actions(PushDialogScript(previews: [.success(upToDate)])))

        await model.load()

        #expect(!model.canPush)
    }

    @Test(arguments: [false, true])
    func selectingACommitLoadsItsChangedFiles(waitForInitialFiles: Bool) async throws {
        let initialFiles = [GitCommitFile(status: "A", path: "Sources/Initial.swift")]
        let files = [GitCommitFile(status: "M", path: "Sources/App.swift")]
        let script = PushDialogScript(
            previews: [.success(pushPreview(branch: "topic", commits: [commit("c1"), commit("c2")]))],
            filesByCommit: ["c1": initialFiles, "c2": files]
        )
        let model = GitPushDialogModel(actions: actions(script))
        defer { model.selectCommit(nil) }
        await model.load()
        if waitForInitialFiles {
            try #require(await awaitChange(on: model) { model.files == .loaded(initialFiles) })
        }

        model.selectCommit(commit("c2"))

        #expect(model.selectedCommit?.hash == "c2")
        // Cancellation does not order callbacks: c1 may be requested after c2.
        // Distinct results verify the selected commit without assuming request order.
        #expect(await awaitChange(on: model) { model.files == .loaded(files) })
        #expect(script.filesRequests.contains("c2"))
    }
}

private final class PushDialogScript: @unchecked Sendable {
    private let lock = NSLock()
    private var previews: [Result<GitPushPreview, GitPushFailure>]
    private var pushResults: [GitPushFailure?]
    private var recordedTargets: [GitPushTargetChoice?] = []
    private var recordedPushes: [(preview: GitPushPreview, target: GitPushTargetChoice?)] = []
    private var recordedFiles: [String] = []
    private let filesByCommit: [String: [GitCommitFile]]

    init(
        previews: [Result<GitPushPreview, GitPushFailure>],
        pushResults: [GitPushFailure?] = [],
        filesByCommit: [String: [GitCommitFile]] = [:]
    ) {
        self.previews = previews
        self.pushResults = pushResults
        self.filesByCommit = filesByCommit
    }

    func nextPreview(_ target: GitPushTargetChoice?) -> Result<GitPushPreview, GitPushFailure> {
        lock.lock(); defer { lock.unlock() }
        recordedTargets.append(target)
        guard !previews.isEmpty else { return .failure(GitPushFailure("No scripted preview")) }
        return previews.count > 1 ? previews.removeFirst() : previews[0]
    }

    func nextPush(_ preview: GitPushPreview, _ target: GitPushTargetChoice?) -> GitPushFailure? {
        lock.lock(); defer { lock.unlock() }
        recordedPushes.append((preview, target))
        return pushResults.isEmpty ? GitPushFailure("No scripted push") : pushResults.removeFirst()
    }

    func nextFiles(_ commit: GitCommit) -> [GitCommitFile]? {
        lock.lock(); defer { lock.unlock() }
        recordedFiles.append(commit.hash)
        return filesByCommit[commit.hash]
    }

    var previewTargets: [GitPushTargetChoice?] { lock.lock(); defer { lock.unlock() }; return recordedTargets }
    var pushes: [(preview: GitPushPreview, target: GitPushTargetChoice?)] { lock.lock(); defer { lock.unlock() }; return recordedPushes }
    var filesRequests: [String] { lock.lock(); defer { lock.unlock() }; return recordedFiles }
}

private func actions(_ script: PushDialogScript) -> GitPushDialogActions {
    GitPushDialogActions(
        preview: { script.nextPreview($0) },
        changedFiles: { script.nextFiles($0) },
        push: { script.nextPush($0, $1) }
    )
}

private func commit(_ hash: String) -> GitCommit {
    GitCommit(hash: hash, shortHash: hash, parentHashes: [], authorName: "Author", authorEmail: "a@example.com",
              date: "2026-10-22", subject: "Subject \(hash)", decorations: "")
}

private func pushPreview(
    branch: String,
    remote: String = "origin",
    remoteBranch: String? = nil,
    kind: GitPushTargetKind = .tracking,
    upstream: String? = "origin/main",
    createsRemoteBranch: Bool = false,
    commits: [GitCommit] = [commit("c1")]
) -> GitPushPreview {
    GitPushPreview(
        localBranch: branch,
        localHead: "head-\(branch)",
        remote: remote,
        remoteBranch: remoteBranch ?? branch,
        targetKind: kind,
        createsRemoteBranch: createsRemoteBranch,
        remoteTrackingOid: createsRemoteBranch ? nil : "tracking-\(branch)",
        upstream: upstream,
        commits: commits
    )
}
