import Foundation
import Testing
@testable import Lithe

private let runEntryPointChangeWaitTimeout: DispatchTimeInterval = .seconds(10)
private let runEntryPointGateWaitTimeout: Duration = .seconds(10)

// Each test here opens a real workspace and builds a full service container, and
// several of them coordinate on gates. Run in parallel they contend hard enough
// to stretch their own durations by two orders of magnitude and to push other
// suites past their deadlines, so this suite takes one test at a time.
@Suite("Run entry points", .serialized)
@MainActor
struct RunEntryPointTests {
    /// Run activates the execution module on demand, so it can reach a run
    /// feature before the workspace snapshot has been applied. Binding the
    /// workspace there is not enough: generation scans the file inventory the
    /// run service holds, so identifying a provisional inventory would write a
    /// `generated.json` that omits entry points the workspace contains.
    ///
    /// The snapshot is held until after Run is pressed, then released with a
    /// real Java entry point, so the test observes both halves of the contract.
    @Test
    func runBeforeTheSnapshotDefersGenerationUntilTheInventoryIsComplete() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let operations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: operations),
            "the initial provisional workspace scan never finished"
        )
        model.runSelectedConfiguration()

        // The entry point binds the workspace so existing configuration is
        // readable, but the pending snapshot must keep generation out.
        let bound = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.projectLoadState == .bound(workspace: workspace.root.standardizedFileURL)
        }
        #expect(bound, "the Run entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root, snapshotID: model.workspaceSnapshotID) == false)

        let runFeature = try #require(model.runFeatureIfActive)
        await runFeature.generateRunConfigurations()
        #expect(runFeature.generationState == .projectNotReady)
        #expect(!workspace.hasGeneratedConfiguration, "a partial inventory must not be written")

        operations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        let ready = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the applied snapshot never made the run project ready")
        // Which paths generation then scans is asserted against the run
        // configuration store in ExecutionModuleTests, because the Swift test
        // binary does not link the Rust Core that performs the scan.
    }

    /// Launching from a provisional inventory resolves toolchains without the
    /// Maven project, so Run has to defer rather than proceed on a bound-only
    /// workspace. The deferred action is remembered and resumed by the load the
    /// snapshot drives, which is what lets the user press Run once.
    @Test
    func runDefersAndResumesWhenTheSnapshotArrivesLater() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let operations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: operations),
            "the initial provisional workspace scan never finished"
        )
        model.runSelectedConfiguration()

        let deferred = await awaitLoadDrivenChange(on: model) { model.pendingRunAction?.kind == .run }
        #expect(deferred, "Run must be deferred while the inventory is provisional")

        operations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        let ready = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the applied snapshot never made the run project ready")
        let resumed = await awaitLoadDrivenChange(on: model) { model.pendingRunAction == nil }
        #expect(resumed, "the deferred Run was never resumed")
    }

    /// A workspace that already has a configuration reports `configurationStatus
    /// == .ready` as soon as it is bound, which used to be enough to launch. With
    /// a provisional inventory the Maven project is absent, so toolchains resolve
    /// without it. Readiness has to be checked before the configuration status.
    @Test
    func runWithExistingConfigurationLaunchesOnlyAfterTheSnapshotArrives() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let workspaceOperations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let runConfigurations = ReadyRunConfigurationOperations()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: workspaceOperations),
            "the initial provisional workspace scan never finished"
        )
        model.runSelectedConfiguration()

        let deferred = await awaitLoadDrivenChange(on: model) { model.pendingRunAction?.kind == .run }
        #expect(deferred, "Run must be deferred while the file inventory is provisional")
        let runFeature = try #require(model.runFeatureIfActive)
        #expect(
            runFeature.configurationStatus == .ready,
            "the seeded configuration should already report ready"
        )
        #expect(
            runConfigurations.launchPlanCallCount == 0,
            "Run must not build a launch plan from a provisional inventory"
        )

        workspaceOperations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        // Production clears the deferred action before it re-issues Run, so
        // waiting for the action to clear would pass even if the relaunch were
        // dropped. The launch plan request is what proves Run actually ran.
        let relaunched = await runConfigurations.launchPlanRequested(1)
        #expect(relaunched, "the deferred Run was never actually re-issued")
        #expect(model.pendingRunAction == nil)
        #expect(
            runFeature.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            )
        )
    }

    /// When Run's own provisional load is still in flight, the snapshot can land
    /// and be fully consumed first — including the deferred-run resume, which
    /// finds nothing pending. The entry point must then re-check the *current*
    /// snapshot rather than the one it captured before that load, or it defers
    /// an action nothing will ever resume.
    @Test
    func runResumesWhenTheSnapshotLandsDuringTheEntryPointsOwnLoad() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let workspaceOperations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let runConfigurations = InspectionGatedRunConfigurationOperations()
        defer { runConfigurations.releaseAll() }
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: workspaceOperations),
            "the initial provisional workspace scan never finished"
        )
        model.runSelectedConfiguration()

        // The Run entry point starts its own load before any scan succeeded, so
        // it captures "no snapshot applied".
        #expect(
            await runConfigurations.inspectionEntered(1),
            "the Run entry point never started its own load"
        )

        // The snapshot lands and is fully consumed while that load is suspended.
        // The refresh cannot be awaited here: the load it drives suspends on the
        // inspection this test releases further down.
        workspaceOperations.makeSnapshotAvailable()
        let refreshTask = Task { await model.workspaceFeature.refreshCurrent() }
        #expect(
            await runConfigurations.inspectionEntered(2),
            "the snapshot-driven load never started"
        )
        runConfigurations.release(2)
        let ready = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the snapshot-driven load never made the run project ready")
        // Wait for the snapshot-driven load to finish completely, so its resume
        // point has already run and found nothing deferred.
        let snapshotLoadFinished = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isLoadingProject == false
                && runConfigurations.resolveCallCount == 1
        }
        #expect(snapshotLoadFinished, "the snapshot-driven load never finished")

        runConfigurations.release(1)

        let relaunched = await runConfigurations.launchPlanRequested(1)
        #expect(relaunched, "Run was neither launched nor resumed after the snapshot landed")
        #expect(model.pendingRunAction == nil)
        _ = await refreshTask.value
    }

    /// Debugging reaches the same run feature through its own entry point.
    @Test
    func debugBeforeTheSnapshotDefersGenerationUntilTheInventoryIsComplete() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let operations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: operations),
            "the initial provisional workspace scan never finished"
        )
        model.startDebugging()

        let bound = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.projectLoadState == .bound(workspace: workspace.root.standardizedFileURL)
        }
        #expect(bound, "the Debug entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root, snapshotID: model.workspaceSnapshotID) == false)

        operations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        let ready = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the applied snapshot never made the run project ready")
    }

    /// Opening a project normally must reach the same ready state without any
    /// entry point, so the tool-window path keeps working.
    @Test
    func openingAProjectMakesTheRunProjectReadyOnItsOwn() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        // The scan succeeds right away here, which is the ordinary case this test
        // protects: no entry point is involved.
        let operations = SequencedWorkspaceOperations(snapshots: [workspace.snapshot])
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)

        let ready = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "opening a project should make the run project ready")
    }

    /// The Run panel's play buttons call `startRunConfiguration`, not
    /// `runSelectedConfiguration`. That path must defer under a provisional
    /// inventory and remember the concrete configuration for resume.
    @Test
    func startRunConfigurationDefersAndResumesAfterTheSnapshotArrives() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let workspaceOperations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let runConfigurations = ReadyRunConfigurationOperations()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )
        let configuration = ReadyRunConfigurationOperations.entryPoint

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: workspaceOperations),
            "the initial provisional workspace scan never finished"
        )
        model.startRunConfiguration(configuration)

        let deferred = await awaitLoadDrivenChange(on: model) {
            model.pendingRunAction?.kind == .startConfiguration(configuration)
        }
        #expect(deferred, "direct start must be deferred while the inventory is provisional")
        #expect(
            runConfigurations.launchPlanCallCount == 0,
            "direct start must not build a launch plan from a provisional inventory"
        )

        workspaceOperations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        let relaunched = await runConfigurations.launchPlanRequested(1)
        #expect(relaunched, "the deferred direct start was never actually re-issued")
        #expect(model.pendingRunAction == nil)
    }

    /// The Run panel's "Run All Services" button calls `runAllServiceConfigurations`,
    /// which must defer under a provisional inventory and remember that batch
    /// intent — not collapse into a generic `.run`.
    @Test
    func runAllServicesDefersAndResumesAfterTheSnapshotArrives() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let workspaceOperations = SequencedWorkspaceOperations.controlledSnapshot(workspace.snapshot)
        let runConfigurations = ReadyRunConfigurationOperations()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )

        model.openProjectDirectly(workspace.root)
        try #require(
            await initialWorkspaceScanFinished(on: model, operations: workspaceOperations),
            "the initial provisional workspace scan never finished"
        )
        model.runAllServiceConfigurations()

        let deferred = await awaitLoadDrivenChange(on: model) {
            model.pendingRunAction?.kind == .runAllServices
        }
        #expect(deferred, "run-all-services must be deferred while the inventory is provisional")
        #expect(
            runConfigurations.launchPlanCallCount == 0,
            "run-all-services must not build a launch plan from a provisional inventory"
        )

        workspaceOperations.makeSnapshotAvailable()
        await model.workspaceFeature.refreshCurrent()

        let relaunched = await runConfigurations.launchPlanRequested(1)
        #expect(relaunched, "the deferred run-all-services was never actually re-issued")
        #expect(model.pendingRunAction == nil)
    }

    /// Restart must use the same readiness funnel as direct start. A published
    /// but not-yet-consumed refresh still leaves the run service on the old
    /// inventory; restarting then would rebuild a launch plan from that stale
    /// scan.
    @Test
    func restartDefersWhenANewerSnapshotIsPublishedButNotYetConsumed() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }

        let first = workspace.snapshot
        let secondSource = workspace.root.appendingPathComponent("src/main/java/demo/Other.java")
        try """
        package demo;
        public class Other {
          public static void main(String[] args) {}
        }
        """.write(to: secondSource, atomically: true, encoding: .utf8)
        let second = WorkspaceSnapshot(
            root: first.root,
            files: [workspace.sourceURL, secondSource],
            id: UUID()
        )

        let workspaceOperations = SequencedWorkspaceOperations(snapshots: [nil, first, second])
        let watchContext = GatedGitWatchContextProvider()
        defer { watchContext.releaseAll() }
        let runConfigurations = ReadyRunConfigurationOperations()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations,
            gitWatchContextProvider: watchContext
        )

        // Establish lastConfiguration through the same deferred-run path the
        // existing entry tests already cover, then refresh to a newer snapshot
        // without letting the run service consume it.
        model.openProjectDirectly(workspace.root)
        model.runSelectedConfiguration()
        let deferredRun = await awaitLoadDrivenChange(on: model) { model.pendingRunAction?.kind == .run }
        #expect(deferredRun, "the initial run must defer until the first snapshot arrives")

        // Each refresh is held at its watch-configuration fetch, so it runs as a
        // task the test releases; a refresh must also finish before the next one
        // starts, or the workspace feature would drop it as already refreshing.
        let firstRefresh = Task { await model.workspaceFeature.refreshCurrent() }
        #expect(await watchContext.entered(1))
        watchContext.release(1)
        let launched = await runConfigurations.launchPlanRequested(1)
        #expect(launched, "the initial run never requested a launch plan")
        #expect(model.runFeatureIfActive?.lastConfiguration != nil)
        #expect(model.pendingRunAction == nil)
        _ = await firstRefresh.value

        let refreshTask = Task { await model.workspaceFeature.refreshCurrent() }
        #expect(await watchContext.entered(2))
        let advanced = await awaitLoadDrivenChange(on: model) {
            model.workspaceSnapshotID == second.id
        }
        #expect(advanced, "the refreshed snapshot was never published")
        #expect(
            model.runFeatureIfActive?.isProjectReady(for: workspace.root, snapshotID: first.id) == true,
            "the run service should still hold the first snapshot while B's callback is held"
        )

        model.restartSelectedRun()
        let deferredRestart = await awaitLoadDrivenChange(on: model) {
            model.pendingRunAction?.kind == .restart
        }
        #expect(deferredRestart, "Restart must defer while the newer snapshot is unpublished to the run service")
        #expect(
            runConfigurations.launchPlanCallCount == 1,
            "Restart must not rebuild a launch plan from the superseded inventory"
        )

        watchContext.release(2)
        let relaunched = await runConfigurations.launchPlanRequested(2)
        #expect(relaunched, "the deferred Restart was never actually re-issued")
        #expect(model.pendingRunAction == nil)
        _ = await refreshTask.value
    }

    /// An entry task that started for workspace A must not re-record its action
    /// against B after a project switch, and must not wipe B's own pending.
    @Test
    func directStartFromTheOldWorkspaceIsNotDeferredIntoTheNewWorkspace() async throws {
        let workspaceA = try JavaWorkspaceFixture()
        let workspaceB = try JavaWorkspaceFixture()
        defer {
            workspaceA.remove()
            workspaceB.remove()
        }

        // Neither project ever gets an inventory, so both direct starts take the
        // pre-snapshot path and the only coordination point is the inspection.
        let workspaceOperations = SequencedWorkspaceOperations.neverScans()
        let runConfigurations = InspectionGatedRunConfigurationOperations()
        defer { runConfigurations.releaseAll() }
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )
        let configurationA = ReadyRunConfigurationOperations.entryPoint
        let configurationB = ReadyRunConfigurationOperations.serviceEntryPoint

        model.openProjectDirectly(workspaceA.root)
        model.startRunConfiguration(configurationA)
        #expect(await runConfigurations.inspectionEntered(1))

        model.openProjectDirectly(workspaceB.root)
        #expect(model.pendingRunAction == nil, "opening B must clear A's pending")

        // B has no inventory either, so its direct start defers for B itself.
        model.startRunConfiguration(configurationB)
        #expect(await runConfigurations.inspectionEntered(2))
        runConfigurations.release(2)
        let deferredForB = await awaitLoadDrivenChange(on: model) {
            model.pendingRunAction?.kind == .startConfiguration(configurationB)
                && model.pendingRunAction?.identity.url == workspaceB.root.standardizedFileURL
        }
        #expect(deferredForB, "B should record its own deferred direct start")

        // A's in-flight ensure finishes after the switch. It must be treated as
        // stale: no re-defer against B, and B's pending must survive.
        runConfigurations.release(1)
        let corruptedByStaleA = await awaitChange(on: model, timeout: .seconds(1)) {
            model.pendingRunAction?.kind == .startConfiguration(configurationA)
        }
        #expect(
            !corruptedByStaleA,
            "a stale entry task for A must not re-defer its configuration onto B"
        )
        #expect(
            model.pendingRunAction?.kind == .startConfiguration(configurationB)
                && model.pendingRunAction?.identity.url == workspaceB.root.standardizedFileURL,
            "B's pending action must survive the stale A task finishing"
        )
    }

    /// Reopening the same path starts a new session while the URL stays the same,
    /// so only the opening's generation separates the two. An entry task from the
    /// previous opening must be discarded — otherwise it finds the new opening's
    /// snapshot already applied, reads that as "ready", and launches its own
    /// configuration into a session the user has replaced.
    @Test
    func directStartFromAnEarlierOpeningOfTheSameWorkspaceIsDiscarded() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }

        // The first opening never gets a snapshot, so the direct start takes the
        // pre-snapshot path and suspends in its own load; the second opening
        // scans normally.
        let workspaceOperations = SequencedWorkspaceOperations.unavailableThenReady(workspace.snapshot)
        let runConfigurations = InspectionGatedRunConfigurationOperations()
        defer { runConfigurations.releaseAll() }
        // This test does not coordinate on the watch configuration, and the real
        // provider would run Git twice for the two openings.
        let watchContext = GatedGitWatchContextProvider()
        watchContext.releaseAll()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations,
            gitWatchContextProvider: watchContext
        )
        let earlierConfiguration = ReadyRunConfigurationOperations.entryPoint

        model.openProjectDirectly(workspace.root)
        model.startRunConfiguration(earlierConfiguration)
        #expect(
            await runConfigurations.inspectionEntered(1),
            "the direct start never began its own load"
        )

        // Reopen the same path and let this opening reach a fully loaded state.
        model.openProjectDirectly(workspace.root)
        #expect(model.pendingRunAction == nil, "reopening must clear the previous pending")
        #expect(
            await runConfigurations.inspectionEntered(2),
            "the reopened project never loaded its own snapshot"
        )
        runConfigurations.release(2)
        let readyForCurrentOpening = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(readyForCurrentOpening, "the reopened project never became ready")
        let currentSnapshotID = model.workspaceSnapshotID

        // The earlier opening's task finishes last. Its captured URL still
        // matches, so only the generation can reject it.
        runConfigurations.release(1)
        #expect(
            await runConfigurations.launchPlanNotRequested(within: .seconds(1)),
            "a task from the previous opening must not launch into the current one"
        )
        #expect(
            model.pendingRunAction == nil,
            "a discarded task must not record a pending action either"
        )
        #expect(
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: currentSnapshotID
            ) == true,
            "the current opening's inventory must survive the discarded task"
        )
    }

    /// When snapshot B is already published but its callback has not consumed it
    /// into the run service, generation must stop rather than scan the still-ready
    /// A inventory.
    @Test
    func generateRefusesStaleReadyInventoryWhenSnapshotAdvancesDuringLoad() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }

        let first = workspace.snapshot
        let secondSource = workspace.root.appendingPathComponent("src/main/java/demo/Other.java")
        try """
        package demo;
        public class Other {
          public static void main(String[] args) {}
        }
        """.write(to: secondSource, atomically: true, encoding: .utf8)
        let second = WorkspaceSnapshot(
            root: first.root,
            files: [workspace.sourceURL, secondSource],
            id: UUID()
        )

        let workspaceOperations = SequencedWorkspaceOperations(snapshots: [first, second])
        let watchContext = GatedGitWatchContextProvider()
        defer { watchContext.releaseAll() }
        let runConfigurations = InventoryRecordingGatedRunConfigurationOperations()
        defer { runConfigurations.releaseAll() }
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations,
            gitWatchContextProvider: watchContext
        )

        model.openProjectDirectly(workspace.root)
        #expect(await watchContext.entered(1))
        watchContext.release(1)
        #expect(await runConfigurations.inspectionEntered(1))
        runConfigurations.release(1)

        let readyForFirst = await awaitLoadDrivenChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: first.id
            ) == true
        }
        #expect(readyForFirst, "the first snapshot never made the run project ready")

        let runFeature = try #require(model.runFeatureIfActive)
        let refreshTask = Task { await model.workspaceFeature.refreshCurrent() }
        #expect(await watchContext.entered(2))
        let advanced = await awaitLoadDrivenChange(on: model) {
            model.workspaceSnapshotID == second.id
        }
        #expect(advanced, "the refreshed snapshot was never published")
        #expect(
            runFeature.isProjectReady(for: workspace.root, snapshotID: first.id),
            "the run service should still hold A while B's callback is held"
        )

        await model.generateRunConfigurations()
        #expect(runFeature.generationState == .projectNotReady)
        #expect(
            runConfigurations.generatedInventories.isEmpty,
            "generation must not scan the superseded inventory"
        )

        watchContext.release(2)
        #expect(await runConfigurations.inspectionEntered(2))
        runConfigurations.release(2)
        _ = await refreshTask.value
    }

    private func makeAppModel(
        workspaceOperations: any WorkspaceOperations,
        runConfigurationOperations: (any RunConfigurationOperations)? = nil,
        gitWatchContextProvider: (any GitWatchContextProviding)? = nil
    ) -> AppModel {
        let store = RunEntryPointTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurationOperations,
            gitWatchContextProvider: gitWatchContextProvider,
            // These tests assert load ordering, never toolchain selection. The
            // real resolver inspects installed JDKs through processes, which
            // makes every test here depend on the machine and serialize behind
            // that discovery.
            runExecutableResolver: StubRunExecutableResolver()
        ).services
        return AppModel(settings: settings, services: services)
    }
}

