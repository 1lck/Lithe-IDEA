import Foundation
import LitheCoreContracts
import LitheExecutionModule
import Testing
@testable import Lithe

@MainActor
struct IdeCapabilitiesTests {
    @Test
    func revokedAndReplacedWorkspacesCannotReachProductActions() async {
        let actions = CapabilityActionsFixture()
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        let disabled = await feature.call("lithe_project_inspect", arguments: [:])
        #expect((disabled["error"] as? [String: String])?["code"] == "WORKSPACE_CLOSED")
        feature.enable()
        let inspected = await feature.call("lithe_project_inspect", arguments: [:])
        #expect(inspected["name"] as? String == "Fixture")
        actions.currentWorkspaceIdentity = WorkspaceIdentity(url: actions.root, generation: 2)
        let stale = await feature.call("lithe_environment_configure", arguments: ["javaHomePath": ""])
        #expect((stale["error"] as? [String: String])?["code"] == "WORKSPACE_CLOSED")
        #expect(actions.activationCount == 0)
        await feature.shutdown()
        #expect(actions.transport.closed)
    }

    @Test
    func sharedPermissionDenialNeverActivatesExecution() async {
        let actions = CapabilityActionsFixture()
        actions.transport.validation = ["ok": false, "error": ["code": "PERMISSION_DENIED"]]
        let feature = IdeCapabilitiesFeatureModel(model: actions)
        feature.enable()
        let result = await feature.call("lithe_maven_execute", arguments: ["goals": ["verify"]])
        #expect((result["error"] as? [String: String])?["code"] == "PERMISSION_DENIED")
        #expect(actions.activationCount == 0)
        await feature.shutdown()
    }

    @Test
    func runOutputIdentitySurvivesUpdatesButChangesForReplacement() {
        let first = RunSession(id: "slot", configurationID: "service", title: "Service", output: "", isRunning: true)
        var updated = first
        updated.output = "completed"
        updated.isRunning = false
        let replacement = RunSession(id: "slot", configurationID: "service", title: "Service", output: "", isRunning: true)
        #expect(updated.executionID == first.executionID)
        #expect(replacement.executionID != first.executionID)
    }
}

@MainActor
private final class CapabilityTransportFixture: IdeHostTransport {
    var validation: [String: Any] = ["ok": true]
    var closed = false
    func open(workspace: URL, permissions: [String: Bool]) throws -> [String: Any] {
        ["hostID": "fixture-host", "configuration": ["mcpServers": [String: String]()]]
    }
    func control(_ action: String, arguments: [String: Any]) throws -> [String: Any] {
        if action == "validate" { return validation }
        if action == "close" { closed = true }
        return ["requests": []]
    }
}

@MainActor
private final class CapabilityActionsFixture: IdeCapabilityActions {
    let id = UUID()
    let projectName = "Fixture"
    let root = URL(fileURLWithPath: "/fixture/project")
    let transport = CapabilityTransportFixture()
    var activationCount = 0
    var currentWorkspaceIdentity: WorkspaceIdentity?
    var runtimeFeature: RuntimeSettingsFeatureModel { preconditionFailure("Authorization tests must not inspect runtimes") }
    var ideHostTransport: (any IdeHostTransport)? { transport }
    init() { currentWorkspaceIdentity = WorkspaceIdentity(url: root, generation: 1) }
    func isCurrentWorkspace(_ identity: WorkspaceIdentity) -> Bool { identity == currentWorkspaceIdentity }
    func activateExecutionModule() async -> ExecutionFeatureAccess? { activationCount += 1; return nil }
    func ensureRunProjectReady(_ run: RunFeatureModel, for identity: WorkspaceIdentity) async -> RunProjectReadiness { .stale }
    func prepareProjectRuntimeSettings() async {}
    func persistProjectRuntimeSettings() {}
    func reloadMavenProject(rescan: Bool) async {}
    func startAPIConfiguration(_ configuration: RunConfiguration) async {}
    func registerIdeCapabilities(_ feature: IdeCapabilitiesFeatureModel) {}
    func unregisterIdeCapabilities() {}
    func showMavenOutput() {}
    func copyIdeConfiguration(_ text: String) {}
}
