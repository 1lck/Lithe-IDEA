import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

struct PluginSessionContractTests {
    @Test
    func nativeCoreConsumesSharedSessionFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            root.appendingPathComponent("shared/fixtures/plugins/session-v1.json")))
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let owner = UUID().uuidString
        for step in fixture.steps {
            var payload = step.request
            payload["ownerId"] = .string(owner)
            payload["pluginId"] = .string(fixture.pluginId)
            let result: Result<MacPluginLifecycleClient.Snapshot, CoreCallError> = core.executeResult(
                command: "plugin.session", payload: payload)
            if step.error == true {
                if case .success = result { Issue.record("Invalid session transition was accepted") }
            } else {
                let snapshot = try result.get()
                #expect(snapshot.lifecycle.state == step.state)
                #expect(snapshot.lifecycle.resources == step.resources)
                #expect(snapshot.installed == step.installed)
            }
        }
    }
    private struct Fixture: Decodable {
        let pluginId: String
        let steps: [Step]
    }
    private struct Step: Decodable {
        let request: [String: ToolingJSONValue]
        let state: String?
        let resources: [String]?
        let installed: Bool?
        let error: Bool?
    }
}
