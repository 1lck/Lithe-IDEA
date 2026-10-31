import Foundation
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
                      pluginName: "Renderer", candidate: .init(executable: "/fixture/bin/renderer", origin: .path))
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
