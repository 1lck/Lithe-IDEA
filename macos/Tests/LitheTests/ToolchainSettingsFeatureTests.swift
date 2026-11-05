import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Toolchain settings presentation")
@MainActor
struct ToolchainSettingsFeatureTests {
    private let root = URL(fileURLWithPath: "/fixture/workspace")

    @Test
    func loadingPublishesTheLoaderSnapshotForTheRequestedWorkspace() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: root)
        #expect(model.state == .ready)
        #expect(model.snapshot == snapshot())
        #expect(model.selectedDirectoryID == ".")
        #expect(model.tools.map(\.id) == ["compiler"])
        #expect(model.loginShell == nil)
        #expect(loader.workspaces == [root])
    }

    @Test
    func directorySelectionIsValidatedAndFiltersToolsByExactIdentity() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: root)
        model.selectDirectory("apps/web")
        #expect(model.selectedDirectory?.id == "apps/web")
        #expect(model.tools.map(\.identity) == ["apps/web:compiler", "apps/web:renderer"])
        model.selectDirectory("apps/website")
        #expect(model.selectedDirectoryID == "apps/web")
    }

    @Test
    func expansionOnlyAcceptsToolsOfTheSelectedDirectory() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: root)
        model.toggleExpanded("compiler")
        #expect(model.expandedToolIDs == ["compiler"])
        model.toggleExpanded("renderer")
        model.toggleExpanded("unknown")
        #expect(model.expandedToolIDs == ["compiler"])
        model.toggleExpanded("compiler")
        #expect(model.expandedToolIDs.isEmpty)
    }

    @Test
    func pluginReloadWithdrawsRowsProvidersAndExpansionState() async {
        var withdrawn = snapshot()
        withdrawn.tools = []
        withdrawn.providers = []
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), withdrawn])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: root)
        model.selectDirectory("apps/web")
        model.toggleExpanded("renderer")
        await model.load(workspace: root)
        #expect(model.state == .ready)
        #expect(model.selectedDirectoryID == "apps/web")
        #expect(model.tools.isEmpty)
        #expect(model.providers.isEmpty)
        #expect(model.expandedToolIDs.isEmpty)
    }

    @Test
    func readFailureRetainsPreviousFactsButDoesNotReportFreshSuccess() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: root)
        let previous = model.snapshot
        loader.failure = SettingsReadFailure.unavailable
        await model.load(workspace: root)
        #expect(model.state == .failed)
        #expect(model.loadError != nil)
        #expect(model.snapshot == previous)
        #expect(model.workspaceURL == root)
    }

    @Test
    func closeRevokesReturningSnapshotAndAllowsAnotherWorkspaceLoad() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { loader.beforeReturn = nil; model.close() }
        loader.beforeReturn = { _ in model.close() }
        await model.load(workspace: root)
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
        loader.beforeReturn = nil
        await model.load(workspace: root)
        #expect(model.state == .ready)
        #expect(model.snapshot != nil)
    }

    @Test
    func newerWorkspaceLoadPublishesBeforeOlderResultAndCannotBeOverwritten() async {
        let other = URL(fileURLWithPath: "/fixture/other")
        var newer = snapshot()
        newer.workspaceURL = other
        newer.directories = [.init(id: ".", title: "Other")]
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), newer])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { loader.beforeReturn = nil; model.close() }
        // Reentrant reads control the result order without a timer or a suspended gate.
        loader.beforeReturn = { index in
            if index == 0 { await model.load(workspace: other) }
        }
        await model.load(workspace: root)
        #expect(model.state == .ready)
        #expect(model.snapshot?.workspaceURL == other)
        #expect(model.selectedDirectory?.title == "Other")
        #expect(loader.workspaces == [root, other])
    }

    @Test
    func cancelledLoadTerminatesWithoutPublishingItsSnapshot() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        let read = Task { await model.load(workspace: root) }
        defer { read.cancel(); model.close() }
        read.cancel()
        await read.value
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
        #expect(model.loadError == nil)
    }

    @Test
    func missingLoaderAndMismatchedWorkspaceAreFailuresNotReadyEmptyPages() async {
        let missing = ToolchainSettingsFeatureModel()
        defer { missing.close() }
        await missing.load(workspace: root)
        #expect(missing.state == .failed)
        #expect(missing.snapshot == nil)
        let loader = SettingsSnapshotLoader(snapshots: [snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader)
        defer { model.close() }
        await model.load(workspace: URL(fileURLWithPath: "/fixture/other"))
        #expect(model.state == .failed)
        #expect(model.snapshot == nil)
    }

    @Test
    func loadShowsTheLoginShellStateAndJoinsAReadStillRunning() async {
        let inspector = LoginShellStub(current: .init(shell: "/bin/zsh", state: .reading),
                                       afterReread: .init(shell: "/bin/zsh", state: .read, variableCount: 12))
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader, loginShell: inspector)
        defer { model.close() }
        await model.load(workspace: root)
        #expect(model.loginShell?.state == .read)
        #expect(model.loginShell?.variableCount == 12)
        #expect(!model.isRereadingLoginShell)
        // Candidates depend on the refreshed variables, so the snapshot is read again once.
        #expect(inspector.rereads == 1)
        #expect(loader.workspaces == [root, root])
    }

    @Test
    func finishedLoginShellReadIsNotStartedAgainByLoading() async {
        let inspector = LoginShellStub(current: .init(shell: "/bin/zsh", state: .failed, startedFromCache: true),
                                       afterReread: .init(shell: "/bin/zsh", state: .read))
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader, loginShell: inspector)
        defer { model.close() }
        await model.load(workspace: root)
        #expect(model.loginShell?.state == .failed)
        #expect(model.loginShell?.startedFromCache == true)
        #expect(inspector.rereads == 0)
        await model.rereadLoginShell()
        #expect(model.loginShell?.state == .read)
        #expect(inspector.rereads == 1)
        #expect(loader.workspaces == [root, root])
    }

    /// A burst of edits to watched files reloads once; other files and other roots do not.
    @Test
    func watchedFileChangesReloadTheWholeSnapshotOnce() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader, reloadDelay: .zero)
        defer { model.close() }
        model.workspaceFilesChanged([.init(fileURL: root.appendingPathComponent(".fixture-version"), kind: .changed)])
        #expect(loader.workspaces.isEmpty)
        await model.load(workspace: root)
        let reloaded = AsyncGate()
        loader.beforeReturn = { index in if index == 1 { reloaded.open() } }
        model.workspaceFilesChanged([
            .init(fileURL: root.appendingPathComponent("README.md"), kind: .changed),
            .init(fileURL: URL(fileURLWithPath: "/elsewhere/.fixture-version"), kind: .changed)
        ])
        model.workspaceFilesChanged([.init(fileURL: root.appendingPathComponent("apps/web/.fixture-version"), kind: .created)])
        model.workspaceFilesChanged([.init(fileURL: root.appendingPathComponent(".fixture-version"), kind: .deleted)])
        #expect(await reloaded.wait(timeout: .seconds(5)))
        #expect(loader.workspaces == [root, root])
    }

    /// A live plugin change rereads an open page, and does nothing before the page loads.
    @Test
    func pluginChangesReloadAnOpenPageOnly() async {
        let loader = SettingsSnapshotLoader(snapshots: [snapshot(), snapshot()])
        let model = ToolchainSettingsFeatureModel(loader: loader, reloadDelay: .zero)
        defer { model.close() }
        model.pluginsChanged()
        #expect(loader.workspaces.isEmpty)
        await model.load(workspace: root)
        let reloaded = AsyncGate()
        loader.beforeReturn = { index in if index == 1 { reloaded.open() } }
        model.pluginsChanged()
        #expect(await reloaded.wait(timeout: .seconds(5)))
        #expect(loader.workspaces == [root, root])
    }

    /// Inputs outside the workspace are watched per snapshot; closing ends the observation.
    @Test
    func providerInputsOutsideTheWorkspaceAreWatchedUntilClose() async {
        var watched = snapshot()
        watched.watch = ["/fixture/manager/installs"]
        let loader = SettingsSnapshotLoader(snapshots: [watched, watched])
        let watcher = InputWatcherStub()
        let model = ToolchainSettingsFeatureModel(loader: loader, inputWatcher: watcher, reloadDelay: .zero)
        await model.load(workspace: root)
        #expect(watcher.paths == [["/fixture/manager/installs"]])
        let reloaded = AsyncGate()
        loader.beforeReturn = { index in if index == 1 { reloaded.open() } }
        watcher.fire()
        #expect(await reloaded.wait(timeout: .seconds(5)))
        model.close()
        #expect(watcher.liveObservations == 0)
    }

    private func snapshot() -> ToolchainSettingsSnapshot {
        let provider = "dev.lithe.fixture.provider:fixture"
        let file = ToolchainSettingsSnapshot.VersionFile(path: "apps/web/.fixture-version", providerIDs: [provider])
        return ToolchainSettingsSnapshot(
            workspaceURL: root,
            directories: [.init(id: ".", title: "Workspace"), .init(id: "apps", title: "apps", depth: 1),
                          .init(id: "apps/web", title: "web", depth: 2, versionFiles: [file])],
            tools: [
                .init(id: "compiler", displayName: "Fixture compiler", pluginID: "dev.lithe.fixture.compiler", pluginName: "Compiler",
                      pin: .init(version: "1", home: "/fixture/compiler")),
                .init(id: "compiler", directoryID: "apps/web", displayName: "Fixture compiler", pluginID: "dev.lithe.fixture.compiler",
                      pluginName: "Compiler", pin: .init(version: "1", home: "/fixture/compiler"), versionFiles: [file]),
                .init(id: "renderer", directoryID: "apps/web", displayName: "Fixture renderer", pluginID: "dev.lithe.fixture.renderer",
                      pluginName: "Renderer", candidate: .init(executable: "/fixture/bin/renderer"))
            ],
            providers: [.init(id: provider, title: "Fixture provider", pluginID: "dev.lithe.fixture.provider",
                              pluginName: "Provider", tools: ["compiler"], watchFiles: [".fixture-version"])])
    }
}