/// Awaits a state this suite reaches only after a full snapshot-driven load —
/// watch configuration, project load, toolchain resolution, and the deferred
/// resume that follows. That pipeline is far longer than a single publication,
/// so these waits carry the same deadline as the file's cross-load gates
/// instead of the shared default a failing test would otherwise hit first.
@MainActor
private func awaitLoadDrivenChange(
    on model: AppModel,
    until isSatisfied: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    await awaitChange(on: model, timeout: runEntryPointChangeWaitTimeout, until: isSatisfied)
}

/// Waits until opening has consumed its intentional `nil` snapshot. Without
/// this boundary, a following `refreshCurrent()` can overlap the initial rebuild
/// and correctly return without starting a second scan.
@MainActor
private func initialWorkspaceScanFinished(
    on model: AppModel,
    operations: SequencedWorkspaceOperations
) async -> Bool {
    guard await operations.snapshotRequested(1) else { return false }
    return await awaitChange(on: model, timeout: .seconds(5)) {
        !model.workspaceFeature.isLoadingWorkspace
    }
}

/// A real workspace on disk holding one Java entry point, so generation runs
/// through the shared Core instead of a stubbed result.
@MainActor
private struct JavaWorkspaceFixture {
    let root: URL
    let sourceURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-run-entry-\(UUID().uuidString)")
        sourceURL = root.appendingPathComponent("src/main/java/demo/App.java")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        package demo;
        public class App {
          public static void main(String[] args) {}
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
    }

    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(
            root: FileNode(url: root, isDirectory: true, children: []),
            files: [sourceURL]
        )
    }

    var hasGeneratedConfiguration: Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".lithe/run/generated.json").path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Answers toolchain questions without inspecting the machine.
