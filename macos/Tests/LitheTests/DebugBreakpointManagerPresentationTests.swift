import Foundation
import Testing
@testable import Lithe

@Suite("Debug breakpoint manager presentation")
@MainActor
struct DebugBreakpointManagerPresentationTests {
    @Test
    func doesNotPresentWithoutAWorkspace() {
        let model = makeModel()

        model.showDebugBreakpointManager()

        #expect(!model.debugBreakpointPresentation.isManagerPresented)
        #expect(model.workspaceURL == nil)
    }

    @Test
    func switchingAndClosingProjectsDismissesTheManager() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-breakpoint-manager-\(UUID().uuidString)")
        let firstProject = root.appendingPathComponent("first", isDirectory: true)
        let secondProject = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeModel()
        model.openProjectDirectly(firstProject)
        model.debugBreakpointPresentation.isManagerPresented = true

        model.openProjectDirectly(secondProject)

        #expect(!model.debugBreakpointPresentation.isManagerPresented)
        model.debugBreakpointPresentation.isManagerPresented = true

        model.closeProject()

        #expect(!model.debugBreakpointPresentation.isManagerPresented)
        #expect(model.workspaceURL == nil)
    }

    private func makeModel() -> AppModel {
        let store = DebugBreakpointManagerTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode
        ).services
        return AppModel(settings: settings, services: services)
    }
}

private final class DebugBreakpointManagerTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