private enum SettingsReadFailure: Error { case unavailable }

/// Returns finite snapshots; optional reentrancy controls completion order without waiting.
@MainActor
private final class SettingsSnapshotLoader: ToolchainSettingsLoading {
    let snapshots: [ToolchainSettingsSnapshot]
    var workspaces: [URL?] = []
    var failure: SettingsReadFailure?
    var beforeReturn: (@MainActor (Int) async -> Void)?

    init(snapshots: [ToolchainSettingsSnapshot]) { self.snapshots = snapshots }

    func load(workspace: URL?) async throws -> ToolchainSettingsSnapshot {
        let index = workspaces.count
        workspaces.append(workspace)
        if let failure { throw failure }
        guard snapshots.indices.contains(index) else { throw SettingsReadFailure.unavailable }
        let snapshot = snapshots[index]
        await beforeReturn?(index)
        return snapshot
    }
}

/// A login shell whose reads finish immediately; `reread` publishes the next state.
private final class LoginShellStub: LoginShellEnvironmentInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: LoginShellEnvironmentSnapshot
    private let next: LoginShellEnvironmentSnapshot
    private var count = 0

    init(current: LoginShellEnvironmentSnapshot, afterReread: LoginShellEnvironmentSnapshot) {
        snapshot = current
        next = afterReread
    }

    var rereads: Int { lock.withLock { count } }

    func inspect() -> LoginShellEnvironmentSnapshot { lock.withLock { snapshot } }

    func reread() async -> LoginShellEnvironmentSnapshot {
        lock.withLock {
            count += 1
            snapshot = next
            return next
        }
    }
}