///
/// Launching is out of scope for this suite, so resolution never has to succeed;
/// the protocol's default candidate and refresh behavior is what keeps real JDK
/// discovery out of these tests.
private final class StubRunExecutableResolver: RunExecutableResolving {
    func resolve(
        _ plan: SharedLaunchPlan,
        projectURL: URL,
        options: RunOptions
    ) throws -> ResolvedRunExecutable {
        throw RunConfigurationOperationFailure(message: "Launching is out of scope for this test")
    }
}

/// Hands out prepared scans in call order, and reports the folder as unreadable
/// once they run out.
///
/// Reporting "no snapshot" is how these tests reach the pre-snapshot entry path.
/// Suspending the scan instead would model a scan in flight, but the workspace
/// feature scans from a detached task, so a held scan occupies a thread of the
/// cooperative pool for the whole test and starves every other suite running in
/// parallel. The tests coordinate on the run service's inspection and on the
/// watch-configuration fetch instead, both of which suspend without a thread.
private final class SequencedWorkspaceOperations: WorkspaceOperations, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [WorkspaceSnapshot?]
    private let controlledSnapshot: WorkspaceSnapshot?
    private let snapshotRequests: [TestGate]
    private var isControlledSnapshotAvailable: Bool
    private var scanCount = 0

    init(
        snapshots: [WorkspaceSnapshot?],
        controlledSnapshot: WorkspaceSnapshot? = nil,
        requestCapacity: Int = 8
    ) {
        self.snapshots = snapshots
        self.controlledSnapshot = controlledSnapshot
        snapshotRequests = (0..<requestCapacity).map { _ in TestGate() }
        isControlledSnapshotAvailable = false
    }

    /// No scan ever succeeds, so every opening stays before its inventory.
    static func neverScans() -> SequencedWorkspaceOperations {
        SequencedWorkspaceOperations(snapshots: [])
    }

    /// The first scan finds nothing and later scans succeed, which is what a test
    /// uses to publish an inventory on demand through `refreshCurrent()`.
    static func unavailableThenReady(_ snapshot: WorkspaceSnapshot) -> SequencedWorkspaceOperations {
        SequencedWorkspaceOperations(snapshots: [nil, snapshot, snapshot, snapshot])
    }

    /// Keeps every scan provisional until the test explicitly publishes the snapshot.
    static func controlledSnapshot(_ snapshot: WorkspaceSnapshot) -> SequencedWorkspaceOperations {
        SequencedWorkspaceOperations(snapshots: [], controlledSnapshot: snapshot)
    }

    func makeSnapshotAvailable() {
        lock.lock()
        isControlledSnapshotAvailable = true
        lock.unlock()
    }

    func snapshotRequested(_ ordinal: Int) async -> Bool {
        guard snapshotRequests.indices.contains(ordinal - 1) else { return false }
        return await snapshotRequests[ordinal - 1].waitUntilOpen(timeout: .seconds(5))
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        lock.lock()
        let ordinal = scanCount
        scanCount += 1
        let result: WorkspaceSnapshot?
        if let controlledSnapshot {
            result = isControlledSnapshotAvailable ? controlledSnapshot : nil
        } else if ordinal < snapshots.count {
            result = snapshots[ordinal]
        } else {
            result = nil
        }
        lock.unlock()
        if snapshotRequests.indices.contains(ordinal) {
            snapshotRequests[ordinal].open()
        }
        return result
    }

    func readFile(at rootURL: URL, relativePath: String) -> String? {
        try? String(contentsOf: rootURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool {
        (try? text.write(
            to: rootURL.appendingPathComponent(relativePath),
            atomically: true,
            encoding: .utf8
        )) != nil
    }
}

/// Reports a workspace that already carries a configuration, which the Swift test
/// binary cannot obtain from the real store because it does not link the Rust
/// Core. Records launch-plan requests so a test can prove no launch was built.
private final class ReadyRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var launchPlanCalls = 0
    private let launchPlanRequests: [TestGate]

    init(capacity: Int = 8) {
        launchPlanRequests = (0..<capacity).map { _ in TestGate() }
    }

    var launchPlanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchPlanCalls
    }

    /// Waits for the `ordinal`-th launch plan (1-based) to be requested.
    ///
    /// The call count is not published through the model, so observing
    /// `objectWillChange` could miss an increment that lands after the last
    /// publication. Signalling from the request itself keeps the wait
    /// deterministic.
    ///
    /// The deadline spans a whole snapshot-driven load — watch configuration,
    /// project load, and toolchain resolution — so it matches the other
    /// cross-load gates in this file rather than a single publication.
    func launchPlanRequested(_ ordinal: Int) async -> Bool {
        await launchPlanRequests[ordinal - 1].waitUntilOpen(timeout: runEntryPointGateWaitTimeout)
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }

    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }

    /// A configuration that does not depend on the active editor file, so a
    /// resumed Run reaches the launch plan instead of stopping at "no open file".
    static let entryPoint = RunConfiguration(
        id: "java-main:demo.App",
        name: "App",
        kind: .javaMain,
        execution: .application,
        modulePath: nil,
        mainClass: "demo.App"
    )

    /// A service configuration so `runAllServiceConfigurations` has something to
    /// launch after a deferred resume.
    static let serviceEntryPoint = RunConfiguration(
        id: "spring-boot:demo.App",
        name: "App (Spring Boot)",
        kind: .mavenFramework(.springBoot),
        execution: .service,
        modulePath: nil,
        mainClass: "demo.App"
    )

    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [
                EffectiveRunConfiguration(
                    configuration: Self.entryPoint,
                    options: RunOptions()
                ),
                EffectiveRunConfiguration(
                    configuration: Self.serviceEntryPoint,
                    options: RunOptions()
                ),
            ],
            diagnostics: [],
            defaultConfigurationID: Self.entryPoint.id
        )
    }

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        lock.lock()
        launchPlanCalls += 1
        let ordinal = launchPlanCalls
        lock.unlock()
        launchPlanRequests[ordinal - 1].open()
        throw RunConfigurationOperationFailure(message: "Launching is out of scope for this test")
    }

    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Reports a workspace that already carries a configuration, and lets a test
