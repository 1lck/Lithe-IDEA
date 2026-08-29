import Foundation
import Testing
@testable import Lithe

@Suite("Run entry points")
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
        let operations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        model.runSelectedConfiguration()

        // The entry point binds the workspace so existing configuration is
        // readable, but the pending snapshot must keep generation out.
        let bound = await awaitChange(on: model) {
            model.runFeatureIfActive?.projectLoadState == .bound(workspace: workspace.root.standardizedFileURL)
        }
        #expect(bound, "the Run entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root, snapshotID: model.workspaceSnapshotID) == false)

        let runFeature = try #require(model.runFeatureIfActive)
        await runFeature.generateRunConfigurations()
        #expect(runFeature.generationState == .projectNotReady)
        #expect(!workspace.hasGeneratedConfiguration, "a partial inventory must not be written")

        operations.releaseSnapshot()

        let ready = await awaitChange(on: model) {
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
        let operations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        model.runSelectedConfiguration()

        let deferred = await awaitChange(on: model) { model.pendingRunAction?.kind == .run }
        #expect(deferred, "Run must be deferred while the inventory is provisional")

        operations.releaseSnapshot()

        let ready = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the applied snapshot never made the run project ready")
        let resumed = await awaitChange(on: model) { model.pendingRunAction == nil }
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
        let workspaceOperations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        let runConfigurations = ReadyRunConfigurationOperations()
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )

        model.openProjectDirectly(workspace.root)
        model.runSelectedConfiguration()

        let deferred = await awaitChange(on: model) { model.pendingRunAction?.kind == .run }
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

        workspaceOperations.releaseSnapshot()

        // Production clears the deferred action before it re-issues Run, so
        // waiting for the action to clear would pass even if the relaunch were
        // dropped. The launch plan request is what proves Run actually ran.
        let relaunched = await awaitChange(on: model) {
            runConfigurations.launchPlanCallCount == 1
        }
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
        let workspaceOperations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        let runConfigurations = InspectionGatedRunConfigurationOperations()
        defer { runConfigurations.releaseAll() }
        let model = makeAppModel(
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurations
        )

        model.openProjectDirectly(workspace.root)
        model.runSelectedConfiguration()

        // The Run entry point starts its own load while the scan is gated, so it
        // captures "no snapshot applied".
        #expect(
            await runConfigurations.inspectionEntered(1),
            "the Run entry point never started its own load"
        )

        // The snapshot lands and is fully consumed while that load is suspended.
        workspaceOperations.releaseSnapshot()
        #expect(
            await runConfigurations.inspectionEntered(2),
            "the snapshot-driven load never started"
        )
        runConfigurations.release(2)
        let ready = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "the snapshot-driven load never made the run project ready")
        // Wait for the snapshot-driven load to finish completely, so its resume
        // point has already run and found nothing deferred.
        let snapshotLoadFinished = await awaitChange(on: model) {
            model.runFeatureIfActive?.isLoadingProject == false
                && runConfigurations.resolveCallCount == 1
        }
        #expect(snapshotLoadFinished, "the snapshot-driven load never finished")

        runConfigurations.release(1)

        let relaunched = await awaitChange(on: model) {
            runConfigurations.launchPlanCallCount == 1
        }
        #expect(relaunched, "Run was neither launched nor resumed after the snapshot landed")
        #expect(model.pendingRunAction == nil)
    }

    /// Debugging reaches the same run feature through its own entry point.
    @Test
    func debugBeforeTheSnapshotDefersGenerationUntilTheInventoryIsComplete() async throws {
        let workspace = try JavaWorkspaceFixture()
        defer { workspace.remove() }
        let operations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)
        model.startDebugging()

        let bound = await awaitChange(on: model) {
            model.runFeatureIfActive?.projectLoadState == .bound(workspace: workspace.root.standardizedFileURL)
        }
        #expect(bound, "the Debug entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root, snapshotID: model.workspaceSnapshotID) == false)

        operations.releaseSnapshot()

        let ready = await awaitChange(on: model) {
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
        let operations = GatedWorkspaceOperations(snapshot: workspace.snapshot)
        operations.releaseSnapshot()
        let model = makeAppModel(workspaceOperations: operations)

        model.openProjectDirectly(workspace.root)

        let ready = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(
                for: workspace.root,
                snapshotID: model.workspaceSnapshotID
            ) == true
        }
        #expect(ready, "opening a project should make the run project ready")
    }

    private func makeAppModel(
        workspaceOperations: any WorkspaceOperations,
        runConfigurationOperations: (any RunConfigurationOperations)? = nil
    ) -> AppModel {
        let store = RunEntryPointTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            workspaceOperations: workspaceOperations,
            runConfigurationOperations: runConfigurationOperations
        ).services
        return AppModel(settings: settings, services: services)
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

/// Holds the workspace snapshot until the test releases it, so a test can decide
/// exactly when the file inventory becomes complete.
private final class GatedWorkspaceOperations: WorkspaceOperations, @unchecked Sendable {
    private let gate = TestGate()
    private let lock = NSLock()
    private let preparedSnapshot: WorkspaceSnapshot

    init(snapshot: WorkspaceSnapshot) {
        preparedSnapshot = snapshot
    }

    func releaseSnapshot() {
        gate.open()
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        // Runs on the workspace feature's detached scan task, never the main
        // actor, and the bounded wait keeps a failing test from pinning it.
        // The race test holds this gate while an inspect is suspended, so the
        // deadline must outlast that coordination window.
        guard gate.waitSynchronously(timeout: 30) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return preparedSnapshot
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

    var launchPlanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchPlanCalls
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

    func resolve(at projectURL: URL, toolchainCandidates: [ProjectToolchainCandidate]) throws -> RunConfigurationResolution {
        RunConfigurationResolution(
            configurations: [EffectiveRunConfiguration(
                configuration: Self.entryPoint,
                options: RunOptions()
            )],
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
        lock.unlock()
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
    private let lock = NSLock()
    private var inspectCalls = 0
    private var launchPlanCalls = 0
    private var resolveCalls = 0

    init(capacity: Int = 8) {
        entered = (0..<capacity).map { _ in TestGate() }
        releases = (0..<capacity).map { _ in TestGate() }
    }

    var launchPlanCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchPlanCalls
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
