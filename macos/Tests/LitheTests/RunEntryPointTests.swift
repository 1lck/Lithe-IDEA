import Foundation
import Testing
@testable import Lithe

@Suite("Run entry points")
@MainActor
struct RunEntryPointTests {
    /// Run and Debug activate the execution module on demand, so they can reach
    /// a run feature that no workspace snapshot has bound to a project yet. The
    /// entry point has to load the project itself; otherwise identification hits
    /// an unbound service and the confirmed dialog appears to do nothing.
    ///
    /// An unreadable workspace makes the snapshot unavailable, which keeps
    /// `onSnapshotLoaded` from running and leaves the entry point as the only
    /// path that can bind the project.
    @Test
    func runningBeforeTheSnapshotLoadsBindsTheProject() async {
        let model = makeAppModel()
        model.openProjectDirectly(unreadableWorkspaceURL())
        #expect(model.runFeatureIfActive == nil)

        model.runSelectedConfiguration()

        let bound = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectLoaded == true
        }
        #expect(bound, "the Run entry point did not bind the workspace to the run feature")
    }

    /// Debugging reaches the same run feature through its own entry point.
    @Test
    func debuggingBeforeTheSnapshotLoadsBindsTheProject() async {
        let model = makeAppModel()
        model.openProjectDirectly(unreadableWorkspaceURL())
        #expect(model.runFeatureIfActive == nil)

        model.startDebugging()

        let bound = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectLoaded == true
        }
        #expect(bound, "the Debug entry point did not bind the workspace to the run feature")
    }

    /// The tool-window entry point already loaded the project on demand. It must
    /// keep doing so, because the other two now rely on the same contract.
    @Test
    func openingTheRunToolWindowBindsTheProject() async {
        let model = makeAppModel()
        model.openProjectDirectly(unreadableWorkspaceURL())

        model.toggleRun()

        let bound = await awaitChange(on: model) {
            model.runFeatureIfActive?.isProjectLoaded == true
        }
        #expect(bound, "opening the Run tool window did not bind the workspace")
    }

    private func makeAppModel() -> AppModel {
        let store = RunEntryPointTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings).services
        return AppModel(settings: settings, services: services)
    }

    private func unreadableWorkspaceURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-unreadable-workspace-\(UUID().uuidString)")
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