/// release each `inspect` individually so it can decide what happens while a
/// specific project load is suspended.
private final class InspectionGatedRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private let entered: [TestGate]
    private let releases: [TestGate]
    private let launchPlanRequests: [TestGate]
    private let lock = NSLock()
    private var inspectCalls = 0
    private var launchPlanCalls = 0
    private var resolveCalls = 0

    init(capacity: Int = 8) {
        entered = (0..<capacity).map { _ in TestGate() }
        releases = (0..<capacity).map { _ in TestGate() }
        launchPlanRequests = (0..<capacity).map { _ in TestGate() }
    }

    var launchPlanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchPlanCalls
    }

    /// Signalled from the request itself, because the count is not published
    /// through the model and an `objectWillChange` wait could miss it. The
    /// deadline spans a whole snapshot-driven load, like the gates above.
    func launchPlanRequested(_ ordinal: Int) async -> Bool {
        await launchPlanRequests[ordinal - 1].waitUntilOpen(timeout: runEntryPointGateWaitTimeout)
    }

    /// Asserting that no launch happens needs a short deadline: the whole wait is
    /// paid on the passing path, so it must not carry a load-sized one.
    func launchPlanNotRequested(within duration: Duration) async -> Bool {
        await !launchPlanRequests[0].waitUntilOpen(timeout: duration)
    }

    var resolveCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resolveCalls
    }

    /// Waits for the `ordinal`-th inspection (1-based) to reach its gate.
    func inspectionEntered(_ ordinal: Int) async -> Bool {
        await entered[ordinal - 1].waitUntilOpen(timeout: .seconds(5))
    }

    func release(_ ordinal: Int) {
        releases[ordinal - 1].open()
    }

    func releaseAll() {
        releases.forEach { $0.open() }
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        lock.lock()
        inspectCalls += 1
        let ordinal = inspectCalls
        lock.unlock()
        // Runs on the run service's utility queue, never the cooperative
        // executor. The race test holds the first gate across a full
        // snapshot-driven load, so the deadline must cover that window.
        entered[ordinal - 1].open()
        _ = releases[ordinal - 1].waitSynchronously(timeout: 30)
        return ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }

    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        RunConfigurationGenerationResult(entryCount: 1)
    }

    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        lock.lock()
        resolveCalls += 1
        lock.unlock()
        return RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: ReadyRunConfigurationOperations.entryPoint,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: ReadyRunConfigurationOperations.entryPoint.id
        )
    }

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        lock.lock()
        launchPlanCalls += 1
        let ordinal = launchPlanCalls
        lock.unlock()
        launchPlanRequests[ordinal - 1].open()
        throw RunConfigurationOperationFailure(message: "Launching is out of scope for this test")
    }

    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

