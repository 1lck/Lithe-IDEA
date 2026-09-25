import Foundation
import LitheCoreContracts
import Testing
@testable import LitheAgentConversationModule

/// Drives the feature model with events from the shared Rust fixture. Events
/// are delivered synchronously through `receive`, so no test waits on timers.
@MainActor
struct AgentConversationFeatureModelTests {
    @Test
    func readyAgentListsWorkspaceHistory() throws {
        let (feature, connection) = try connectedFeature()
        #expect(feature.connectionState == .ready)
        #expect(feature.canLoadSessions)
        #expect(connection.commands.last?["kind"] as? String == "listSessions")

        try feature.receive(event("sessions"))
        #expect(feature.sessions.map(\.id) == ["session-1", "session-2"])
        #expect(feature.sessions.first?.title == "Explain this project")
    }

    @Test
    func firstMessageCreatesASessionThenPromptsIt() throws {
        let (feature, connection) = try connectedFeature()
        try feature.send("Explain this project")
        let create = try #require(connection.commands.last)
        #expect(create["kind"] as? String == "newSession")
        #expect(feature.pendingNewConversationPrompt == "Explain this project")

        try feature.receive(event("sessionCreated", ["token": create["token"] as Any]))
        #expect(feature.selectedSessionID == "session-1")
        #expect(feature.pendingNewConversationPrompt == nil)
        let prompt = try #require(connection.commands.last)
        #expect(prompt["kind"] as? String == "prompt")
        #expect(prompt["sessionId"] as? String == "session-1")
        #expect(prompt["text"] as? String == "Explain this project")
        #expect(feature.selectedConversation?.isResponding == true)
        #expect(feature.sessions.first?.title == "Explain this project")
    }

