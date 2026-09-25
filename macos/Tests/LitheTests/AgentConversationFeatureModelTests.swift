import Foundation
import LitheCoreContracts
import Testing
@testable import LitheAgentConversationModule

@MainActor
struct AgentConversationFeatureModelTests {
    @Test
    func rustPermissionEventDisplaysChoicesAndRoutesBothDecisions() async throws {
        let transport = TestAgentTransport()
        let feature = AgentConversationFeatureModel(transport: transport)
        try feature.send("hello", configuration: configuration)
        let permissionEvent = try fixtureEvent("permission")

        feature.receive(permissionEvent)
        #expect(feature.permission?.title == "Run command")
        #expect(feature.permission?.choices.map(\.id) == ["allow_once"])
        feature.answerPermission(optionID: "allow_once")
        #expect(transport.session.answers.count == 1)
        #expect(transport.session.answers[0].requestID == "permission-1")
        #expect(transport.session.answers[0].optionID == "allow_once")

        feature.receive(permissionEvent)
        feature.cancel()
        #expect(feature.permission?.id == nil)
        #expect(transport.session.answers.count == 2)
        #expect(transport.session.answers[1].optionID == nil)
        #expect(transport.session.cancelCount == 1)
        await feature.stop()
    }

    @Test
    func projectDeactivationDetachesSessionBeforeProcessCleanup() async throws {
        let transport = TestAgentTransport()
        let feature = AgentConversationFeatureModel(transport: transport)
        try feature.send("hello", configuration: configuration)

        feature.stopForProjectDeactivation()
        #expect(!feature.hasActiveSession)
        #expect(feature.messages.isEmpty)
        #expect(throws: AgentConversationError.sessionStopping) {
            try feature.send("new prompt", configuration: configuration)
        }
        await feature.stop()
        #expect(transport.session.stopCount == 1)
    }

    private var configuration: AgentLaunchConfiguration {
        AgentLaunchConfiguration(
            command: "test-agent",
            arguments: [],
            workspaceURL: URL(fileURLWithPath: "/tmp/lithe-acp-test")
        )
    }

    private func fixtureEvent(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/acp-events-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(fixture["events"] as? [String: Any])
        let event = try #require(events[name])
        return try #require(String(data: JSONSerialization.data(withJSONObject: event), encoding: .utf8))
    }
}

@MainActor
private final class TestAgentTransport: AgentConversationTransport {
    let session = TestAgentSession()

    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConversationSession {
        session
    }
}

@MainActor
private final class TestAgentSession: AgentConversationSession {
    struct Answer { let requestID: String; let optionID: String? }
    var answers: [Answer] = []
    var cancelCount = 0
    var stopCount = 0

    func send(_ prompt: String) throws {}
    func cancel() { cancelCount += 1 }
    func answerPermission(requestID: String, optionID: String?) {
        answers.append(Answer(requestID: requestID, optionID: optionID))
    }
    func stop() async { stopCount += 1 }
}