/// Holds `updateWatchConfiguration`'s git-context fetch so a test can publish a
/// newer snapshot without letting `onSnapshotLoaded` consume it yet.
private final class GatedGitWatchContextProvider: GitWatchContextProviding, @unchecked Sendable {
    private let entered: [TestGate]
    private let releases: [TestGate]
    private let queue = DispatchQueue(label: "lithe.tests.gated-git-watch-context")
    private var calls = 0

    init(capacity: Int = 8) {
        entered = (0..<capacity).map { _ in TestGate() }
        releases = (0..<capacity).map { _ in TestGate() }
    }

    func entered(_ ordinal: Int) async -> Bool {
        await entered[ordinal - 1].waitUntilOpen(timeout: .seconds(5))
    }

    func release(_ ordinal: Int) {
        releases[ordinal - 1].open()
    }

    func releaseAll() {
        releases.forEach { $0.open() }
    }

    func watchContext(for workspace: URL) async -> GitWatchContext? {
        let ordinal: Int = await withCheckedContinuation { continuation in
            queue.async {
                self.calls += 1
                continuation.resume(returning: self.calls)
            }
        }
        entered[ordinal - 1].open()
        _ = await releases[ordinal - 1].waitUntilOpen(timeout: runEntryPointGateWaitTimeout)
        return nil
    }
}

