import Foundation
import LitheCoreContracts
import Testing
@testable import LitheAgentConversationModule

/// Controls prompt completion and each configuration acknowledgement without a live Agent.
@MainActor
struct AgentNextTurnConfigurationTests {
    @Test
    func respondingChoicesStayLocalUntilEveryNextTurnSettingIsConfirmed() async throws {
        try await withFeature { feature, connection in
            try feature.send("First turn")
            let turn = feature.selectedConversation?.activeTurn
            let count = connection.commands.count
            feature.setConfigOption("mode", value: "auto")
            feature.setConfigOption("reasoning_effort", value: "high")
            feature.setConfigOption("model", value: "model-b")
            #expect(connection.commands.count == count)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            #expect(values(feature.selectedConversation?.configOptions) == ["model-a", "read-only", "medium"])
            #expect(values(feature.selectedConversation?.displayConfigOptions) == ["model-b", "auto", "high"])
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }

            // A late full notification describes the running turn, not the user's next-turn intent.
            try receive(feature, "update", ["update": ["sessionUpdate": "config_option_update", "configOptions": options()]])
            try receive(feature, "update", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]])
            #expect(values(feature.selectedConversation?.configOptions) == ["model-a", "plan", "medium"])
            #expect(values(feature.selectedConversation?.displayConfigOptions) == ["model-b", "auto", "high"])
            #expect(connection.commands.count == count)

            try receive(feature, "turnFinished", ["stopReason": "end_turn"])
            #expect(connection.commands.last?["configId"] as? String == "model")
            #expect(throws: AgentConversationError.configurationPending) { try feature.send("Before confirmation") }
            let token = try #require(connection.commands.last?["token"] as? String)
            try receive(feature, "sessionConfigured", ["token": "stale", "configOptions": options(model: "model-b")])
            #expect(feature.selectedConversation?.pendingConfigToken == token)
            try acknowledge(feature, connection, options(model: "model-b", mode: "plan"))
            #expect(connection.commands.last?["configId"] as? String == "mode")
            try acknowledge(feature, connection, options(model: "model-b", mode: "auto"))
            #expect(connection.commands.last?["configId"] as? String == "reasoning_effort")
            #expect(throws: AgentConversationError.configurationPending) { try feature.send("Still confirming") }
            try acknowledge(feature, connection, options(model: "model-b", mode: "auto", effort: "high"))
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            #expect(feature.selectedConversation?.queuedConfigValues.isEmpty == true)
            #expect(values(feature.selectedConversation?.configOptions) == ["model-b", "auto", "high"])
            try feature.send("Next turn")
            #expect(connection.commands.suffix(4).compactMap { $0["kind"] as? String } ==
                    ["setConfigOption", "setConfigOption", "setConfigOption", "prompt"])
        }
    }

    @Test
    func repeatedChoicesCoalesceAndReturningToTheConfirmedValueCancelsTheChange() async throws {
        try await withFeature { feature, connection in
            try feature.send("First turn")
            let count = connection.commands.count
            feature.setConfigOption("mode", value: "auto")
            feature.setConfigOption("mode", value: "plan")
            feature.setConfigOption("mode", value: "auto")
            feature.setConfigOption("reasoning_effort", value: "high")
            feature.setConfigOption("reasoning_effort", value: "medium")
            feature.setConfigOption("model", value: "unknown")
            feature.setConfigOption("unknown", value: "auto")
            #expect(feature.selectedConversation?.queuedConfigValues == ["mode": "auto"])
            #expect(connection.commands.count == count)
            feature.setConfigOption("mode", value: "read-only")
            try receive(feature, "turnFinished")
            #expect(connection.commands.count == count)
            #expect(feature.selectedConversation?.queuedConfigValues.isEmpty == true)
            try feature.send("Next turn")
            #expect(connection.commands.last?["kind"] as? String == "prompt")
        }
    }

    @Test(arguments: ["turnFinished", "requestFailed"])
    func cancellationKeepsChoicesLocalUntilTheTerminalEvent(kind: String) async throws {
        try await withFeature { feature, connection in
            try feature.send("First turn")
            feature.setConfigOption("mode", value: "auto")
            feature.cancel()
            feature.setConfigOption("mode", value: "plan")
            #expect(connection.commands.last?["kind"] as? String == "cancel")
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.isCancelling == true)
            try receive(feature, kind, ["stopReason": "cancelled", "message": "Turn failed"])
            #expect(connection.commands.last?["kind"] as? String == "setConfigOption")
            #expect(connection.commands.last?["value"] as? String == "plan")
            #expect(feature.selectedConversation?.isResponding == false)
            try acknowledge(feature, connection, options(mode: "plan"))
            try feature.send("Next turn")
            #expect(connection.commands.last?["kind"] as? String == "prompt")
        }
    }

    @Test
    func backgroundCompletionAppliesOnlyThatSessionsChoices() async throws {
        try await withFeature { feature, connection in
            try feature.send("First session")
            feature.setConfigOption("mode", value: "auto")
            feature.startNewConversation()
            let token = try #require(connection.commands.last?["token"])
            try receive(feature, "sessionCreated", ["sessionId": "session-2", "token": token, "configOptions": options()])
            try feature.send("Second session")
            feature.setConfigOption("reasoning_effort", value: "high")
            feature.selectSession("session-1")
            #expect(values(feature.selectedConversation?.displayConfigOptions) == ["model-a", "auto", "medium"])
            feature.selectSession("session-2")
            try receive(feature, "turnFinished")
            #expect(connection.commands.last?["sessionId"] as? String == "session-1")
            #expect(connection.commands.last?["configId"] as? String == "mode")
            try acknowledge(feature, connection, options(mode: "auto"))
            #expect(feature.selectedSessionID == "session-2")
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            #expect(values(feature.selectedConversation?.displayConfigOptions) == ["model-a", "read-only", "high"])
            try receive(feature, "turnFinished", ["sessionId": "session-2"])
            #expect(connection.commands.last?["sessionId"] as? String == "session-2")
            #expect(connection.commands.last?["configId"] as? String == "reasoning_effort")
            try acknowledge(feature, connection, options(effort: "high"))
        }
    }

    @Test(arguments: ["requestFailed", "unconfirmed", "removedChoice", "sendFailed"])
    func failedApplicationRestoresConfirmedChoicesAndDoesNotSendAPrompt(failure: String) async throws {
        try await withFeature { feature, connection in
            try feature.send("First turn")
            feature.setConfigOption("model", value: "model-b")
            feature.setConfigOption("reasoning_effort", value: "high")
            if failure == "sendFailed" { connection.sendFailure = .notConnected }
            try receive(feature, "turnFinished")
            switch failure {
            case "requestFailed":
                try receive(feature, "requestFailed", ["token": connection.commands.last?["token"] as Any, "message": "Rejected"])
            case "unconfirmed":
                try acknowledge(feature, connection, options())
            case "removedChoice":
                try acknowledge(feature, connection, Array(options(model: "model-b").prefix(2)))
            default:
                break
            }
            #expect(feature.selectedConversation?.configurationError != nil)
            #expect(feature.selectedConversation?.queuedConfigValues.isEmpty == true)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            #expect(feature.selectedConversation?.displayConfigOptions == feature.selectedConversation?.configOptions)
            #expect(connection.commands.filter { $0["kind"] as? String == "prompt" }.count == 1)
            #expect(connection.commands.filter { $0["kind"] as? String == "setConfigOption" }.count == (failure == "sendFailed" ? 0 : 1))
        }
    }

    @Test
    func disconnectDiscardsUnconfirmedChoicesAndLateAcknowledgements() async throws {
        try await withFeature { feature, connection in
            try feature.send("First turn")
            feature.setConfigOption("mode", value: "auto")
            try receive(feature, "turnFinished")
            let token = try #require(connection.commands.last?["token"])
            await feature.stop()
            try receive(feature, "sessionConfigured", ["token": token, "configOptions": options(mode: "auto")])
            #expect(feature.selectedConversation?.queuedConfigValues.isEmpty == true)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            #expect(values(feature.selectedConversation?.displayConfigOptions) == ["model-a", "read-only", "medium"])
            #expect(connection.closeCount == 1)
        }
    }

    private func withFeature(_ run: (AgentConnectionModel, NextTurnConnection) async throws -> Void) async throws {
        let transport = NextTurnTransport()
        let feature = AgentConnectionModel(transport: transport)
        do {
            try feature.connect(configuration: .init(agentID: "example-agent", command: "example-agent", arguments: [],
                workspaceURL: URL(fileURLWithPath: "/example/project"), dataDirectory: URL(fileURLWithPath: "/example/agents"),
                providerProtocol: "responses", providerEndpoint: "https://provider.example.test/v1", apiKey: "test-key",
                providerName: "Example", model: "", allowsInsecureHTTP: false))
            try receive(feature, "ready", ["canLoadSessions": true])
            feature.prepareConversation()
            try receive(feature, "sessionCreated", ["token": transport.connection.commands.last?["token"] as Any,
                                                     "configOptions": options()])
            try await run(feature, transport.connection)
            await feature.stop()
        } catch {
            await feature.stop()
            throw error
        }
    }

    private func receive(_ feature: AgentConnectionModel, _ kind: String, _ fields: [String: Any] = [:]) throws {
        var event: [String: Any] = ["kind": kind, "sessionId": "session-1"]
        event.merge(fields) { _, new in new }
        feature.receive(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
    }

    private func acknowledge(_ feature: AgentConnectionModel, _ connection: NextTurnConnection, _ options: [[String: Any]]) throws {
        let command = try #require(connection.commands.last)
        try receive(feature, "sessionConfigured", ["token": command["token"] as Any,
                                                   "sessionId": command["sessionId"] as Any, "configOptions": options])
    }

    private func values(_ options: [AgentSessionConfigOption]?) -> [String]? { options?.map(\.currentValue) }

    private func options(model: String = "model-a", mode: String = "read-only", effort: String = "medium") -> [[String: Any]] {
        [("model", "model", model, ["model-a", "model-b"]),
         ("mode", "mode", mode, ["read-only", "auto", "plan"]),
         ("reasoning_effort", "thought_level", effort, ["medium", "high"])].map { id, category, current, choices in
            ["id": id, "name": id, "category": category, "type": "select", "currentValue": current,
             "options": choices.map { ["value": $0, "name": $0] }]
        }
    }
}

@MainActor
private final class NextTurnTransport: AgentConversationTransport {
    let connection = NextTurnConnection()
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        connection
    }
}

@MainActor
private final class NextTurnConnection: AgentConnection {
    var commands: [[String: Any]] = []
    var closeCount = 0
    var sendFailure: AgentConversationError?
    func send(commandJSON: String) throws {
        if let sendFailure { throw sendFailure }
        commands.append(try #require(JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]))
    }
    func close() async { closeCount += 1 }
}
