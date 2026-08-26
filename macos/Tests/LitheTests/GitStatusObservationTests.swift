import Foundation
@testable import LitheGitModule
import LitheSearchModule
import Testing
@testable import Lithe

@Suite("Git status observation", .serialized)
struct GitStatusObservationTests {
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
        try fixture.initializeRepository(at: repository)
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
        try fixture.initializeRepository(at: repository)
        try Data("staged\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try fixture.git(["add", "tracked.txt"], at: repository)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: repository, recorder: recorder)

        try fixture.git(["commit", "-q", "-m", "external commit"], at: repository)

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
        try fixture.initializeRepository(at: repository)
        let hiddenDirectory = repository.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        let hiddenFile = hiddenDirectory.appendingPathComponent("bundle.js")
        try Data("initial\n".utf8).write(to: hiddenFile)
        try fixture.git(["add", "dist/bundle.js"], at: repository)
        try fixture.git(["commit", "-q", "-m", "track hidden output"], at: repository)
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
        try fixture.initializeRepository(at: repository)
        try fixture.git(
            ["worktree", "add", "-q", "-b", "observation-worktree", worktree.path],
            at: repository
        )
        try Data("changed\n".utf8).write(to: worktree.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: worktree, recorder: recorder)

        try fixture.git(["add", "tracked.txt"], at: worktree)

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
        try fixture.git(
            ["init", "-q", "--separate-git-dir=\(gitDirectory.path)", workspace.path],
            at: fixture.url
        )
        try fixture.configureRepository(at: workspace)
        try Data("initial\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
        try fixture.git(["add", "tracked.txt"], at: workspace)
        try fixture.git(["commit", "-q", "-m", "initial"], at: workspace)
        try Data("changed\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: workspace, recorder: recorder)

        try fixture.git(["add", "tracked.txt"], at: workspace)

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
        try fixture.initializeRepository(at: source)
        try fixture.initializeRepository(at: parent)
        try fixture.git(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                source.path, "modules/child"
            ],
            at: parent
        )
        try fixture.git(["commit", "-q", "-am", "add submodule"], at: parent)
        let submodule = parent.appendingPathComponent("modules/child", isDirectory: true)
        try fixture.configureRepository(at: submodule)
        try Data("changed\n".utf8).write(to: submodule.appendingPathComponent("tracked.txt"))
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: submodule, recorder: recorder)

        try fixture.git(["add", "tracked.txt"], at: submodule)

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
        try fixture.initializeRepository(at: source)
        try fixture.initializeRepository(at: parent)
        try fixture.git(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "-q",
                source.path, "modules/child"
            ],
            at: parent
        )
        try fixture.git(["commit", "-q", "-am", "add submodule"], at: parent)
        let submodule = parent.appendingPathComponent("modules/child", isDirectory: true)
        try fixture.configureRepository(at: submodule)
        try Data("changed\n".utf8).write(to: submodule.appendingPathComponent("tracked.txt"))
        try fixture.git(["add", "tracked.txt"], at: submodule)
        let recorder = GitObservationRecorder()
        let model = makeObservationModel(recorder: recorder)
        defer { model.reset() }
        try await startObservation(model, at: parent, recorder: recorder)

        try fixture.git(["commit", "-q", "-m", "advance submodule"], at: submodule)

        let refreshed = await waitUntil { recorder.gitRefreshCount == 1 }
        #expect(refreshed, "The parent repository must refresh its submodule gitlink state")
        #expect(recorder.externalChangeBatches.isEmpty)
    }

    @Test
    @MainActor
    func editOutsideOpenedSubdirectoryRefreshesRepositoryGitStateOnly() async throws {
        let fixture = try GitObservationFixture(label: "repository-subdirectory")
        let repository = fixture.url.appendingPathComponent("repository", isDirectory: true)
        try fixture.initializeRepository(at: repository)
        let workspace = repository.appendingPathComponent("apps/opened", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("inside\n".utf8).write(to: workspace.appendingPathComponent("inside.txt"))
        try Data("outside\n".utf8).write(to: repository.appendingPathComponent("outside.txt"))
        try fixture.git(["add", "."], at: repository)
        try fixture.git(["commit", "-q", "-m", "repository layout"], at: repository)
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

        try fixture.git(["init", "-q"], at: workspace)

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
        model.reconcilePendingStagingStates(with: [unstaged])
        #expect(model.effectiveStagingState(for: unstaged))

        model.reconcilePendingStagingStates(with: [staged])
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

    func configureRepository(at repository: URL) throws {
        try git(["config", "user.email", "tests@lithe.local"], at: repository)
        try git(["config", "user.name", "Lithe Tests"], at: repository)
        try git(["config", "core.autocrlf", "false"], at: repository)
    }

    func initializeRepository(at repository: URL) throws {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-q"], at: repository)
        try configureRepository(at: repository)
        try Data("initial\n".utf8).write(to: repository.appendingPathComponent("tracked.txt"))
        try git(["add", "tracked.txt"], at: repository)
        try git(["commit", "-q", "-m", "initial"], at: repository)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw GitObservationTestError.gitFailed(
                arguments: arguments,
                output: String(decoding: standardError, as: UTF8.self)
            )
        }
        return String(decoding: standardOutput, as: UTF8.self)
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
        await Task.detached {
            guard let repositoryRoot = Self.resolvePath(
                at: workspace,
                arguments: ["rev-parse", "--show-toplevel"]
            ),
            let gitDirectory = Self.resolvePath(
                at: workspace,
                arguments: ["rev-parse", "--absolute-git-dir"]
            ),
            let gitCommonDirectory = Self.resolvePath(
                at: workspace,
                arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"]
            ) else { return nil }
            return GitWatchContext(
                repositoryRoot: repositoryRoot,
                gitDirectory: gitDirectory,
                gitCommonDirectory: gitCommonDirectory
            )
        }.value
    }

    private static func resolvePath(at workspace: URL, arguments: [String]) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workspace
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
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
        onSnapshotLoaded: { _, _ in }
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
    try await Task.sleep(for: .milliseconds(750))
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
