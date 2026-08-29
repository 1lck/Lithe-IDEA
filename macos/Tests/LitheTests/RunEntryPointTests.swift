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
            model.runFeatureIfActive?.projectLoadState.workspace != nil
        }
        #expect(bound, "the Run entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root) == false)

        let runFeature = try #require(model.runFeatureIfActive)
        await runFeature.generateRunConfigurations()
        #expect(runFeature.generationState == .projectNotReady)
        #expect(!workspace.hasGeneratedConfiguration, "a partial inventory must not be written")

        operations.releaseSnapshot()

        let ready = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(for: workspace.root) == true
        }
        #expect(ready, "the applied snapshot never made the run project ready")
        // Which paths generation then scans is asserted against the run
        // configuration store in ExecutionModuleTests, because the Swift test
        // binary does not link the Rust Core that performs the scan.
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
            model.runFeatureIfActive?.projectLoadState.workspace != nil
        }
        #expect(bound, "the Debug entry point never bound the workspace")
        #expect(model.runFeatureIfActive?.isProjectReady(for: workspace.root) == false)

        operations.releaseSnapshot()

        let ready = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectReady(for: workspace.root) == true
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
            model.runFeatureIfActive?.isProjectReady(for: workspace.root) == true
        }
        #expect(ready, "opening a project should make the run project ready")
    }

    private func makeAppModel(workspaceOperations: any WorkspaceOperations) -> AppModel {
        let store = RunEntryPointTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            workspaceOperations: workspaceOperations
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
        guard gate.waitSynchronously() else { return nil }
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

private final class RunEntryPointTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