/// Like `InspectionGatedRunConfigurationOperations`, but also records every
/// generate inventory so a superseded-snapshot test can prove generation never
/// scanned the stale file list.
private final class InventoryRecordingGatedRunConfigurationOperations: RunConfigurationOperations, @unchecked Sendable {
    private let entered: [TestGate]
    private let releases: [TestGate]
    private let lock = NSLock()
    private var inspectCalls = 0
    private var launchPlanCalls = 0
    private var inventories: [[URL]] = []

    init(capacity: Int = 8) {
        entered = (0..<capacity).map { _ in TestGate() }
        releases = (0..<capacity).map { _ in TestGate() }
    }

    var launchPlanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchPlanCalls
    }

    var generatedInventories: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return inventories
    }

    func inspectionEntered(_ ordinal: Int) async -> Bool {
        await entered[ordinal - 1].waitUntilOpen(timeout: .seconds(5))
    }

    func release(_ ordinal: Int) {
        releases[ordinal - 1].open()
    }

    func releaseAll() {
        releases.forEach { $0.open() }
    }

    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        lock.lock()
        inspectCalls += 1
        let ordinal = inspectCalls
        lock.unlock()
        entered[ordinal - 1].open()
        _ = releases[ordinal - 1].waitSynchronously(timeout: 30)
        return ProjectRunConfigurationInspection(status: .ready, diagnostics: [])
    }

    func generate(at projectURL: URL, files: [URL], modulePaths: [String]) throws -> RunConfigurationGenerationResult {
        lock.lock()
        inventories.append(files)
        lock.unlock()
        return RunConfigurationGenerationResult(entryCount: files.count)
    }

    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: ReadyRunConfigurationOperations.entryPoint,
                options: RunOptions()
            )],
            diagnostics: [],
            defaultConfigurationID: ReadyRunConfigurationOperations.entryPoint.id
        )
    }

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan {
        lock.lock()
        launchPlanCalls += 1
        lock.unlock()
        throw RunConfigurationOperationFailure(message: "Launching is out of scope for this test")
    }

    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String { draft.name }
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws {}
}

private final class RunEntryPointTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
