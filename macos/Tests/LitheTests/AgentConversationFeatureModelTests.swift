import Foundation
import LitheCoreContracts
import Testing
@testable import LitheAgentConversationModule

/// Drives the feature model with events from the shared Rust fixture. Events
/// are delivered synchronously through `receive`, so no test waits on timers.
@MainActor
struct AgentConversationFeatureModelTests {
    @Test
    func turnStatisticsIncludePreparationFreezeAtCompletionAndKeepReportedUsage() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("First turn")
            let submitted = clock.instant
            #expect(feature.pendingNewConversationStartedAt == submitted)
            clock.advance(2)
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let active = try #require(feature.selectedConversation?.activeTurn)
            #expect(active.startedAt == submitted)
            clock.advance(3)
            #expect(active.elapsed(at: clock.instant) == 5)
            try feature.receive(event("usageUpdate"))
            try feature.receive(event("agentMessageChunk"))
            try feature.receive(event("turnFinishedWithUsage"))
            let first = try #require(feature.selectedConversation?.completedTurns.first)
            #expect(feature.selectedConversation?.activeTurn == nil)
            #expect(first.duration == 5)
            #expect(first.usage?.inputTokens == 18000)
            #expect(first.usage?.outputTokens == 2000)
            #expect(first.usage?.cachedReadTokens == 3000)
            #expect(first.endingMessageID == feature.selectedConversation?.messages.last?.id)
            clock.advance(20)
            #expect(first.elapsed(at: clock.instant) == 5)
            try feature.send("Second turn")
            #expect(feature.selectedConversation?.activeTurn?.usage == nil)
            clock.advance(1)
            try feature.receive(event("turnFinished"))
            let turns = try #require(feature.selectedConversation?.completedTurns)
            #expect(turns.count == 2)
            #expect(turns[0] == first)
            #expect(turns[1].duration == 1)
            #expect(turns[1].usage == nil)
            // A duplicate completion cannot create a new footer or replace earlier usage.
            try feature.receive(event("turnFinishedWithUsage"))
            #expect(feature.selectedConversation?.completedTurns == turns)
        }
    }

    @Test
    func backgroundTurnsHaveIndependentTimersAndUsage() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("First session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            clock.advance(2)
            feature.startNewConversation()
            try feature.send("Second session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                       "sessionId": "session-2"]))
            clock.advance(3)
            try feature.receive(event("turnFinishedWithUsage"))
            #expect(feature.selectedSessionID == "session-2")
            #expect(feature.conversations["session-1"]?.completedTurns.first?.duration == 5)
            #expect(feature.selectedConversation?.activeTurn?.elapsed(at: clock.instant) == 3)
            try feature.receive(event("turnFinished", ["sessionId": "session-2"]))
            #expect(feature.selectedConversation?.completedTurns.first?.duration == 3)
            #expect(feature.selectedConversation?.completedTurns.first?.usage == nil)
            feature.selectSession("session-1")
            #expect(feature.selectedConversation?.completedTurns.first?.usage?.inputTokens == 18000)
        }
    }

    @Test
    func cancellationWaitsForAcknowledgementAndFailuresStopTheirTimers() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Cancel this")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            clock.advance(2)
            feature.cancel()
            #expect(feature.selectedConversation?.activeTurn != nil)
            clock.advance(3)
            try feature.receive(event("turnCancelled"))
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 5)
            try feature.send("Fail this")
            clock.advance(4)
            try feature.receive(event("requestFailed"))
            #expect(feature.selectedConversation?.activeTurn == nil)
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 4)
            #expect(feature.selectedConversation?.completedTurns.last?.usage == nil)
            try feature.send("Disconnect this")
            clock.advance(6)
            try feature.receive(event("stopped"))
            await feature.stop()
            clock.advance(100)
            #expect(feature.selectedConversation?.activeTurn == nil)
            #expect(feature.selectedConversation?.completedTurns.map(\.duration) == [5, 4, 6])
        }
    }

    @Test
    func hostCancellationClearsPermissionsAndKeepsTheTurnBusyUntilFailure() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            var attention: [Bool] = []
            feature.onAttentionChanged = { attention.append($0) }
            try feature.send("Wait for permission")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("permission"))
            try feature.receive(event("permission", ["requestId": "permission-2"]))
            #expect(feature.selectedConversation?.pendingPermissions.count == 2)
            clock.advance(600)

            // Deliver the Host timeout event without calling the UI's cancel action.
            try feature.receive(event("turnCancelling"))
            #expect(feature.selectedConversation?.pendingPermissions.isEmpty == true)
            #expect(feature.selectedConversation?.permission == nil)
            #expect(!feature.hasPendingPermission)
            #expect(attention == [true, false])
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.isCancelling == true)
            #expect(feature.selectedConversation?.completedTurns.isEmpty == true)
            clock.advance(3)
            #expect(feature.selectedConversation?.activeTurn?.elapsed(at: clock.instant) == 603)

            let commandCount = connection.commands.count
            try feature.receive(event("permission", ["requestId": "late-permission"]))
            feature.answerPermission(optionID: "allow_once")
            feature.cancel()
            #expect(feature.selectedConversation?.permission == nil)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Still stopping") }
            #expect(connection.commands.count == commandCount)
            #expect(attention == [true, false])

            try feature.receive(event("requestFailed", ["message": "The Agent request timed out"]))
            #expect(feature.selectedConversation?.isResponding == false)
            #expect(feature.selectedConversation?.isCancelling == false)
            #expect(feature.selectedConversation?.activeTurn == nil)
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 603)
            #expect(feature.selectedConversation?.errorMessage == "The Agent request timed out")
            #expect(feature.connectionState == .ready)
            try feature.send("Retry on the same connection")
            #expect(connection.commands.last?["kind"] as? String == "prompt")
        }
    }

    @Test
    func backgroundHostCancellationPreservesOtherSessionsPermissionsAndAttention() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            var attention: [Bool] = []
            feature.onAttentionChanged = { attention.append($0) }
            try feature.send("First session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("permission"))
            feature.startNewConversation()
            try feature.send("Second session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                       "sessionId": "session-2"]))
            try feature.receive(event("permission", ["sessionId": "session-2", "requestId": "permission-2"]))

            try feature.receive(event("turnCancelling"))
            try feature.receive(event("turnCancelling"))
            #expect(feature.conversations["session-1"]?.pendingPermissions.isEmpty == true)
            #expect(feature.conversations["session-1"]?.isCancelling == true)
            #expect(feature.selectedSessionID == "session-2")
            #expect(feature.selectedConversation?.isCancelling == false)
            #expect(feature.selectedConversation?.permission?.id == "permission-2")
            #expect(feature.hasPendingPermission)
            #expect(attention == [true])
            feature.answerPermission(optionID: "allow_once")
            #expect(connection.commands.last?["requestId"] as? String == "permission-2")
            #expect(connection.commands.last?["optionId"] as? String == "allow_once")
            #expect(!feature.hasPendingPermission)
            #expect(attention == [true, false])
        }
    }

    @Test
    func failedSendAndReplayedHistoryDoNotInventStatistics() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            feature.selectSession("session-1")
            let loadToken = try #require(connection.commands.last?["token"])
            try feature.receive(event("userMessageChunk"))
            try feature.receive(event("agentMessageChunk"))
            clock.advance(30)
            try feature.receive(event("sessionLoaded", ["token": loadToken]))
            #expect(feature.selectedConversation?.completedTurns.isEmpty == true)
            #expect(feature.selectedConversation?.activeTurn == nil)
            connection.sendFailure = AgentConversationError.notConnected
            #expect(throws: AgentConversationError.sendFailed(AgentConversationError.notConnected.localizedDescription)) {
                try feature.send("Cannot send")
            }
            #expect(feature.selectedConversation?.activeTurn == nil)
            #expect(feature.selectedConversation?.messages.count == 2)
        }
    }

    @Test
    func queuedHistoryPromptIncludesLoadTimeWithoutTimingReplayedMessages() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            feature.selectSession("session-1")
            let token = try #require(connection.commands.last?["token"])
            try feature.send("Continue after loading")
            let submitted = clock.instant
            try feature.receive(event("userMessageChunk"))
            try feature.receive(event("agentMessageChunk"))
            #expect(feature.selectedConversation?.activeTurn == nil)
            clock.advance(10)
            try feature.receive(event("sessionLoaded", ["token": token]))
            #expect(feature.selectedConversation?.activeTurn?.startedAt == submitted)
            clock.advance(2)
            await feature.stop()
            #expect(feature.selectedConversation?.completedTurns.count == 1)
            #expect(feature.selectedConversation?.completedTurns.first?.duration == 12)
        }
    }

    @Test
    func malformedAndMissingTurnUsageIsUnknownWhileReportedZeroIsPreserved() throws {
        #expect(AgentTurnUsage.parse(nil) == nil)
        #expect(AgentTurnUsage.parse(NSNull()) == nil)
        for payload: [String: Any] in [
            ["inputTokens": 1, "outputTokens": 2],
            ["totalTokens": 3, "inputTokens": -1, "outputTokens": 2],
            ["totalTokens": 3, "inputTokens": true, "outputTokens": 2],
            ["totalTokens": 3, "inputTokens": "1", "outputTokens": 2],
            ["totalTokens": 3, "inputTokens": 1.5, "outputTokens": 2]
        ] { #expect(AgentTurnUsage.parse(payload) == nil) }
        let zero = try #require(AgentTurnUsage.parse(["totalTokens": 0, "inputTokens": 0, "outputTokens": 0]))
        #expect(zero.inputTokens == 0 && zero.outputTokens == 0)
        #expect(zero.thoughtTokens == nil && zero.cachedReadTokens == nil)
    }

    private func withStatisticsFeature(
        _ operation: (AgentConnectionModel, TestAgentConnection, TestAgentTurnClock) async throws -> Void
    ) async throws {
        let clock = TestAgentTurnClock()
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport, now: { clock.instant })
        do {
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            try await operation(feature, try #require(transport.connections.last), clock)
        } catch { await feature.stop(); throw error }
        await feature.stop()
    }

    @Test
    func contextUsageTracksEachSessionAndCompactionWithoutAccumulatingTokens() async throws {
        try await withContextFeature { feature, connection in
            #expect(feature.selectedConversation?.contextUsage == nil)
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("usageUpdate"))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 18700)
            #expect(feature.selectedConversation?.contextUsage?.capacityTokens == 258400)
            feature.startNewConversation()
            #expect(feature.selectedConversation?.contextUsage == nil)
            try feature.receive(event("sessionCreated", ["sessionId": "session-2", "token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("usageUpdate", ["sessionId": "session-2",
                "update": ["sessionUpdate": "usage_update", "used": 90000, "size": 100000]]))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 90000)
            feature.selectSession("session-1")
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 18700)
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 1000, "size": 258400]]))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 1000)
            #expect(feature.conversations["session-2"]?.contextUsage?.usedTokens == 90000)
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            feature.closeConversation("session-1")
            #expect(feature.conversations["session-1"] == nil)
        }
    }

    @Test
    func missingInvalidAndDisconnectedUsageRemainUnknown() async throws {
        try await withContextFeature { feature, connection in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            for payload: [String: Any] in [
                ["used": -1, "size": 100], ["used": 1.5, "size": 100],
                ["used": true, "size": 100], ["used": "1", "size": 100],
                ["used": 1, "size": 0], ["used": 1], ["size": 100]
            ] {
                try feature.receive(event("usageUpdate"))
                var update = payload
                update["sessionUpdate"] = "usage_update"
                try feature.receive(event("usageUpdate", ["update": update]))
                #expect(feature.selectedConversation?.contextUsage == nil)
            }
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 0, "size": 100]]))
            #expect(feature.selectedConversation?.contextUsage?.fraction == 0)
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 150, "size": 100]]))
            #expect(feature.selectedConversation?.contextUsage?.fraction == 1.5)
            try feature.receive(event("stopped"))
            #expect(feature.selectedConversation?.contextUsage == nil)
            try feature.receive(event("usageUpdate"))
            #expect(feature.selectedConversation?.contextUsage == nil)
        }
    }

    @Test
    func confirmedModelChangesInvalidateCapacityButOtherOptionsKeepUsage() async throws {
        try await withContextFeature { feature, connection in
            feature.prepareConversation()
            let option = { (model: String, permission: String) -> [[String: Any]] in [
                ["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
                 "options": [["value": "model-a", "name": "A"], ["value": "model-b", "name": "B"]]],
                ["id": "mode", "name": "Permissions", "category": "mode", "type": "select", "currentValue": permission,
                 "options": [["value": "read-only", "name": "Read Only"], ["value": "auto", "name": "Auto"]]]
            ] }
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                        "configOptions": option("model-a", "read-only")]))
            try feature.receive(event("usageUpdate"))
            feature.setConfigOption("mode", value: "auto")
            try feature.receive(event("sessionConfigured", ["token": connection.commands.last?["token"] as Any,
                "configOptions": option("model-a", "auto")]))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 18700)
            feature.setConfigOption("model", value: "model-b")
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 18700)
            try feature.receive(event("sessionConfigured", ["token": connection.commands.last?["token"] as Any,
                "configOptions": option("model-b", "auto")]))
            #expect(feature.selectedConversation?.contextUsage == nil)
            try feature.receive(event("usageUpdate"))
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "config_option_update",
                "configOptions": option("model-a", "auto")]]))
            #expect(feature.selectedConversation?.contextUsage == nil)
        }
    }

    private func withContextFeature(_ operation: (AgentConnectionModel, TestAgentConnection) throws -> Void) async throws {
        let (feature, connection) = try connectedFeature()
        do { try operation(feature, connection) }
        catch { await feature.stop(); throw error }
        await feature.stop()
    }

    @Test
    func readyAgentListsWorkspaceHistory() throws {
        let (feature, connection) = try connectedFeature()
        #expect(feature.connectionState == .ready)
        #expect(feature.canLoadSessions)
        #expect(connection.commands.last?["kind"] as? String == "listSessions")

        try feature.receive(event("sessions", ["token": connection.commands.last?["token"] as Any]))
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
        #expect(messages[2].toolDetails.input?.contains("node --test") == true)
        #expect(messages[2].toolDetails.output?.contains("exitCode") == true)
        #expect(messages[2].toolDetails.locations.first?.line == 1)
        #expect(messages[2].toolDetails.content.first?.text == "1 test passed")
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.sessions.first?.title == "Project overview")
    }

    @Test
    func interleavedReasoningAndReplyBecomeSeparateMessagesInArrivalOrder() throws {
        let (feature, _) = try respondingFeature()
        // Thought and reply chunks share one flush window; a role change must
        // still end the previous segment instead of merging the texts.
        try feature.receive(event("agentThoughtChunk"))
        try feature.receive(event("agentThoughtChunk", ["update": ["sessionUpdate": "agent_thought_chunk",
                                                                   "content": ["type": "text", "text": " Then test."]]]))
        try feature.receive(event("agentMessageChunk"))
        try feature.receive(event("toolCall"))
        try feature.receive(event("agentThoughtChunk"))
        try feature.receive(event("turnFinished"))

        let messages = try #require(feature.selectedConversation?.messages)
        #expect(messages.map(\.role) == [.user, .thought, .agent, .tool, .thought])
        #expect(messages[1].text == "Read the manifest first. Then test.")
        #expect(messages[2].text == "This project **builds** an IDE.")
        #expect(messages[4].text == "Read the manifest first.")
        let document = AgentHistoryDocument(id: "session-1", title: "Sample", messages: messages)
        let markdown = AgentHistoryDocument.markdown([document])
        #expect(markdown.contains("> Read the manifest first. Then test."))
        #expect(markdown.contains("This project **builds** an IDE."))
        #expect(!markdown.contains("> This project"))
    }

    @Test
    func planUpdatesReplaceTheWholePlanAndAnEmptyPlanClearsIt() throws {
        let (feature, _) = try respondingFeature()
        try feature.receive(event("plan"))
        let plan = try #require(feature.selectedConversation?.plan)
        #expect(plan.entries.map(\.status) == [.completed, .inProgress, .pending])
        #expect(plan.entries.first?.priority == "high")
        #expect(plan.completedCount == 1)
        #expect(plan.currentEntry?.content == "Run the tests")
        #expect(!plan.isComplete)

        try feature.receive(event("plan", ["update": ["sessionUpdate": "plan", "entries": [
            ["content": "Summarize the results", "priority": "low", "status": "completed"],
            ["content": "Unknown status", "priority": "low", "status": "blocked"]
        ]]]))
        let replaced = try #require(feature.selectedConversation?.plan)
        #expect(replaced.entries.map(\.content) == ["Summarize the results"])
        #expect(replaced.isComplete)
        #expect(replaced.currentEntry == nil)

        try feature.receive(event("plan", ["update": ["sessionUpdate": "plan", "entries": [] as [Any]]]))
        #expect(feature.selectedConversation?.plan == nil)
        // A malformed update leaves the plan state unchanged rather than inventing one.
        try feature.receive(event("plan", ["update": ["sessionUpdate": "plan"]]))
        #expect(feature.selectedConversation?.plan == nil)
    }

    @Test
    func advertisedCommandsArePerSessionAndFilterOnlyWhileTypingAName() throws {
        let (feature, connection) = try respondingFeature()
        try feature.receive(event("availableCommands"))
        let commands = try #require(feature.selectedConversation?.availableCommands)
        #expect(commands.map(\.name) == ["review", "compact"])
        #expect(commands[0].hint == "optional focus")
        #expect(commands[1].hint == nil)

        #expect(AgentCommand.suggestions(for: "/", in: commands)?.map(\.name) == ["review", "compact"])
        #expect(AgentCommand.suggestions(for: "/CO", in: commands)?.map(\.name) == ["compact"])
        // Prefix matches rank before names that only contain the query.
        #expect(AgentCommand.suggestions(for: "/e", in: commands)?.map(\.name) == ["review"])
        #expect(AgentCommand.suggestions(for: "/zz", in: commands)?.isEmpty == true)
        #expect(AgentCommand.suggestions(for: "/review ", in: commands) == nil)
        #expect(AgentCommand.suggestions(for: "review", in: commands) == nil)
        #expect(AgentCommand.suggestions(for: "/", in: []) == nil)
        #expect(commands.map(\.invocation) == ["/review", "/compact"])
        // A dollar sign is ordinary text unless the agent advertises skills.
        #expect(AgentCommand.suggestions(for: "$", in: commands) == nil)

        // codex-acp lists skills as `$name` commands and ignores `/$name`, so a
        // skill is inserted as a `$` mention and `$` filters to skills only.
        let withSkills = commands + [AgentCommand(name: "$pdf", description: "Read PDF files"),
                                     AgentCommand(name: "$spreadsheets", description: "Edit sheets")]
        #expect(withSkills[2].isSkill && !withSkills[0].isSkill)
        #expect(withSkills[2].invocation == "$pdf")
        #expect(AgentCommand.suggestions(for: "$", in: withSkills)?.map(\.name) == ["$pdf", "$spreadsheets"])
        #expect(AgentCommand.suggestions(for: "$sp", in: withSkills)?.map(\.name) == ["$spreadsheets"])
        #expect(AgentCommand.suggestions(for: "/pd", in: withSkills)?.map(\.name) == ["$pdf"])
        #expect(AgentCommand.suggestions(for: "$pdf ", in: withSkills) == nil)

        // Another session has its own list; the command text is sent as typed.
        feature.startNewConversation()
        try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                    "sessionId": "session-2"]))
        #expect(feature.selectedConversation?.availableCommands.isEmpty == true)
        try feature.send("/review src")
        #expect(connection.commands.last?["text"] as? String == "/review src")
        try feature.receive(event("availableCommands", ["sessionId": "session-2", "update": [
            "sessionUpdate": "available_commands_update", "availableCommands": [] as [Any]
        ]]))
        #expect(feature.conversations["session-1"]?.availableCommands.count == 2)
    }

    @Test
    func duplicateAdvertisedCommandsKeepTheFirstDefinitionAndUniqueRowIdentities() throws {
        let (feature, _) = try respondingFeature()
        let advertised: [[String: Any]] = [
            ["name": "review", "description": "First definition", "input": ["hint": "focus"]],
            ["name": "review", "description": "Repeated definition"],
            ["name": "compact", "description": "Compact the conversation"]
        ] + (0..<201).map { ["name": "command-\($0)"] }
        try feature.receive(event("availableCommands", ["update": [
            "sessionUpdate": "available_commands_update", "availableCommands": advertised
        ]]))
        let commands = try #require(feature.selectedConversation?.availableCommands)
        #expect(commands.count == 199, "Only the first 200 upstream entries are consumed")
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(commands.prefix(2).map(\.name) == ["review", "compact"])
        #expect(commands[0].description == "First definition")
        #expect(commands[0].hint == "focus")
        #expect(AgentCommand.suggestions(for: "/re", in: commands)?.count == 1)
    }

    @Test
    func agentReportedModeChangeMovesOnlyTheMatchingModeSelector() throws {
        let (feature, connection) = try connectedFeature()
        feature.prepareConversation()
        let configured = try #require(JSONSerialization.jsonObject(with: Data(event("sessionConfigured").utf8)) as? [String: Any])
        try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                    "configOptions": configured["configOptions"] as Any]))
        func current(_ category: String) -> String? {
            feature.selectedConversation?.configOptions.first { $0.category == category }?.currentValue
        }
        #expect(current("mode") == "read-only")
        let commandCount = connection.commands.count
        try feature.receive(event("currentModeUpdate"))
        #expect(current("mode") == "auto")
        #expect(current("model") == "example-model")
        // The agent already switched; echoing it back as a request would be wrong.
        #expect(connection.commands.count == commandCount)
        // A mode the selector does not offer is ignored rather than shown as a raw id.
        try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update",
                                                                   "currentModeId": "unlisted"]]))
        #expect(current("mode") == "auto")
    }

    @Test
    func permissionChoicesAreAnsweredOrRejectedByCancel() throws {
        let (feature, connection) = try respondingFeature()
        var attention: [Bool] = []
        feature.onAttentionChanged = { attention.append($0) }

        try feature.receive(event("permission"))
        #expect(feature.selectedConversation?.permission?.details.input?.contains("node --test") == true)
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
        #expect(feature.selectedConversation?.isCancelling == true)
        let count = connection.commands.count
        try feature.receive(event("permission"))
        #expect(feature.selectedConversation?.permission == nil)
        try feature.receive(event("toolCall"))
        feature.cancel()
        #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Must not enter the stopping turn") }
        #expect(connection.commands.count == count)
        try feature.receive(event("turnCancelled"))
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.selectedConversation?.isCancelling == false)
        #expect(feature.selectedConversation?.messages.last?.toolStatus == .interrupted)
        #expect(attention == [true, false, true, false, true, false])
    }

    @Test
    func openingAnEarlierSessionReplaysItsHistoryBeforePrompting() throws {
        let (feature, connection) = try connectedFeature()
        try feature.receive(event("sessions", ["token": connection.commands.last?["token"] as Any]))
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
        try feature.receive(event("sessions", ["token": connection.commands.last?["token"] as Any]))
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

        try feature.receive(event("availableCommands"))
        #expect(feature.selectedConversation?.availableCommands.count == 2)
        try feature.receive(event("availableCommands", ["sessionId": "session-2"]))
        #expect(feature.conversations["session-2"]?.availableCommands.count == 2)

        try feature.receive(event("stopped"))
        #expect(feature.connectionState == .failed("The Agent connection closed unexpectedly"))
        #expect(feature.selectedConversation?.isResponding == false)
        #expect(feature.selectedConversation?.isAttached == false)
        #expect(feature.selectedConversation?.messages.count == 1)
        #expect(feature.conversations.values.allSatisfy { $0.availableCommands.isEmpty })
        #expect(throws: AgentConversationError.notConnected) { try feature.send("again") }

        await feature.stop()
        #expect(transport.connections[0].closeCount == 1)
        try feature.connect(configuration: configuration)
        try feature.receive(event("ready"))
        try feature.send("again")
        #expect(transport.connections[1].commands.last?["kind"] as? String == "loadSession")
        #expect(feature.selectedConversation?.availableCommands.isEmpty == true)
        try feature.receive(event("sessionLoaded", ["token": transport.connections[1].commands.last?["token"] as Any]))
        try feature.receive(event("availableCommands", ["update": ["sessionUpdate": "available_commands_update",
            "availableCommands": [["name": "new-process-command", "description": "Current capabilities"]]]]))
        #expect(feature.selectedConversation?.availableCommands.map(\.name) == ["new-process-command"])
        await feature.stop()
        #expect(feature.selectedConversation?.availableCommands.isEmpty == true)
        #expect(transport.connections[1].closeCount == 1)
    }

    @Test
    func fileReviewBaselinesSurviveReconnectAndHistoryReplay() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.selectSession("session-1")
            try feature.receive(event("sessionLoaded", ["token": transport.connections[0].commands.last?["token"] as Any]))
            try receiveEdit(feature, id: "first", old: "A", new: "B")
            let first = try #require(reviewActivity(feature).files.first)
            feature.keepFileChanges([first], in: "session-1")

            await feature.stop()
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            let load = try #require(transport.connections[1].commands.last)
            #expect(load["kind"] as? String == "loadSession")
            try receiveEdit(feature, id: "first", old: "A", new: "B")
            try feature.receive(event("sessionLoaded", ["token": load["token"] as Any]))
            #expect(reviewActivity(feature).files.isEmpty)

            try receiveEdit(feature, id: "later", old: "B", new: "C")
            let later = reviewActivity(feature).files
            var restoredText: String?
            await feature.restoreFileChanges(later, in: "session-1") { change in
                restoredText = change.diffs.first?.oldText
            }
            #expect(restoredText == "B", "Rollback must preserve the edit kept before reconnect")
            #expect(reviewActivity(feature).files.isEmpty)

            await feature.stop()
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            let replayToken = transport.connections[2].commands.last?["token"] as Any
            try receiveEdit(feature, id: "first", old: "A", new: "B")
            try receiveEdit(feature, id: "later", old: "B", new: "C")
            try feature.receive(event("sessionLoaded", ["token": replayToken]))
            #expect(reviewActivity(feature).files.isEmpty, "Successfully rolled-back versions must stay acknowledged")

            feature.closeConversation("session-1")
            feature.selectSession("session-1")
            let reopenedToken = transport.connections[2].commands.last?["token"] as Any
            try receiveEdit(feature, id: "first", old: "A", new: "B")
            try feature.receive(event("sessionLoaded", ["token": reopenedToken]))
            #expect(reviewActivity(feature).files.count == 1, "Closing the tab releases its local review baseline")
        }
    }

    @Test
    func replayedChangedEvidenceIsNotHiddenByTheRetainedReviewBaseline() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.selectSession("session-1")
            try feature.receive(event("sessionLoaded", ["token": transport.connections[0].commands.last?["token"] as Any]))
            try receiveEdit(feature, id: "first", old: "A", new: "B")
            feature.keepFileChanges(reviewActivity(feature).files, in: "session-1")
            await feature.stop()
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            let failedLoad = transport.connections[1].commands.last?["token"] as Any
            try receiveEdit(feature, id: "first", old: "A", new: "partial replay")
            try feature.receive(event("requestFailed", ["token": failedLoad, "message": "Replay failed"]))
            #expect(reviewActivity(feature).files.isEmpty, "A failed replay restores the acknowledged transcript")
            feature.prepareConversation()
            let load = transport.connections[1].commands.last?["token"] as Any
            try receiveEdit(feature, id: "first", old: "A", new: "different")
            try feature.receive(event("sessionLoaded", ["token": load]))
            #expect(reviewActivity(feature).files.first?.diffs.first?.newText == "different")
        }
    }

    @Test
    func providerReconnectRecreatesUnpromptedSessionsAndKeepsHistoryTabs() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.selectSession("session-2")
            try feature.receive(event("sessionLoaded", ["token": transport.connections[0].commands.last?["token"] as Any,
                "sessionId": "session-2"]))
            for id in ["empty-1", "empty-2"] {
                feature.startNewConversation()
                try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any,
                    "sessionId": id]))
            }
            await feature.stop()
            #expect(feature.selectedSessionID == nil)
            #expect(feature.openSessionIDs == ["session-2"])
            #expect(feature.conversations["empty-1"] == nil && feature.conversations["empty-2"] == nil)
            #expect(!feature.sessions.contains { $0.id.hasPrefix("empty-") })
            #expect(feature.conversations["session-2"] != nil, "loaded history is retained even if its replay was empty")

            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            let connection = transport.connections[1]
            let create = try #require(connection.commands.last)
            #expect(create["kind"] as? String == "newSession")
            #expect(!connection.commands.contains { $0["kind"] as? String == "loadSession" })
            let file = try AgentFileReference(url: URL(fileURLWithPath: "/example/project/notes.txt"))
            try feature.send("Continue with the new provider", files: [file])
            try feature.receive(event("sessionCreated", ["token": create["token"] as Any, "sessionId": "replacement"]))
            let prompts = connection.commands.filter { $0["kind"] as? String == "prompt" }
            #expect(prompts.count == 1)
            #expect(prompts.first?["sessionId"] as? String == "replacement")
            #expect((prompts.first?["files"] as? [[String: String]])?.first?["uri"] == file.id)
        }
    }

    @Test
    func agentExitDropsOnlyItsUnpersistedEmptySession() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))
            try feature.receive(event("stopped"))
            #expect(feature.selectedSessionID == nil)
            #expect(feature.openSessionIDs.isEmpty && feature.sessions.isEmpty)
            await feature.stop()
            #expect(transport.connections[0].closeCount == 1)
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            #expect(transport.connections[1].commands.last?["kind"] as? String == "newSession")
        }
    }

    @Test
    func emptySessionConfirmedByUpstreamHistoryStillLoadsAfterReconnect() async throws {
        try await withReconnectableFeature { feature, transport in
            let list = try #require(transport.connections[0].commands.last)
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))
            try feature.receive(event("sessions", ["token": list["token"] as Any]))
            await feature.stop()
            #expect(feature.selectedSessionID == "session-1")
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            #expect(transport.connections[1].commands.last?["kind"] as? String == "loadSession")
            #expect(transport.connections[1].commands.last?["sessionId"] as? String == "session-1")
        }
    }

    @Test
    func missingHistoryReportsItsLoadFailureWithoutCreatingAReplacement() async throws {
        try await withReconnectableFeature { feature, transport in
            try feature.receive(event("sessions", ["token": transport.connections[0].commands.last?["token"] as Any]))
            feature.selectSession("session-2")
            let connection = transport.connections[0]
            let load = try #require(connection.commands.last)
            let count = connection.commands.count
            try feature.receive(event("requestFailed", ["token": load["token"] as Any,
                "sessionId": "session-2", "message": "no rollout found for thread id session-2"]))
            #expect(feature.selectedSessionID == "session-2")
            #expect(feature.selectedConversation?.errorMessage == "no rollout found for thread id session-2")
            #expect(connection.commands.count == count, "a missing history file is not an invitation to replace a real conversation")
            await feature.stop()
            #expect(feature.openSessionIDs == ["session-2"])
            #expect(feature.sessions.contains { $0.id == "session-2" })
        }
    }

    @Test
    func failedFirstSendDoesNotMakeAnEmptySessionResumable() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))
            transport.connections[0].sendFailure = .notConnected
            #expect(throws: AgentConversationError.sendFailed(AgentConversationError.notConnected.localizedDescription)) {
                try feature.send("Not delivered")
            }
            await feature.stop()
            #expect(feature.selectedSessionID == nil)
            #expect(feature.conversations.isEmpty)
        }
    }

    @Test
    func unsolicitedTranscriptIsRetainedEvenBeforeFirstLocalPrompt() async throws {
        try await withReconnectableFeature { feature, transport in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": transport.connections[0].commands.last?["token"] as Any]))
            try feature.receive(event("agentMessageChunk"))
            await feature.stop()
            #expect(feature.selectedSessionID == "session-1")
            #expect(feature.selectedConversation?.messages.first?.text == "This project **builds** an IDE.")
        }
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
        #expect(codex.cli?.installation?.source == .npm)
        #expect(codex.cli?.installation?.canUpdate == true)
        let claude = try #require(status.agents.last)
        #expect(claude.cli?.command == "claude")
        #expect(claude.cli?.detected == nil)
        #expect(!claude.isInstalled)
        #expect(claude.issues.count == 2)
    }

    // MARK: Helpers

    @Test
    func concurrentPermissionsArePresentedInOrderAndCancelClearsTheQueue() throws {
        let (feature, connection) = try respondingFeature()
        try feature.receive(event("permission"))
        try feature.receive(event("permission", ["requestId": "permission-2"]))
        #expect(feature.selectedConversation?.permission?.id == "permission-1")
        feature.answerPermission(optionID: "allow_once")
        #expect(connection.commands.last?["requestId"] as? String == "permission-1")
        #expect(feature.selectedConversation?.permission?.id == "permission-2")
        #expect(feature.hasPendingPermission)
        feature.cancel()
        #expect(!feature.hasPendingPermission)
    }

    @Test
    func configurationIsAvailableBeforeFirstPromptAndOnlyChangesOnAcknowledgement() throws {
        let (feature, connection) = try connectedFeature()
        feature.prepareConversation()
        let token = try #require(connection.commands.last?["token"])
        let configured = try #require(JSONSerialization.jsonObject(with: Data(event("sessionConfigured").utf8)) as? [String: Any])
        try feature.receive(event("sessionCreated", ["token": token, "configOptions": configured["configOptions"] as Any]))
        #expect(feature.selectedConversation?.messages.isEmpty == true)
        #expect(feature.selectedConversation?.configOptions.map(\.category) == ["model", "mode", "thought_level"])
        feature.setConfigOption("reasoning_effort", value: "high")
        let command = try #require(connection.commands.last)
        #expect(command["kind"] as? String == "setConfigOption")
        #expect(command["value"] as? String == "high")
        #expect(feature.selectedConversation?.configOptions.last?.currentValue == "medium")
        #expect(throws: AgentConversationError.configurationPending) { try feature.send("Wait") }
        try feature.receive(event("sessionConfigured", ["token": "stale"]))
        #expect(feature.selectedConversation?.pendingConfigToken != nil)
        try feature.receive(event("requestFailed", ["token": command["token"] as Any, "message": "Unsupported value"]))
        #expect(feature.selectedConversation?.pendingConfigToken == nil)
        #expect(feature.selectedConversation?.configurationError == "Unsupported value")
        #expect(feature.selectedConversation?.configOptions.last?.currentValue == "medium")
        feature.setConfigOption("reasoning_effort", value: "high")
        var options = try #require(configured["configOptions"] as? [[String: Any]])
        options[2]["currentValue"] = "high"
        try feature.receive(event("sessionConfigured", ["token": connection.commands.last?["token"] as Any, "configOptions": options]))
        #expect(feature.selectedConversation?.configOptions.last?.currentValue == "high")
        #expect(feature.selectedConversation?.pendingConfigToken == nil)
        try feature.send("Now send")
        #expect(connection.commands.last?["kind"] as? String == "prompt")
    }

    @Test
    func failedHistoryReloadRestoresTranscriptAndDropsPartialReplay() async throws {
        let (feature, _) = try respondingFeature()
        try feature.receive(event("turnFinished"))
        let messages = feature.selectedConversation?.messages
        await feature.stop()
        try feature.connect(configuration: configuration)
        try feature.receive(event("ready"))
        feature.selectSession("session-1")
        try feature.receive(event("agentMessageChunk"))
        // list=1, create=2, reconnect list=3, load=4
        try feature.receive(event("requestFailed", ["token": "lithe-4", "message": "Load failed"]))
        #expect(feature.selectedConversation?.messages == messages)
        #expect(feature.selectedConversation?.isLoading == false)
        #expect(feature.selectedConversation?.errorMessage == "Load failed")
        await feature.stop()
        #expect(feature.selectedConversation?.messages == messages)
    }

    @Test
    func groupedConfigChoicesAndPartialToolUpdatesPreserveUpstreamData() {
        let options = AgentSessionConfigOption.parse([[
            "id": "model", "name": "Model", "type": "select", "currentValue": "a",
            "options": [["name": "Provider", "options": [["value": "a", "name": "Model A", "description": "Upstream choice detail"]]]]
        ]])
        #expect(options.first?.choices.first?.group == "Provider")
        #expect(options.first?.choices.first?.description == "Upstream choice detail")
        #expect(options.first?.currentLabel == "Model A")
        var details = AgentToolDetails()
        details.merge(["kind": "edit", "rawInput": ["path": "main.js"],
                       "content": [["type": "diff", "path": "main.js", "oldText": "before", "newText": "after"]]])
        details.merge(["status": "completed"])
        #expect(details.kind == "edit")
        #expect(details.content.first?.text == "---\nbefore\n+++\nafter")
        details.merge(["rawOutput": String(repeating: "x", count: 100_000)])
        #expect((details.output?.count ?? 0) < 33_000)
        details.merge(["rawInput": NSNull(), "content": []])
        #expect(details.input == nil && details.content.isEmpty)
        let root = URL(fileURLWithPath: "/tmp/example-project", isDirectory: true)
        #expect(AgentToolDetails.Location(path: "main.js", line: 1).fileURL(in: root)?.path == "/tmp/example-project/main.js")
        #expect(AgentToolDetails.Location(path: "../outside.js", line: nil).fileURL(in: root) == nil)
        #expect(AgentToolDetails.Location(path: "/tmp/example-project-other/main.js", line: nil).fileURL(in: root) == nil)
    }

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

    @Test
    func droppedFilesStayWithFirstMessageUntilSessionCreation() throws {
        let (feature, connection) = try connectedFeature()
        let files = try AgentFileReference.adding([
            URL(fileURLWithPath: "/example/project/中文 File.swift"),
            URL(fileURLWithPath: "/example/project/README.md")
        ], to: [])
        try feature.send("Explain these files", files: files)
        let create = try #require(connection.commands.last)
        #expect(create["kind"] as? String == "newSession")
        #expect(feature.pendingNewConversationPrompt?.contains("中文 File.swift") == true)
        try feature.receive(event("sessionCreated", ["token": create["token"] as Any]))
        let prompt = try #require(connection.commands.last)
        let references = try #require(prompt["files"] as? [[String: String]])
        #expect(references.map { $0["uri"] } == files.map { Optional($0.id) })
        #expect(references.map { $0["name"] } == ["中文 File.swift", "README.md"])
        #expect(feature.selectedConversation?.messages.last?.text.contains("README.md") == true)
    }

    @Test
    func fileOnlyMessageWaitsForHistoryLoadAndKeepsItsSession() throws {
        let (feature, connection) = try connectedFeature()
        feature.selectSession("session-2")
        let load = try #require(connection.commands.last)
        let file = try AgentFileReference(url: URL(fileURLWithPath: "/example/project/notes.txt"))
        try feature.send("  ", files: [file])
        feature.selectSession("session-1")
        try feature.receive(event("sessionLoaded", ["token": load["token"] as Any, "sessionId": "session-2"]))
        let prompt = try #require(connection.commands.last)
        #expect(prompt["sessionId"] as? String == "session-2")
        #expect(prompt["text"] as? String == "")
        #expect((prompt["files"] as? [[String: String]])?.first?["uri"] == file.id)
        #expect(feature.selectedSessionID == "session-1")
    }

    @Test
    func failedSendCanRetryTheSameFilesWithoutDuplicatingTranscript() throws {
        let (feature, connection) = try connectedFeature()
        feature.prepareConversation()
        try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
        let files = try AgentFileReference.adding([URL(fileURLWithPath: "/example/project/notes.txt")], to: [])
        connection.sendFailure = AgentConversationError.notConnected
        #expect(throws: AgentConversationError.sendFailed(AgentConversationError.notConnected.localizedDescription)) {
            try feature.send("Read this", files: files)
        }
        #expect(feature.selectedConversation?.messages.isEmpty == true)
        #expect(feature.selectedConversation?.isResponding == false)
        connection.sendFailure = nil
        try feature.send("Read this", files: files)
        #expect(feature.selectedConversation?.messages.count == 1)
        #expect((connection.commands.last?["files"] as? [[String: String]])?.count == 1)
    }

    @Test
    func subscriptionWaitsForUserLoginAndRetainsOnlySameAccountQuota() async throws {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        let configuration = AgentLaunchConfiguration(agentID: "codex-acp", command: "", arguments: [],
            workspaceURL: URL(fileURLWithPath: "/example/project"), dataDirectory: URL(fileURLWithPath: "/example/data"),
            providerProtocol: "", providerEndpoint: "", apiKey: "", providerName: "", model: "",
            allowsInsecureHTTP: false, authentication: .codexSubscription)
        do {
            try feature.connect(configuration: configuration)
            let connection = try #require(transport.connections.first)
            try feature.receive(event("authenticationRequired"))
            #expect(feature.connectionState == .authenticationRequired)
            feature.refreshQuota()
            #expect(connection.commands.isEmpty)
            feature.authenticate()
            #expect(connection.commands.last?["kind"] as? String == "authenticate")
            feature.authenticate()
            #expect(connection.commands.count == 1)
            try feature.receive(event("account"))
            try feature.receive(event("ready"))
            feature.refreshQuota()
            #expect(connection.commands.last?["kind"] as? String == "refreshQuota")
            try feature.receive(event("quota"))
            #expect(feature.subscriptionQuota?.mostUsedWindow?.usedPercent == 68)
            let previous = feature.subscriptionQuota
            try feature.receive(event("quotaFailed"))
            #expect(feature.subscriptionQuota == previous)
            #expect(feature.quotaFailure == "timeout")
            try feature.receive(event("quotaFailed", ["code": "accountChanged"]))
            #expect(feature.subscriptionQuota == nil)
            try feature.receive(event("quota"))
            await feature.stop()
            #expect(feature.subscriptionQuota == nil)
            #expect(feature.subscriptionEmail == nil)
            try feature.receive(event("quota"))
            #expect(feature.subscriptionQuota == nil)
            #expect(connection.closeCount == 1)
            try feature.connect(configuration: configuration)
            try feature.receive(event("authenticationRequired"))
            feature.authenticate()
            await feature.cancelAuthentication()
            guard case .failed = feature.connectionState else {
                Issue.record("Cancelled login must not enter the auto-connecting idle view")
                return
            }
            #expect(transport.connections.count == 2)
            #expect(transport.connections[1].closeCount == 1)
        } catch { await feature.stop(); throw error }
    }

    @Test
    func apiKeyConnectionsNeverRequestOrDisplaySubscriptionQuota() async throws {
        let (feature, connection) = try connectedFeature()
        do {
            let before = connection.commands.count
            feature.refreshQuota()
            feature.authenticate()
            try feature.receive(event("quota"))
            try feature.receive(event("account"))
            try feature.receive(event("authenticationRequired"))
            #expect(connection.commands.count == before)
            #expect(feature.subscriptionQuota == nil)
            #expect(feature.subscriptionEmail == nil)
            #expect(feature.connectionState == .ready)
        } catch { await feature.stop(); throw error }
        await feature.stop()
    }

    private func connectedFeature() throws -> (AgentConnectionModel, TestAgentConnection) {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        try feature.connect(configuration: configuration)
        #expect(feature.connectionState == .connecting)
        try feature.receive(event("ready"))
        return (feature, transport.connections[0])
    }

    private func reviewActivity(_ feature: AgentConnectionModel) -> AgentActivity {
        let conversation = feature.selectedConversation ?? AgentConversation()
        return AgentActivity(messages: conversation.messages, reviewed: conversation.reviewedFileChanges)
    }

    private func receiveEdit(_ feature: AgentConnectionModel, id: String, old: String, new: String) throws {
        let update: [String: Any] = ["sessionUpdate": "tool_call", "toolCallId": id, "kind": "edit",
            "status": "completed", "content": [["type": "diff", "path": "a.txt", "oldText": old, "newText": new]]]
        try feature.receive(event("toolCall", ["update": update]))
    }

    private func withReconnectableFeature(
        _ run: (AgentConnectionModel, TestAgentTransport) async throws -> Void
    ) async throws {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        do {
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            try await run(feature, transport)
            await feature.stop()
        } catch {
            await feature.stop()
            throw error
        }
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
private final class TestAgentTurnClock {
    var instant = ContinuousClock.Instant.now
    func advance(_ seconds: Int64) { instant = instant.advanced(by: .seconds(seconds)) }
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
    var sendFailure: AgentConversationError?

    func send(commandJSON: String) throws {
        if let sendFailure { throw sendFailure }
        let object = try JSONSerialization.jsonObject(with: Data(commandJSON.utf8))
        commands.append(try #require(object as? [String: Any]))
    }

    func close() async { closeCount += 1 }
}