    @Test
    func streamedTextAndToolUpdatesBuildOneTranscript() throws {
        let (feature, _) = try respondingFeature()
        try feature.receive(event("agentMessageChunk"))
        try feature.receive(event("toolCall"))
        try feature.receive(event("toolCallUpdate"))
        try feature.receive(event("sessionInfo"))
        try feature.receive(event("turnFinished"))

        let messages = try #require(feature.selectedConversation?.messages)
        #expect(messages.map(\.role) == [.user, .agent, .tool])
        #expect(messages[1].text == "This project **builds** an IDE.")
        // The update carries only a status, so the tool keeps its title.
        #expect(messages[2].text == "Run tests")
        #expect(messages[2].toolStatus == .completed)
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.sessions.first?.title == "Project overview")
    }

    @Test
    func permissionChoicesAreAnsweredOrRejectedByCancel() throws {
        let (feature, connection) = try respondingFeature()
        var attention: [Bool] = []
        feature.onAttentionChanged = { attention.append($0) }

        try feature.receive(event("permission"))
        #expect(feature.selectedConversation?.permission?.choices.map(\.id) == ["allow_once", "reject_once"])
        feature.answerPermission(optionID: "allow_once")
        let answer = try #require(connection.commands.last)
        #expect(answer["kind"] as? String == "permission")
        #expect(answer["requestId"] as? String == "permission-1")
        #expect(answer["optionId"] as? String == "allow_once")

        try feature.receive(event("permission"))
        feature.answerPermission(optionID: nil)
        #expect(connection.commands.last?["optionId"] is NSNull)

        try feature.receive(event("permission"))
        feature.cancel()
        #expect(feature.selectedConversation?.permission == nil)
        #expect(connection.commands.last?["kind"] as? String == "cancel")
        try feature.receive(event("turnCancelled"))
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(attention == [true, false, true, false, true, false])
    }

    @Test
    func openingAnEarlierSessionReplaysItsHistoryBeforePrompting() throws {
        let (feature, connection) = try connectedFeature()
        try feature.receive(event("sessions"))
        feature.selectSession("session-1")
        let load = try #require(connection.commands.last)
        #expect(load["kind"] as? String == "loadSession")
        #expect(feature.selectedConversation?.isLoading == true)

        try feature.send("Continue")
        #expect(connection.commands.count == 2, "prompt waits for the load")
        try feature.receive(event("userMessageChunk"))
        try feature.receive(event("agentMessageChunk"))
        try feature.receive(event("sessionLoaded", ["token": load["token"] as Any]))

        let conversation = try #require(feature.selectedConversation)
        #expect(conversation.isAttached)
        #expect(conversation.messages.map(\.text) == ["Explain this project", "This project **builds** an IDE.", "Continue"])
        #expect(connection.commands.last?["kind"] as? String == "prompt")
    }

    @Test
    func openedConversationsBecomeTabsAndClosingOneFallsBackToTheLastOpenTab() throws {
        let (feature, connection) = try connectedFeature()
        try feature.receive(event("sessions"))
        #expect(feature.openSessionIDs.isEmpty, "history is not opened until selected")

        feature.selectSession("session-2")
        try feature.receive(event("sessionLoaded", ["token": connection.commands.last?["token"] as Any, "sessionId": "session-2"]))
        feature.startNewConversation()
        try feature.send("Explain this project")
        try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
        #expect(feature.openSessionIDs == ["session-2", "session-1"])

        // A responding conversation keeps its tab so the reply is not lost.
        feature.closeConversation("session-1")
        #expect(feature.openSessionIDs == ["session-2", "session-1"])
        try feature.receive(event("turnFinished"))
        feature.closeConversation("session-1")
        #expect(feature.openSessionIDs == ["session-2"])
        #expect(feature.selectedSessionID == "session-2")
        #expect(feature.conversations["session-1"] == nil)

        feature.closeConversation("session-2")
        #expect(feature.selectedSessionID == nil, "closing the last tab starts a new conversation")
    }

    @Test
    func agentExitKeepsTranscriptAndRequiresReloadAfterReconnect() async throws {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        try feature.connect(configuration: configuration)
        try feature.receive(event("ready"))
        try feature.send("Explain this project")
        try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))

        try feature.receive(event("stopped"))
        #expect(feature.connectionState == .failed("The Agent connection closed unexpectedly"))
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.selectedConversation?.isAttached == false)
        #expect(feature.selectedConversation?.messages.count == 1)
        #expect(throws: AgentConversationError.notConnected) { try feature.send("again") }

        await feature.stop()
        #expect(transport.connections[0].closeCount == 1)
        try feature.connect(configuration: configuration)
        try feature.receive(event("ready"))
        try feature.send("again")
        #expect(transport.connections[1].commands.last?["kind"] as? String == "loadSession")
        await feature.stop()
        #expect(transport.connections[1].closeCount == 1)
    }

    @Test
    func requestFailureEndsTheTurnWithoutStoppingTheConnection() throws {
        let (feature, _) = try respondingFeature()
        try feature.receive(event("requestFailed"))
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.selectedConversation?.errorMessage == "The Agent is still responding in this conversation")
        #expect(feature.connectionState == .ready)
    }

    @Test
    func managementStatusFixtureDecodesIntoContractTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/agent-management-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let responses = try #require(fixture["responses"] as? [String: Any])
        let status = try JSONDecoder().decode(
            AgentManagementStatus.self,
            from: JSONSerialization.data(withJSONObject: try #require(responses["status"]))
        )
        #expect(status.environment.node?.version == "20.11.0")
        let codex = try #require(status.agents.first)
        #expect(codex.isInstalled && !codex.needsUpdate)
        #expect(codex.cli?.detected?.version == "0.156.1")
        #expect(codex.cli?.minimumVersion == "0.156.0")
        let claude = try #require(status.agents.last)
        #expect(claude.cli?.command == "claude")
        #expect(claude.cli?.detected == nil)
        #expect(!claude.isInstalled)
        #expect(claude.issues.count == 2)
    }

    // MARK: Helpers

    private var configuration: AgentLaunchConfiguration {
        AgentLaunchConfiguration(
            agentID: "codex-acp",
            command: "",
            arguments: [],
            workspaceURL: URL(fileURLWithPath: "/tmp/lithe-acp-test"),
            dataDirectory: URL(fileURLWithPath: "/tmp/lithe-acp-data"),
            providerProtocol: "responses",
            providerEndpoint: "https://gateway.example.com/v1",
            apiKey: "test-key",
            providerName: "Example",
            model: "",
            allowsInsecureHTTP: false
        )
    }

    @Test
    func panelKeepsOneLazyConnectionPerAgentAndAggregatesAttention() async throws {
        let transport = TestAgentTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        var attention: [Bool] = []
        panel.onAttentionChanged = { attention.append($0) }
        #expect(panel.selectedConnection == nil)

        panel.setAgents([AgentOption(id: "codex-acp", name: "Codex"), AgentOption(id: "claude-acp", name: "Claude")])
        #expect(panel.selectedAgentID == "codex-acp")
        #expect(transport.connections.isEmpty, "selecting an agent starts nothing")
        let codex = try #require(panel.selectedConnection)
        #expect(panel.connection(for: "codex-acp") === codex)

        try codex.connect(configuration: configuration)
        try codex.receive(event("ready"))
        try codex.send("Explain this project")
        try codex.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))
        try codex.receive(event("permission"))
        #expect(attention == [true])

        panel.selectAgent("claude-acp")
        let claude = try #require(panel.selectedConnection)
        #expect(claude !== codex)
        panel.selectAgent("unknown")
        #expect(panel.selectedAgentID == "claude-acp")
        codex.cancel()
        #expect(attention == [true, false])

        panel.setAgents([AgentOption(id: "codex-acp", name: "Codex")])
        #expect(panel.selectedAgentID == "codex-acp", "a removed agent falls back to the first one")
        #expect(panel.hasActiveConnection)
        await panel.stop()
        #expect(!panel.hasActiveConnection)
        #expect(transport.connections[0].closeCount == 1)
    }

    private func connectedFeature() throws -> (AgentConnectionModel, TestAgentConnection) {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        try feature.connect(configuration: configuration)
        #expect(feature.connectionState == .connecting)
        try feature.receive(event("ready"))
        return (feature, transport.connections[0])
    }

    private func respondingFeature() throws -> (AgentConnectionModel, TestAgentConnection) {
        let (feature, connection) = try connectedFeature()
        try feature.send("Explain this project")
        try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
        return (feature, connection)
    }

    private func event(_ name: String, _ overrides: [String: Any] = [:]) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/acp-events-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(fixture["events"] as? [String: Any])
        var event = try #require(events[name] as? [String: Any])
        event.merge(overrides) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }
}

@MainActor
private final class TestAgentTransport: AgentConversationTransport {
    var connections: [TestAgentConnection] = []

    func open(
        configuration: AgentLaunchConfiguration,
        onEvent: @escaping @Sendable (String) -> Void
    ) throws -> any AgentConnection {
        let connection = TestAgentConnection()
        connections.append(connection)
        return connection
    }
}

@MainActor
private final class TestAgentConnection: AgentConnection {
    var commands: [[String: Any]] = []
    var closeCount = 0

    func send(commandJSON: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(commandJSON.utf8))
        commands.append(try #require(object as? [String: Any]))
    }

    func close() async { closeCount += 1 }
}