/// Opened once by the loader; a test waits for it with its own deadline.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Bool, Never>?

    func open() {
        isOpen = true
        waiter?.resume(returning: true)
        waiter = nil
    }

    func wait(timeout: Duration) async -> Bool {
        if isOpen { return true }
        let deadline = Task { @MainActor [weak self] in
            // test-stability: allow(swift-real-sleep) reason: this only bounds the wait; the loader opens the gate.
            try? await Task.sleep(for: timeout)
            self?.waiter?.resume(returning: false)
            self?.waiter = nil
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { waiter = $0 }
    }
}

private final class InputWatcherStub: ToolchainInputWatching, @unchecked Sendable {
    private final class Observation {
        weak var owner: InputWatcherStub?
        init(owner: InputWatcherStub) { self.owner = owner }
        deinit { owner?.lock.withLock { owner?.live -= 1 } }
    }

    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var live = 0
    private var latest: (@Sendable () -> Void)?

    var paths: [[String]] { lock.withLock { recorded } }
    var liveObservations: Int { lock.withLock { live } }

    func watch(paths: [String], onChange: @escaping @Sendable () -> Void) -> AnyObject? {
        lock.withLock {
            recorded.append(paths)
            live += 1
            latest = onChange
        }
        return Observation(owner: self)
    }

    func fire() { lock.withLock { latest }?() }
}
