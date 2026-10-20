import Foundation
import Combine
import LitheCoreContracts
import Testing
@testable import LitheAgentConversationModule

/// Drives the feature model with events from the shared Rust fixture. Events
/// are delivered synchronously through `receive`, so no test waits on timers.
@MainActor
struct AgentConversationFeatureModelTests {
    @Test
    func nativeSubagentsKeepTheirOutputAndToolIdentitySeparateFromTheRoot() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Inspect the sample")
            try feature.receive(event("toolCall"))
            #expect(feature.selectedConversation?.subagents.isEmpty == true)
            try feature.receive(event("subagentSpawned"))
            try feature.receive(event("nestedSubagentSpawned"))
            try feature.receive(event("subagentThoughtChunk"))
            try feature.receive(event("subagentMessageChunk"))
            try feature.receive(event("subagentToolCall"))
            // Child guidance is not the parent's plan or model selection.
            try feature.receive(event("plan", ["sessionId": "child-1"]))
            try feature.receive(event("sessionConfigured", ["sessionId": "child-1"]))
            try feature.receive(event("agentMessageChunk"))
            try feature.receive(event("subagentStateUpdate"))
            let root = try #require(feature.selectedConversation)
            #expect(root.subagents.map(\.depth) == [0, 1])
            #expect(root.subagents.map(\.state) == [.completed, .disconnected])
            #expect(root.isResponding)
            #expect(root.plan == nil)
            #expect(root.messages.filter { $0.role == .tool }.count == 2)
            #expect(Set(root.messages.filter { $0.role == .tool }.map(\.id)).count == 2)
            #expect(root.messages.contains { $0.subagentSessionID == "child-1" && $0.role == .thought })
            #expect(root.messages.contains { $0.subagentSessionID == "child-1" && $0.role == .agent })
            #expect(root.transcriptMessages.filter { $0.role == .agent }.map(\.text) == ["This project **builds** an IDE."])
            let messages = root.messages
            try feature.receive(event("subagentMessageChunk"))
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.messages.map(\.text) == messages.map(\.text), "Terminal child traffic cannot append output")
            #expect(feature.selectedConversation?.subagents.map(\.state) == [.completed, .disconnected])
            #expect(feature.conversations["child-1"] == nil)
        }
    }

    @Test
    func nativeSubagentsStayWithTheirRootAndCannotReattachOrStealARootSession() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Inspect the sample")
            try feature.receive(event("subagentSpawned"))
            feature.startNewConversation()
            try feature.receive(event("sessionCreated", ["sessionId": "session-2", "token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("subagentSpawned", ["sessionId": "session-2"]))
            try feature.receive(event("subagentSpawned", ["update": ["sessionUpdate": "subagent_spawned",
                "subagentSessionId": "session-2", "name": "Invalid", "task": "Cannot steal a root"]]))
            try feature.receive(event("nestedSubagentSpawned"))
            try feature.receive(event("subagentMessageChunk"))
            try feature.receive(event("subagentStateUpdate"))
            #expect(feature.selectedSessionID == "session-2")
            #expect(feature.selectedConversation?.subagents.isEmpty == true)
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            #expect(feature.conversations["session-1"]?.subagents.map(\.id) == ["child-1", "child-2"])
            #expect(feature.conversations["session-1"]?.messages.last?.subagentSessionID == "child-1")
            feature.selectSession("session-1")
            #expect(feature.selectedConversation?.subagents.first?.state == .completed)
        }
    }

    @Test
    func failedSubagentHistoryReloadRestoresTheOriginalChildRouting() async throws {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        do {
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": transport.connections.last?.commands.last?["token"] as Any]))
            try feature.send("Inspect the sample")
            try feature.receive(event("subagentSpawned"))
            try feature.receive(event("subagentMessageChunk"))
            try feature.receive(event("subagentStateUpdate"))
            try feature.receive(event("turnFinished"))
            let original = try #require(feature.selectedConversation)
            await feature.stop()
            try feature.connect(configuration: configuration)
            try feature.receive(event("ready"))
            feature.selectSession("session-1")
            let load = try #require(transport.connections.last?.commands.last)
            try feature.receive(event("subagentSpawned", ["update": ["sessionUpdate": "subagent_spawned",
                "subagentSessionId": "partial-child", "name": "Partial", "task": "Partial replay"]]))
            try feature.receive(event("requestFailed", ["token": load["token"] as Any, "message": "Replay failed"]))
            #expect(feature.selectedConversation?.subagents == original.subagents)
            #expect(feature.selectedConversation?.messages == original.messages)
            try feature.receive(event("subagentMessageChunk"))
            #expect(feature.conversations["child-1"] == nil, "Restored ownership ignores late output from the terminal child")
            #expect(feature.selectedConversation?.messages == original.messages)
        } catch { await feature.stop(); throw error }
        await feature.stop()
    }

    @Test
    func nativeChildPermissionsUseRootControlsAndHistoryReplaysChildOwnership() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Inspect the sample")
            try feature.receive(event("subagentSpawned"))
            try feature.receive(event("subagentToolCall"))
            let permission: [String: Any] = ["sessionId": "child-1",
                "toolCall": ["toolCallId": "tool-1", "title": "Read README.md"],
                "options": [["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]]]
            try feature.receive(event("permission", ["request": permission]))
            let prompt = try #require(feature.selectedConversation?.pendingPermissions.first)
            #expect(prompt.title == "Explore: Read README.md")
            #expect(prompt.details.input?.contains("README.md") == true, "Permission evidence comes from the child tool")
            feature.cancel()
            #expect(connection.commands.last?["sessionId"] as? String == "session-1")
            #expect(feature.selectedConversation?.pendingPermissions.isEmpty == true)
            try feature.receive(event("turnFinished"))
            // History announces child ownership before replaying child traffic.
            feature.closeConversation("session-1")
            feature.selectSession("session-1")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("subagentSpawned"))
            try feature.receive(event("subagentStateUpdate"))
            try feature.receive(event("sessionLoaded", ["token": token]))
            #expect(feature.selectedConversation?.subagents.first?.state == .completed)
            #expect(feature.selectedConversation?.isLoading == false)
        }
    }

    @Test(arguments: ["completed", "failed", "cancelled", "disconnected"])
    func terminalChildrenRemoveOnlyTheirPermissionSubtreeAndKeepTheRootRunning(state: String) async throws {
        try await withStatisticsFeature { feature, connection, clock in
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Inspect the sample")
            try feature.receive(event("subagentSpawned"))
            try feature.receive(event("nestedSubagentSpawned"))
            try feature.receive(event("subagentSpawned", ["update": ["sessionUpdate": "subagent_spawned",
                "subagentSessionId": "sibling", "name": "Other", "task": "Keep working"]]))
            var attention: [Bool] = []
            feature.onAttentionChanged = { attention.append($0) }
            clock.advance(2)
            for source in ["child-1", "child-2", "session-1", "sibling"] {
                try feature.receive(event("permission", ["requestId": source, "request": [
                    "sessionId": source, "toolCall": ["toolCallId": source, "title": "Read sample"],
                    "options": [["optionId": "allow_once", "name": "Allow once", "kind": "allow_once"]]
                ]]))
            }
            #expect(feature.selectedConversation?.pendingPermissions.first?.subagentSessionID == "child-1")
            clock.advance(3)
            try feature.receive(event("subagentStateUpdate", ["update": ["sessionUpdate": "subagent_state_update",
                "subagentSessionId": "child-1", "state": state]]))
            #expect(feature.selectedConversation?.pendingPermissions.map(\.id) == ["session-1", "sibling"])
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.isCancelling == false)
            #expect(feature.hasPendingPermission)
            let commands = connection.commands.count
            try feature.receive(event("permission", ["requestId": "late", "request": ["sessionId": "child-2"]]))
            #expect(feature.selectedConversation?.pendingPermissions.map(\.id) == ["session-1", "sibling"])
            #expect(connection.commands.count == commands, "Host already settled child requests; UI must not answer them again")
            clock.advance(1)
            feature.answerPermission(optionID: "allow_once")
            #expect(connection.commands.last?["requestId"] as? String == "session-1")
            #expect(feature.selectedConversation?.permission?.id == "sibling")
            try feature.receive(event("subagentStateUpdate", ["update": ["sessionUpdate": "subagent_state_update",
                "subagentSessionId": "sibling", "state": "cancelled"]]))
            #expect(feature.selectedConversation?.pendingPermissions.isEmpty == true)
            #expect(!feature.hasPendingPermission)
            #expect(attention == [true, false])
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            clock.advance(4)
            try feature.receive(event("turnFinished"))
            let turn = try #require(feature.selectedConversation?.completedTurns.last)
            #expect(turn.duration == 10)
            #expect(turn.toolDuration == 4, "Ended permissions must close their wait interval before the root finishes")
        }
    }

    @Test
    func delayedAutoFallbackNoticeAfterSelectingPlanDoesNotPolluteTheReply() async throws {
        try await withNoticeFeature { feature, connection, options in
            feature.setConfigOption("mode", value: "plan")
            var planOptions = options
            planOptions[1]["currentValue"] = "plan"
            try feature.receive(event("sessionConfigured", ["token": connection.commands.last?["token"] as Any,
                                                            "configOptions": planOptions]))
            try feature.send("Make a plan")
            let turn = feature.selectedConversation?.activeTurn
            let commands = connection.commands.count
            // Claude defers the startup fallback warning until the first prompt.
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == nil)
            #expect(feature.selectedConversation?.messages.map(\.text) == ["Make a plan"])
            #expect(feature.selectedConversation?.configOptions[1].currentValue == "plan")
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.errorMessage == nil)
            #expect(connection.commands.count == commands)
            try feature.receive(event("agentMessageChunk"))
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.messages.last?.text == "This project **builds** an IDE.")
        }
    }

    @Test
    func fallbackNoticeSurvivesPendingAndFailedModeChangesThenClearsOnConfirmation() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.receive(event("claudeAutoModeNotice"))
            let notice = try #require(feature.selectedConversation?.notice)
            #expect(notice.severity == .warning)
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            feature.setConfigOption("mode", value: "plan")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("sessionConfigured", ["token": "stale", "configOptions": []]))
            #expect(feature.selectedConversation?.notice == notice)
            try feature.receive(event("requestFailed", ["token": token, "message": "Mode rejected"]))
            #expect(feature.selectedConversation?.notice == notice)
            feature.setConfigOption("mode", value: "plan")
            var confirmed = options
            confirmed[1]["currentValue"] = "plan"
            try feature.receive(event("sessionConfigured", ["token": connection.commands.last?["token"] as Any,
                                                            "configOptions": confirmed]))
            #expect(feature.selectedConversation?.notice == nil)
        }
    }

    @Test
    func aNewFallbackWarningBeforeTheConfigResultUsesTheConfirmedMode() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]]))
            feature.setConfigOption("mode", value: "auto")
            let token = try #require(connection.commands.last?["token"])
            // Selecting unsupported Auto emits a notice before confirming Accept edits.
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("sessionConfigured", ["token": "stale", "configOptions": options]))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("sessionConfigured", ["token": token, "configOptions": options]))
            #expect(feature.selectedConversation?.notice?.isClaudeAutoModeFallback == true)
            #expect(feature.selectedConversation?.pendingModeNotice == nil)
            #expect(feature.selectedConversation?.configOptions[1].currentValue == "acceptEdits")
            #expect(feature.selectedConversation?.messages.isEmpty == true)
        }
    }

    @Test(arguments: [true, false])
    func newerErrorSupersedesPendingFallbackAcrossConfigurationResult(configurationSucceeds: Bool) async throws {
        try await withNoticeFeature { feature, connection, options in
            feature.setConfigOption("mode", value: "auto")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "notice", "severity": "error", "title": "Tool connection failed"]]))
            let error = try #require(feature.selectedConversation?.notice)
            #expect(error.severity == .error)
            if configurationSucceeds {
                try feature.receive(event("sessionConfigured", ["token": token, "configOptions": options]))
            } else {
                try feature.receive(event("requestFailed", ["token": token, "message": "Mode rejected"]))
            }
            #expect(feature.selectedConversation?.notice == error, "Replaying an older fallback must not overwrite the newer error")
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
        }
    }

    @Test(arguments: [true, false])
    func newerPendingFallbackSupersedesErrorAfterConfigurationResult(configurationSucceeds: Bool) async throws {
        try await withNoticeFeature { feature, connection, options in
            feature.setConfigOption("mode", value: "auto")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "notice", "severity": "error", "title": "Tool connection failed"]]))
            let error = try #require(feature.selectedConversation?.notice)
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == error, "The fallback still waits for the confirmed mode")
            if configurationSucceeds {
                try feature.receive(event("sessionConfigured", ["token": token, "configOptions": options]))
            } else {
                try feature.receive(event("requestFailed", ["token": token, "message": "Mode rejected"]))
            }
            #expect(feature.selectedConversation?.notice?.isClaudeAutoModeFallback == true)
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
        }
    }

    @Test
    func invalidAndOtherSessionNoticesDoNotSupersedePendingFallback() async throws {
        try await withNoticeFeature { feature, connection, options in
            feature.setConfigOption("mode", value: "auto")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("claudeAutoModeNotice"))
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "notice", "severity": "unknown", "title": "Invalid notice"]]))
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "notice", "severity": "error", "title": " \n"]]))
            try feature.receive(event("claudeAutoModeNotice", ["sessionId": "session-2", "update": ["sessionUpdate": "notice", "severity": "error", "title": "Other session error"]]))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("sessionConfigured", ["token": token, "configOptions": options]))
            #expect(feature.selectedConversation?.notice?.isClaudeAutoModeFallback == true)
            #expect(feature.conversations["session-2"]?.notice?.title == "Other session error")
        }
    }

    @Test
    func modelSwitchFallbackSurvivesItsFollowingConfigUpdateAndRejectedModeDoesNotShowIt() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "auto"]]))
            feature.setConfigOption("model", value: "another-model")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"]]))
            try feature.receive(event("claudeAutoModeNotice"))
            var changed = options
            changed[0]["currentValue"] = "another-model"
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": changed]]))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("sessionConfigured", ["token": token, "configOptions": changed]))
            #expect(feature.selectedConversation?.notice?.isClaudeAutoModeFallback == true)
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]]))
            feature.setConfigOption("mode", value: "auto")
            try feature.receive(event("claudeAutoModeNotice"))
            try feature.receive(event("requestFailed", ["token": connection.commands.last?["token"] as Any, "message": "Mode rejected"]))
            #expect(feature.selectedConversation?.notice == nil)
            #expect(feature.selectedConversation?.pendingModeNotice == nil)
            #expect(feature.selectedConversation?.configurationError == "Mode rejected")
        }
    }

    @Test
    func nativeModelSwitchKeepsItsNewFallbackNoticeWithoutALocalConfigRequest() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "auto"]]))
            let commands = connection.commands.count
            #expect(feature.selectedConversation?.pendingConfigToken == nil)
            // Native /model sends the downgrade and its warning before the full catalog.
            // No local selector request exists to buffer this warning.
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"]]))
            try feature.receive(event("claudeAutoModeNotice"))
            let notice = try #require(feature.selectedConversation?.notice)
            var changedModel = options
            changedModel[0]["currentValue"] = "another-model"
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": changedModel]]))
            #expect(feature.selectedConversation?.notice == notice, "The new model's downgrade reason must survive its configuration snapshot")
            #expect(feature.selectedConversation?.configOptions[0].currentValue == "another-model")
            #expect(feature.selectedConversation?.configOptions[1].currentValue == "acceptEdits")
            #expect(feature.selectedConversation?.messages.isEmpty == true)
            #expect(connection.commands.count == commands)

            // The transition applies to one snapshot; a later model switch clears
            // the warning that now belongs to the previous model.
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": changedModel]]))
            #expect(feature.selectedConversation?.notice == notice)
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": options]]))
            #expect(feature.selectedConversation?.notice == nil)
        }
    }

    @Test
    func nativeFallbackTransitionStaysWithItsSessionAndEndsAtTheNextPrompt() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.send("First session")
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "auto"]]))
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"]]))
            try feature.receive(event("claudeAutoModeNotice"))
            let firstNotice = try #require(feature.selectedConversation?.notice)
            feature.startNewConversation()
            try feature.send("Second session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                        "sessionId": "session-2", "configOptions": options]))
            var changedModel = options
            changedModel[0]["currentValue"] = "another-model"
            try feature.receive(event("claudeAutoModeNotice", ["sessionId": "session-2", "update": ["sessionUpdate": "config_option_update", "configOptions": changedModel]]))
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": changedModel]]))
            #expect(feature.conversations["session-1"]?.notice == firstNotice)
            #expect(feature.selectedConversation?.notice == nil)
            feature.selectSession("session-1")
            try feature.receive(event("turnFinished"))
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "auto"]]))
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"]]))
            // An incomplete old transition must not bless a new turn's warning.
            try feature.send("Next turn")
            try feature.receive(event("claudeAutoModeNotice"))
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": options]]))
            #expect(feature.selectedConversation?.notice == nil)
        }
    }

    @Test
    func upstreamModeAndModelChangesClearOnlyTheObsoleteFallbackNotice() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.receive(event("claudeAutoModeNotice"))
            let commands = connection.commands.count
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "unknown"]]))
            #expect(feature.selectedConversation?.notice != nil)
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]]))
            #expect(feature.selectedConversation?.notice == nil)
            #expect(connection.commands.count == commands)
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "acceptEdits"]]))
            try feature.receive(event("claudeAutoModeNotice"))
            var changedModel = options
            changedModel[0]["currentValue"] = "another-model"
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "config_option_update", "configOptions": changedModel]]))
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("claudeAutoModeNotice", ["update": ["sessionUpdate": "notice", "severity": "error", "title": "Tool connection failed"]]))
            try feature.receive(event("currentModeUpdate", ["update": ["sessionUpdate": "current_mode_update", "currentModeId": "plan"]]))
            #expect(feature.selectedConversation?.notice?.title == "Tool connection failed")
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice?.title == "Tool connection failed", "An obsolete advisory must not replace an unrelated error")
        }
    }

    @Test
    func noticeBeforeSessionAcknowledgementIsReconciledWithConfirmedMode() async throws {
        try await withNoticeFeature { feature, connection, options in
            // Another session's updates can precede its creation response.
            feature.startNewConversation()
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("claudeAutoModeNotice", ["sessionId": "session-2"]))
            var plan = options
            plan[1]["currentValue"] = "plan"
            try feature.receive(event("sessionCreated", ["token": token, "sessionId": "session-2", "configOptions": plan]))
            #expect(feature.selectedConversation?.notice == nil)
            #expect(feature.selectedConversation?.messages.isEmpty == true)
        }
    }

    @Test
    func historyCompletionKeepsReplayedUsageWhileReconcilingModeNotice() async throws {
        try await withNoticeFeature { feature, connection, options in
            feature.selectSession("history-session")
            let token = try #require(connection.commands.last?["token"])
            // Replay precedes the final catalog: the confirmed Plan mode must
            // clear the obsolete advisory without dropping actual context usage.
            try feature.receive(event("claudeAutoModeNotice", ["sessionId": "history-session"]))
            #expect(feature.selectedConversation?.notice != nil)
            try feature.receive(event("usageUpdate", ["sessionId": "history-session", "update": [
                "sessionUpdate": "usage_update", "used": 125300, "size": 300000,
                "_meta": ["lithe": ["contextUsageSource": "history"]]]]))
            var plan = options
            plan[1]["currentValue"] = "plan"
            try feature.receive(event("sessionLoaded", ["token": token, "sessionId": "history-session", "configOptions": plan]))
            #expect(feature.selectedConversation?.notice == nil)
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 125300)
            #expect(feature.selectedConversation?.contextUsageIsHistorical == true)
            #expect(feature.selectedConversation?.isAttached == true)
            #expect(feature.selectedConversation?.configOptions[1].currentValue == "plan")
        }
    }

    @Test
    func noticesAreSessionLocalDismissibleAndClearedByNextPromptAndDisconnect() async throws {
        try await withNoticeFeature { feature, connection, options in
            try feature.send("First task")
            try feature.receive(event("turnFinished"))
            feature.startNewConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                                                        "sessionId": "session-2", "configOptions": options]))
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == nil)
            feature.selectSession("session-1")
            let first = try #require(feature.selectedConversation?.notice)
            feature.dismissNotice("stale", in: "session-1")
            #expect(feature.selectedConversation?.notice == first)
            feature.dismissNotice(first.id, in: "session-1")
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("claudeAutoModeNotice"))
            try feature.send("Continue")
            #expect(feature.selectedConversation?.notice == nil)
            try feature.receive(event("claudeAutoModeNotice"))
            let messages = feature.selectedConversation?.messages
            await feature.stop()
            #expect(feature.selectedConversation?.notice == nil)
            #expect(feature.selectedConversation?.messages == messages)
            try feature.receive(event("claudeAutoModeNotice"))
            #expect(feature.selectedConversation?.notice == nil)
        }
    }

    @Test
    func noticeParsingIsBoundedAndNeverClassifiesAssistantText() async throws {
        #expect(AgentSessionNotice.parse(["severity": "unknown", "title": "Warning"]) == nil)
        #expect(AgentSessionNotice.parse(["severity": "warning", "title": " \n"]) == nil)
        let bounded = try #require(AgentSessionNotice.parse(["severity": "info", "title": String(repeating: "x", count: 1000),
                                                           "description": String(repeating: "y", count: 10000)]))
        #expect(bounded.title.count == 256)
        #expect(bounded.detail?.count == 4096)
        try await withNoticeFeature { feature, _, _ in
            let text = "**Auto mode unavailable:** the selected model does not support Auto mode; using Accept edits instead."
            try feature.receive(event("agentMessageChunk", ["update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]]))
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.messages.last?.text == text)
            #expect(feature.selectedConversation?.notice == nil)
        }
    }

    private func withNoticeFeature(_ run: @MainActor (AgentConnectionModel, TestAgentConnection, [[String: Any]]) async throws -> Void) async throws {
        let transport = TestAgentTransport()
        let feature = AgentConnectionModel(transport: transport)
        let launch = AgentLaunchConfiguration(agentID: "claude-acp", command: "", arguments: [],
            workspaceURL: configuration.workspaceURL, dataDirectory: configuration.dataDirectory,
            providerProtocol: "anthropicMessages", providerEndpoint: "https://gateway.example.com/v1",
            apiKey: "test-key", providerName: "Example", model: "", allowsInsecureHTTP: false)
        do {
            try feature.connect(configuration: launch)
            try feature.receive(event("ready"))
            feature.prepareConversation()
            let connection = transport.connections[0]
            let fixture = try #require(JSONSerialization.jsonObject(with: Data(event("sessionConfigured").utf8)) as? [String: Any])
            var options = try #require(fixture["configOptions"] as? [[String: Any]])
            options[0]["options"] = [["value": "example-model", "name": "Example Model"], ["value": "another-model", "name": "Another Model"]]
            options[1]["currentValue"] = "acceptEdits"
            options[1]["options"] = [["value": "acceptEdits", "name": "Accept edits"], ["value": "plan", "name": "Plan"], ["value": "auto", "name": "Auto"]]
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any, "configOptions": options]))
            try await run(feature, connection, options)
        } catch { await feature.stop(); throw error }
        await feature.stop()
    }

    @Test
    func steeringSendsDuringResponseAndAcknowledgesWithoutStartingAnotherTurn() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.receive(event("ready", ["canSteer": true]))
            try feature.send("Inspect everything")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = feature.selectedConversation?.activeTurn
            try feature.receive(event("agentMessageChunk"))
            try feature.send("Focus on login")
            #expect(connection.commands.last?["kind"] as? String == "steer")
            let token = try #require(connection.commands.last?["token"] as? String)
            #expect(feature.selectedConversation?.messages.last?.delivery == .sending)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Duplicate") }
            // An upstream live echo must not append the already visible input.
            let count = feature.selectedConversation?.messages.count
            try feature.receive(event("userMessageChunk"))
            #expect(feature.selectedConversation?.messages.count == count)
            try feature.receive(event("steeringResult", ["token": token]))
            #expect(feature.selectedConversation?.messages.last?.delivery == .received)
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.pendingSteeringToken == nil)
            #expect(feature.selectedConversation?.activeTurn == turn)
            feature.cancel()
            #expect(connection.commands.last?["kind"] as? String == "cancel")
        }
    }

    @Test
    func steeringFailureAndDisconnectPreserveInputAndTheOriginalTurn() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.receive(event("ready", ["canSteer": true]))
            try feature.send("Inspect")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Supplement")
            let token = try #require(connection.commands.last?["token"] as? String)
            try feature.receive(event("steeringResult", ["token": token, "outcome": "failed", "message": "Rejected"]))
            #expect(feature.selectedConversation?.messages.last?.delivery == .failed("Rejected"))
            #expect(feature.selectedConversation?.isResponding == true)
            try feature.send("Another supplement")
            let lateToken = try #require(connection.commands.last?["token"] as? String)
            await feature.stop()
            #expect(feature.canSteer == false)
            #expect(feature.selectedConversation?.pendingSteeringToken == nil)
            #expect(feature.selectedConversation?.messages.last?.text == "Another supplement")
            try feature.receive(event("steeringResult", ["token": lateToken]))
            #expect(feature.selectedConversation?.messages.last?.delivery != .received)
        }
    }

    @Test
    func steeringCompletionRaceResendsOnlyAnExplicitlyUnconsumedMessageOnce() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.receive(event("ready", ["canSteer": true]))
            try feature.send("Inspect")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Supplement")
            let token = try #require(connection.commands.last?["token"] as? String)
            let messageID = feature.selectedConversation?.messages.last?.id
            let count = connection.commands.count
            try feature.receive(event("steeringResult", ["token": token, "outcome": "promptRequired"]))
            #expect(connection.commands.count == count)
            try feature.receive(event("turnFinished"))
            #expect(connection.commands.last?["kind"] as? String == "prompt")
            #expect(connection.commands.last?["text"] as? String == "Supplement")
            #expect(feature.selectedConversation?.activeTurn?.id == messageID)
            #expect(feature.selectedConversation?.messages.filter { $0.text == "Supplement" }.count == 1)
            try feature.receive(event("steeringResult", ["token": token, "outcome": "promptRequired"]))
            #expect(connection.commands.count == count + 1)
        }
    }

    @Test
    func steeringStopPreventsAnUnconsumedSupplementFromStartingANewTurn() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.receive(event("ready", ["canSteer": true]))
            try feature.send("Inspect")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Supplement")
            let token = try #require(connection.commands.last?["token"] as? String)
            feature.cancel()
            let count = connection.commands.count
            try feature.receive(event("turnFinished", ["stopReason": "cancelled"]))
            try feature.receive(event("steeringResult", ["token": token, "outcome": "promptRequired"]))
            #expect(connection.commands.count == count)
            #expect(feature.selectedConversation?.isResponding == false)
            #expect(feature.selectedConversation?.messages.last?.delivery != .received)
        }
    }

    @Test
    func steeringStopAlsoRevokesAnAlreadyAcknowledgedFallback() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.receive(event("ready", ["canSteer": true]))
            try feature.send("Inspect")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.send("Supplement")
            let token = try #require(connection.commands.last?["token"] as? String)
            try feature.receive(event("steeringResult", ["token": token, "outcome": "promptRequired"]))
            feature.cancel()
            let count = connection.commands.count
            try feature.receive(event("turnFinished", ["stopReason": "cancelled"]))
            #expect(connection.commands.count == count)
            #expect(feature.selectedConversation?.isResponding == false)
            #expect(feature.selectedConversation?.messages.last?.delivery != .received)
        }
    }

    @Test
    func quietNoticeKeepsTheTurnBusyAndContinueWaitingDoesNotReplayIt() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Build the project")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = feature.selectedConversation?.activeTurn
            let commandCount = connection.commands.count
            clock.advance(3600)
            try feature.receive(event("turnActivityQuiet"))
            #expect(feature.selectedConversation?.isQuiet == true)
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.errorMessage == nil)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }
            feature.continueWaiting()
            #expect(feature.selectedConversation?.isQuiet == false)
            #expect(connection.commands.count == commandCount)
            try feature.receive(event("turnActivityQuiet"))
            try feature.receive(event("turnActivityResumed"))
            #expect(feature.selectedConversation?.isQuiet == false)
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 3600)
            try feature.receive(event("turnActivityQuiet"))
            #expect(feature.selectedConversation?.isQuiet == false)
        }
    }

    @Test
    func quietNoticeIsScopedToItsSessionAndCannotOverrideStopping() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("First turn")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            feature.startNewConversation()
            try feature.send("Second turn")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any, "sessionId": "session-2"]))
            try feature.receive(event("turnActivityQuiet"))
            #expect(feature.conversations["session-1"]?.isQuiet == true)
            #expect(feature.selectedConversation?.isQuiet == false)
            feature.cancel()
            try feature.receive(event("turnActivityQuiet", ["sessionId": "session-2"]))
            #expect(feature.selectedConversation?.isQuiet == false)
            #expect(feature.selectedConversation?.responseStatus == .stopping)
        }
    }

    @Test
    func nativeRecoveryKeepsOneTurnAndContinueWaitingCannotReplayTools() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Start the service and finish the files")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("toolCall"))
            let messages = feature.selectedConversation?.messages
            let turn = feature.selectedConversation?.activeTurn
            let commands = connection.commands.count
            clock.advance(301)
            try feature.receive(event("turnRecovering"))
            try feature.receive(event("turnActivityQuiet"))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(feature.selectedConversation?.retryAttempt == 6)
            #expect(feature.selectedConversation?.retryMaxAttempts == nil)
            #expect(feature.selectedConversation?.isQuiet == true)
            #expect(feature.selectedConversation?.messages == messages)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }
            feature.continueWaiting()
            #expect(feature.selectedConversation?.isQuiet == false)
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(connection.commands.count == commands)
            try feature.receive(event("turnActivityResumed"))
            try feature.receive(event("agentMessageChunk"))
            #expect(feature.selectedConversation?.responseStatus != .retrying)
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 301)
            try feature.receive(event("turnRecovering"))
            #expect(feature.selectedConversation?.responseStatus == nil)
        }
    }

    @Test
    func nativeRecoveryTerminalFailurePreservesWorkForExplicitContinuation() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Finish the task")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("toolCall", ["update": ["sessionUpdate": "tool_call", "toolCallId": "completed", "kind": "execute", "title": "Start service", "status": "completed"]]))
            let messages = feature.selectedConversation?.messages
            try feature.receive(event("turnRecovering"))
            let commands = connection.commands.count
            try feature.receive(event("requestFailed", ["token": NSNull(), "message": "Stream recovery exhausted"]))
            #expect(feature.selectedConversation?.isResponding == false)
            #expect(feature.selectedConversation?.messages == messages)
            #expect(feature.selectedConversation?.errorMessage == "Stream recovery exhausted")
            #expect(connection.commands.count == commands, "Terminal failure cannot resend completed tools")
            try feature.send("Check completed work, then finish the remaining steps")
            #expect(connection.commands.last?["kind"] as? String == "prompt")
            #expect(connection.commands.last?["sessionId"] as? String == "session-1")
        }
    }

    @Test
    func codexNativeFailureMetadataAndHostCountsKeepOneTimedTurn() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Try Codex")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = feature.selectedConversation?.activeTurn
            try feature.receive(event("codexNativeRetry"))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            try feature.receive(event("turnRetrying", ["turnId": "upstream-turn-1"]))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(feature.selectedConversation?.retryAttempt == 2)
            #expect(feature.selectedConversation?.activeTurn == turn)
            clock.advance(20)
            try feature.receive(event("turnCancelling"))
            #expect(feature.selectedConversation?.responseStatus == .stopping)
            try feature.receive(event("requestFailed", ["message": "Reconnecting exceeded 20 seconds. Local fixture failure"]))
            #expect(feature.selectedConversation?.retryAttempt == nil)
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 20)
            #expect(feature.selectedConversation?.errorMessage?.contains("Local fixture failure") == true)
        }
    }

    @Test
    func hostReconnectionShowsAttemptCountAndClearsOnProgressOrFailure() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Try the service")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = feature.selectedConversation?.activeTurn
            try feature.receive(event("turnRetrying"))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(feature.selectedConversation?.retryAttempt == 2)
            #expect(feature.selectedConversation?.retryMaxAttempts == 5)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.errorMessage == nil)
            clock.advance(8)
            try feature.receive(event("turnRetrying", ["attempt": 5]))
            #expect(feature.selectedConversation?.retryAttempt == 5)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }
            try feature.receive(event("agentThoughtChunk"))
            #expect(feature.selectedConversation?.responseStatus == .thinking)
            #expect(feature.selectedConversation?.retryAttempt == nil)
            try feature.receive(event("requestFailed"))
            #expect(feature.selectedConversation?.responseStatus == nil)
            #expect(feature.selectedConversation?.retryAttempt == nil)
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 8)
            try feature.receive(event("turnRetrying"))
            #expect(feature.selectedConversation?.responseStatus == nil)
            try feature.send("Next turn")
            try feature.receive(event("turnRetrying"))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            try feature.receive(event("turnRetrying", ["turnId": "host-turn-2"]))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            feature.cancel()
            try feature.receive(event("turnRetrying", ["turnId": "host-turn-2", "attempt": 3]))
            #expect(feature.selectedConversation?.responseStatus == .stopping)
        }
    }

    @Test(arguments: [false, true])
    func validPlanProgressEndsReconnectingWithoutEndingTheTurn(emptyPlan: Bool) async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Inspect the project")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = try #require(feature.selectedConversation?.activeTurn)
            try feature.receive(event("turnRetrying"))
            clock.advance(8)
            // A malformed plan is not evidence that the connection recovered.
            try feature.receive(event("plan", ["update": ["sessionUpdate": "plan"]]))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(feature.selectedConversation?.retryAttempt == 2)
            let entries: [[String: Any]] = emptyPlan ? [] : [
                ["content": "Inspect files", "priority": "medium", "status": "in_progress"]
            ]
            try feature.receive(event("plan", ["update": ["sessionUpdate": "plan", "entries": entries]]))
            #expect(feature.selectedConversation?.plan?.entries.map(\.content) == (emptyPlan ? nil : ["Inspect files"]))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            #expect(feature.selectedConversation?.retryAttempt == nil)
            #expect(feature.selectedConversation?.retryMaxAttempts == nil)
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.activeTurn?.elapsed(at: clock.instant) == 8)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }
            // A later plan must preserve a reply or reasoning already observed.
            try feature.receive(event("agentThoughtChunk"))
            try feature.receive(event("plan"))
            #expect(feature.selectedConversation?.responseStatus == .thinking)
            try feature.receive(event("agentMessageChunk"))
            try feature.receive(event("plan"))
            #expect(feature.selectedConversation?.responseStatus == .responding)
            clock.advance(3)
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 11)
        }
    }

    @Test(arguments: [false, true])
    func planProgressPreservesPermissionAndStoppingPriority(stopping: Bool) async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Inspect the project")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let turn = feature.selectedConversation?.activeTurn
            try feature.receive(event("turnRetrying"))
            if stopping { feature.cancel() }
            else {
                try feature.receive(event("permission"))
                // Recovery notifications can arrive while approval is pending.
                try feature.receive(event("turnRetrying"))
            }
            #expect(feature.selectedConversation?.retryAttempt == 2)
            let permissionID = feature.selectedConversation?.permission?.id
            try feature.receive(event("plan"))
            #expect(feature.selectedConversation?.plan?.currentEntry?.content == "Run the tests")
            #expect(feature.selectedConversation?.responseStatus == (stopping ? .stopping : .waitingForPermission))
            #expect(feature.selectedConversation?.permission?.id == permissionID)
            // Plans and retries never replace or restart the turn; only its
            // tool-wait clock may start while approval is pending.
            #expect(feature.selectedConversation?.activeTurn?.id == turn?.id)
            #expect(feature.selectedConversation?.activeTurn?.startedAt == turn?.startedAt)
            if !stopping {
                #expect(feature.selectedConversation?.retryAttempt == nil)
                #expect(feature.selectedConversation?.retryMaxAttempts == nil)
                feature.answerPermission(optionID: "allow_once")
                #expect(feature.selectedConversation?.responseStatus == .waiting)
            }
        }
    }

    @Test
    func invalidHostRetryCountsCannotInventReconnectingState() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Try the service")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            for fields: [String: Any] in [["attempt": 0], ["attempt": 6], ["maxAttempts": 0],
                                         ["attempt": "2"], ["turnId": ""]] {
                try feature.receive(event("turnRetrying", fields))
                #expect(feature.selectedConversation?.responseStatus == .waiting)
            }
        }
    }

    @Test
    func responseStatusUsesObservedProgressAndPermissionInsteadOfElapsedTime() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Create a sample")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            clock.advance(540)
            #expect(feature.selectedConversation?.responseStatus == .waiting, "Silence cannot prove reasoning or retries")
            try feature.receive(event("agentThoughtChunk"))
            #expect(feature.selectedConversation?.responseStatus == .thinking)
            try feature.receive(event("agentMessageChunk"))
            #expect(feature.selectedConversation?.responseStatus == .responding)
            try feature.receive(event("toolCall"))
            #expect(feature.selectedConversation?.responseStatus == .runningTools)
            try feature.receive(event("permission"))
            #expect(feature.selectedConversation?.responseStatus == .waitingForPermission)
            feature.answerPermission(optionID: "allow_once")
            #expect(feature.selectedConversation?.responseStatus == .runningTools)
            try feature.receive(event("toolCallUpdate"))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.responseStatus == nil)
            #expect(feature.selectedConversation?.completedTurns.last?.duration == 540)
            try feature.send("Continue")
            #expect(feature.selectedConversation?.responseStatus == .waiting)
        }
    }

    @Test
    func titlelessRetryMetadataKeepsTheTurnBusyAndProgressClearsIt() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Try the service")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            let title = feature.sessions.first?.title
            let turn = feature.selectedConversation?.activeTurn
            try feature.receive(event("codexRetry"))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            #expect(feature.selectedConversation?.activeTurn == turn)
            #expect(feature.selectedConversation?.isResponding == true)
            #expect(feature.selectedConversation?.errorMessage == nil)
            #expect(feature.sessions.first?.title == title)
            #expect(throws: AgentConversationError.sessionBusy) { try feature.send("Overlap") }
            try feature.receive(event("agentThoughtChunk"))
            #expect(feature.selectedConversation?.responseStatus == .thinking)
            try feature.receive(event("codexRetry"))
            try feature.receive(event("agentMessageChunk"))
            #expect(feature.selectedConversation?.responseStatus == .responding)
            try feature.receive(event("turnFinished"))
            #expect(feature.selectedConversation?.responseStatus == nil)
            try feature.receive(event("codexRetry"))
            #expect(feature.selectedConversation?.responseStatus == nil, "Late retries must not resurrect a finished turn")
            try feature.send("Next turn")
            try feature.receive(event("codexRetry"))
            #expect(feature.selectedConversation?.responseStatus == .waiting, "The previous upstream turn must stay retired")
            try feature.receive(event("codexRetry", ["update": retryUpdate(turnID: "upstream-turn-2")]))
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            try feature.receive(event("toolCall"))
            #expect(feature.selectedConversation?.responseStatus == .runningTools)
            try feature.receive(event("requestFailed"))
            #expect(feature.selectedConversation?.responseStatus == nil)
        }
    }

    @Test
    func retryAndStoppingStatusAreIsolatedBySessionAndConnectionLifecycle() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("First session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("codexRetry"))
            feature.startNewConversation()
            try feature.send("Second session")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any, "sessionId": "session-2"]))
            #expect(feature.selectedConversation?.responseStatus == .waiting)
            #expect(feature.conversations["session-1"]?.responseStatus == .retrying)
            feature.cancel()
            try feature.receive(event("codexRetry", ["sessionId": "session-2", "update": retryUpdate(turnID: "second-turn")]))
            try feature.receive(event("agentThoughtChunk", ["sessionId": "session-2"]))
            #expect(feature.selectedConversation?.responseStatus == .stopping)
            #expect(feature.conversations["session-1"]?.responseStatus == .retrying)
            try feature.receive(event("turnCancelled", ["sessionId": "session-2"]))
            #expect(feature.selectedConversation?.responseStatus == nil)
            feature.selectSession("session-1")
            #expect(feature.selectedConversation?.responseStatus == .retrying)
            try feature.receive(event("stopped"))
            #expect(feature.conversations.values.allSatisfy { $0.responseStatus == nil })
        }
    }

    @Test
    func invalidRetryMetadataAndHistoricalToolsCannotInventActivity() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Wait for the service")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            for error in [["willRetry": false, "turnId": "turn"] as [String: Any],
                          ["willRetry": "true", "turnId": "turn"],
                          ["willRetry": true], ["willRetry": true, "turnId": ""]] {
                try feature.receive(event("sessionInfo", ["update": ["sessionUpdate": "session_info_update",
                    "_meta": ["codex": ["error": error]]]]))
                #expect(feature.selectedConversation?.responseStatus == .waiting)
            }
        }
        var history = AgentConversation()
        history.messages = [AgentConversationMessage(id: "old-tool", role: .tool, text: "Historical", toolStatus: .inProgress),
                            AgentConversationMessage(id: "new-turn", role: .user, text: "Continue")]
        history.activeTurn = AgentTurnStatistics(id: "new-turn", startedAt: .now)
        history.isResponding = true
        #expect(history.responseStatus == .waiting)
    }

    @Test
    func repeatedOutputChunksKeepConversationPublicationCoalesced() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Stream a response")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            var publications = 0
            let subscription = feature.$conversations.sink { _ in publications += 1 }
            defer { subscription.cancel() }
            let initial = publications
            // Deliver one synchronous burst, before the owned flush task runs.
            for _ in 0..<100 { try feature.receive(event("agentMessageChunk")) }
            #expect(feature.selectedConversation?.responseStatus == .responding)
            #expect(publications - initial == 1, "A text burst must publish its phase once, keeping transcript buffering intact")
        }
    }

    private func retryUpdate(turnID: String) -> [String: Any] {
        ["sessionUpdate": "session_info_update", "_meta": ["codex": ["error": ["willRetry": true, "turnId": turnID]]]]
    }

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
            try feature.send("Keep this session")
            try feature.receive(event("turnFinished"))
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
            #expect(feature.selectedConversation?.messages.map(\.role) == [.user], "Usage updates do not append transcript messages")
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

    @Test(arguments: ["matching", "different-model", "unknown-model", "live-zero", "invalid-report", "native-history"])
    func historyContextRestoresOnlyMatchingReportsAndPrefersReplay(scenario: String) async throws {
        let persistence = InMemoryStatisticsPersistence()
        func store() -> AgentSessionStatisticsStore {
            AgentSessionStatisticsStore(persistence: persistence, agentID: "codex",
                workspaceURL: { URL(fileURLWithPath: "/tmp/lithe-context-workspace") })
        }
        func options(_ model: String) -> [[String: Any]] {
            [["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
              "options": [["value": "a", "name": "A"], ["value": "b", "name": "B"]]]]
        }
        try await withStatisticsFeature { feature, connection, _ in
            feature.statisticsStore = store()
            try feature.send("Keep this report")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                "configOptions": options("a")]))
            try feature.receive(event("usageUpdate"))
            #expect(persistence.saves == 0, "Streaming usage does not write on every notification")
            try feature.receive(event("turnFinished"))
            await feature.stop()
            await feature.stop()
        }
        #expect(store().record(for: "session-1")?.contextUsage?.usedTokens == 18700)
        try await withStatisticsFeature { feature, connection, _ in
            feature.statisticsStore = store()
            feature.selectSession("session-1")
            let token = try #require(connection.commands.last?["token"])
            #expect(feature.selectedConversation?.contextUsage == nil, "Unconfirmed history has no live capacity")
            if scenario == "live-zero" || scenario == "invalid-report" {
                try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 0,
                    "size": scenario == "live-zero" ? 100000 : 0]]))
            }
            if scenario == "native-history" {
                try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 125300,
                    "size": 300000, "_meta": ["lithe": ["contextUsageSource": "history"]]]]))
            }
            let loadedOptions = scenario == "unknown-model" ? [] : options(scenario == "different-model" ? "b" : "a")
            try feature.receive(event("sessionLoaded", ["token": token, "configOptions": loadedOptions]))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens ==
                (scenario == "matching" ? 18700 : scenario == "live-zero" ? 0 : scenario == "native-history" ? 125300 : nil))
            #expect(feature.selectedConversation?.contextUsageIsHistorical == (scenario == "matching" || scenario == "native-history"))
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "usage_update", "used": 1000, "size": 100000]]))
            #expect(feature.selectedConversation?.contextUsage?.usedTokens == 1000, "Compaction replaces the snapshot")
            #expect(feature.selectedConversation?.contextUsageIsHistorical == false)
            #expect(store().record(for: "session-1")?.contextUsage?.usedTokens == 1000, "Idle reports after turn completion are saved")
            feature.selectSession("session-2")
            try feature.receive(event("sessionLoaded", ["sessionId": "session-2", "token": connection.commands.last?["token"] as Any,
                "configOptions": options("a")]))
            #expect(feature.selectedConversation?.contextUsage == nil, "Snapshots are scoped to the session")
        }
    }

    @Test
    func modelChangesInvalidatePersistedContextWithoutSavingPartialCalls() async throws {
        let persistence = InMemoryStatisticsPersistence()
        let store = AgentSessionStatisticsStore(persistence: persistence, agentID: "codex",
            workspaceURL: { URL(fileURLWithPath: "/tmp/lithe-context-workspace") })
        func options(_ model: String) -> [[String: Any]] {
            [["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": model,
              "options": [["value": "a", "name": "A"], ["value": "b", "name": "B"]]]]
        }
        try await withStatisticsFeature { feature, connection, _ in
            feature.statisticsStore = store
            feature.prepareConversation()
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any,
                "configOptions": options("a")]))
            try feature.receive(event("usageUpdate"))
            #expect(store.record(for: "session-1")?.contextUsage != nil, "A usage-only record is retained")
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "config_option_update", "configOptions": options("b")]]))
            #expect(store.record(for: "session-1") == nil, "An invalidated usage-only record is removed")
            try feature.send("First")
            try feature.receive(event("usageUpdate"))
            try feature.receive(event("turnFinished"))
            try feature.send("Second")
            try feature.receive(event("modelCall"))
            try feature.receive(event("usageUpdate", ["update": ["sessionUpdate": "config_option_update", "configOptions": options("a")]]))
            #expect(store.record(for: "session-1")?.contextUsage == nil)
            #expect(store.record(for: "session-1")?.turnCount == 1)
            #expect(store.record(for: "session-1")?.modelCalls.callCount == 0)
        }
    }

    @Test
    func storedContextValidatesCapacityAndOldStatisticsRemainReadable() throws {
        let encoder = JSONEncoder()
        let old = AgentSessionStatisticsRecord(turnCount: 2)
        let data = try encoder.encode(old)
        let decoded = try JSONDecoder().decode(AgentSessionStatisticsRecord.self, from: data)
        #expect(decoded.turnCount == 2 && decoded.contextUsage == nil)
        let zero = try #require(AgentContextUsage(usedTokens: 0, capacityTokens: 100))
        #expect(try JSONDecoder().decode(AgentContextUsage.self, from: encoder.encode(zero)) == zero)
        for payload in ["{\"usedTokens\":0,\"capacityTokens\":0}", "{\"usedTokens\":-1,\"capacityTokens\":100}"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentContextUsage.self, from: Data(payload.utf8)) }
        }
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
            #expect(feature.conversations["empty-1"] == nil, "New Chat immediately drops the preceding unprompted session")
            #expect(!feature.sessions.contains { $0.id == "empty-1" })
            #expect(feature.openSessionIDs == ["session-2", "empty-2"])
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

    @Test
    func toolAndPermissionWaitsAreTimedOnceAndCountedPerTurn() async throws {
        try await withStatisticsFeature { feature, connection, clock in
            try feature.send("Run the tests")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            clock.advance(2)
            try feature.receive(event("toolCall"))
            clock.advance(3)
            // A permission overlapping the running tool must not double the wait.
            try feature.receive(event("permission"))
            clock.advance(4)
            feature.answerPermission(optionID: "allow_once")
            clock.advance(1)
            try feature.receive(event("toolCallUpdate"))
            clock.advance(5)
            #expect(feature.selectedConversation?.sessionStatistics.toolCallCount == 1)
            #expect(feature.selectedConversation?.sessionStatistics.turnCount == 1)
            try feature.receive(event("turnFinished"))
            let turn = try #require(feature.selectedConversation?.completedTurns.last)
            #expect(turn.duration == 15)
            #expect(turn.toolDuration == 8)
            #expect(turn.toolCallCount == 1)
            #expect(feature.selectedConversation?.sessionStatistics.toolDuration == 8)
        }
    }

    @Test
    func observedModelCallsDriveStepsSpeedAndProviderTokens() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("Explain the build")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("modelCall"))
            try feature.receive(event("modelCallNonStreaming"))
            // Calls the Host could not attribute must not be assigned by guessing.
            var unattributed = try #require(JSONSerialization.jsonObject(with: Data(try event("modelCall").utf8)) as? [String: Any])
            unattributed.removeValue(forKey: "sessionId")
            try feature.receive(String(decoding: JSONSerialization.data(withJSONObject: unattributed), as: UTF8.self))
            try feature.receive(event("turnFinishedWithUsage"))
            let statistics = try #require(feature.selectedConversation?.sessionStatistics)
            let calls = try #require(statistics.modelCalls)
            #expect(calls.callCount == 2)
            #expect(calls.nonStreamingCount == 1)
            #expect(calls.duration == 9.4)
            #expect(calls.averageFirstToken == 0.82)
            // Only streamed output after the first token contributes to speed.
            #expect(abs((calls.outputTokensPerSecond ?? 0) - 640 / 5.58) < 0.001)
            #expect(calls.latestContext?.mcpToolCount == 40)
            #expect(feature.selectedConversation?.completedTurns.last?.modelCalls.callCount == 2)
            // Provider counters replace Agent-reported totals when observed.
            let tokens = try #require(statistics.tokens)
            #expect(tokens.source == .modelCalls)
            #expect(tokens.uncachedInputTokens == 1700)
            #expect(tokens.cacheReadTokens == 42000)
            #expect(tokens.outputTokens == 940)
            #expect(tokens.reasoningTokens == 100)
            #expect(abs((tokens.cacheHitRate ?? 0) - 42000.0 / 44500) < 0.0001)
        }
    }

    @Test
    func lateCallsFromAFinishedTurnCountForTheSessionOnly() async throws {
        try await withStatisticsFeature { feature, connection, _ in
            try feature.send("First")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("turnFinished"))
            // The next turn starts before the previous turn's stream reports.
            try feature.send("Second")
            try feature.receive(event("modelCallAfterTurn"))
            #expect(feature.selectedConversation?.activeTurn?.modelCalls.callCount == 0)
            #expect(feature.selectedConversation?.modelCalls.callCount == 1)
            try feature.receive(event("modelCall"))
            #expect(feature.selectedConversation?.activeTurn?.modelCalls.callCount == 1)
            #expect(feature.selectedConversation?.modelCalls.callCount == 2)
        }
    }

    @Test
    func callsWithoutUsageMakeTokenTotalsAnExplicitLowerBound() throws {
        var conversation = AgentConversation()
        conversation.recordModelCall(try modelCall(usage: ["inputTokens": 100, "cacheReadTokens": 900,
                                                            "cacheWriteTokens": 0, "outputTokens": 50]))
        // An interrupted stream or a provider without final usage reports no counters.
        conversation.recordModelCall(try modelCall(usage: nil))
        let tokens = try #require(conversation.sessionStatistics.tokens)
        #expect(tokens.source == .modelCalls)
        #expect(tokens.totalTokens == 1050)
        #expect(tokens.callsMissingUsage == 1)
        #expect(conversation.modelCalls.callCount == 2)
        #expect(conversation.modelCalls.callsWithUsage == 1)
    }

    @Test
    func contextCompositionFollowsMainRequestsWithAndWithoutTools() throws {
        // Agents that never send tools refresh the composition on every request.
        var toolless = AgentModelCallTotals()
        toolless.record(try modelCall(context: context(messages: 1000, tools: 0)))
        toolless.record(try modelCall(context: context(messages: 5000, tools: 0)))
        #expect(toolless.latestContext?.messageTokens == 5000)
        // Once tools are sent, tool-less auxiliary requests do not replace it.
        var main = AgentModelCallTotals()
        main.record(try modelCall(context: context(messages: 1000, tools: 0)))
        main.record(try modelCall(context: context(messages: 8000, tools: 12)))
        main.record(try modelCall(context: context(messages: 40, tools: 0)))
        #expect(main.latestContext?.messageTokens == 8000)
        main.record(try modelCall(context: context(messages: 9000, tools: 12)))
        #expect(main.latestContext?.messageTokens == 9000)
    }

    private func modelCall(usage: [String: Any]? = nil, context: [String: Any]? = nil) throws -> AgentModelCall {
        var call: [String: Any] = ["api": "anthropicMessages", "status": 200, "streaming": true, "durationMs": 1000]
        if let usage { call["usage"] = usage }
        if let context { call["context"] = context }
        return try #require(AgentModelCall.parse(call))
    }

    private func context(messages: Int, tools: Int) -> [String: Any] {
        ["systemPromptTokens": 100, "toolTokens": tools * 100, "mcpToolTokens": 0, "messageTokens": messages,
         "toolCount": tools, "mcpToolCount": 0, "scaledToUsage": false]
    }

    @Test
    func agentReportedTokensDistinguishInclusiveAndDisjointCacheAccounting() throws {
        // The shared fixture uses disjoint buckets: total = input + output + thought + cache.
        let disjoint = try #require(AgentTurnUsage.parse(["totalTokens": 25000, "inputTokens": 18000, "outputTokens": 2000,
                                                         "thoughtTokens": 1000, "cachedReadTokens": 3000, "cachedWriteTokens": 1000]))
        // OpenAI-style accounting includes cached prompt tokens in input.
        let inclusive = try #require(AgentTurnUsage.parse(["totalTokens": 10500, "inputTokens": 10000, "outputTokens": 500,
                                                          "cachedReadTokens": 8000]))
        let separate = AgentSessionStatistics.agentTokens(disjoint)
        #expect(separate.source == .latestAgentTurn)
        #expect(separate.uncachedInputTokens == 18000)
        #expect(separate.promptTokens == 22000)
        #expect(separate.reasoningTokens == 1000)
        let included = AgentSessionStatistics.agentTokens(inclusive)
        #expect(included.uncachedInputTokens == 2000)
        #expect(included.promptTokens == 10000)
        #expect(included.cacheHitRate == 0.8)
    }

    @Test
    func reloadedSessionsContinueTheirPersistedStatisticsWithoutCountingTwice() async throws {
        let persistence = InMemoryStatisticsPersistence()
        let workspace = URL(fileURLWithPath: "/tmp/lithe-statistics-workspace")
        func store() -> AgentSessionStatisticsStore {
            AgentSessionStatisticsStore(persistence: persistence, agentID: "codex", workspaceURL: { workspace },
                                        currentDate: { Date(timeIntervalSince1970: 1_792_053_000) })
        }
        try await withStatisticsFeature { feature, connection, _ in
            feature.statisticsStore = store()
            try feature.send("First")
            try feature.receive(event("sessionCreated", ["token": connection.commands.last?["token"] as Any]))
            try feature.receive(event("toolCall"))
            try feature.receive(event("modelCall"))
            try feature.receive(event("turnFinished"))
        }
        #expect(persistence.saves == 1)
        // A new connection, as after relaunching, starts from the saved totals.
        try await withStatisticsFeature { feature, connection, _ in
            feature.statisticsStore = store()
            feature.selectSession("session-1")
            let token = try #require(connection.commands.last?["token"])
            try feature.receive(event("userMessageChunk"))
            try feature.receive(event("agentMessageChunk"))
            try feature.receive(event("sessionLoaded", ["token": token]))
            let loaded = try #require(feature.selectedConversation?.sessionStatistics)
            #expect(loaded.turnCount == 1)
            #expect(loaded.toolCallCount == 1)
            #expect(loaded.modelCalls?.callCount == 1)
            #expect(loaded.modelCalls?.averageFirstToken == 0.82)
            #expect(loaded.tokens?.source == .modelCalls)
            #expect(feature.selectedConversation?.completedTurns.isEmpty == true)

            try feature.send("Second")
            #expect(feature.selectedConversation?.sessionStatistics.turnCount == 2)
            try feature.receive(event("modelCall"))
            try feature.receive(event("turnFinished"))
            let continued = try #require(feature.selectedConversation?.sessionStatistics)
            #expect(continued.turnCount == 2)
            #expect(continued.modelCalls?.callCount == 2)
            #expect(continued.tokens?.outputTokens == 1280)
        }
        // Disconnecting re-saves nothing new, and the record holds each turn once.
        #expect(persistence.saves == 2)
        let saved = try #require(store().record(for: "session-1"))
        #expect(saved.turnCount == 2)
        #expect(saved.toolCallCount == 1)
        #expect(saved.modelCalls.callCount == 2)
    }

    @Test
    func unreadableStatisticsStartFromZeroAndTheStoreKeepsTheNewestSessions() throws {
        let persistence = InMemoryStatisticsPersistence()
        persistence.data = Data("not json".utf8)
        var date = Date(timeIntervalSince1970: 1_792_053_000)
        let store = AgentSessionStatisticsStore(persistence: persistence, agentID: "codex",
                                                workspaceURL: { URL(fileURLWithPath: "/tmp/lithe-statistics-workspace") },
                                                currentDate: { date })
        #expect(store.record(for: "session-0") == nil)
        var conversation = AgentConversation()
        store.save(conversation, sessionID: "empty")
        #expect(persistence.saves == 0, "Sessions without turns or calls are not stored")
        conversation.statisticsBaseline = AgentSessionStatisticsRecord(turnCount: 1)
        for index in 0...AgentSessionStatisticsStore.maximumSessions {
            date += 1
            store.save(conversation, sessionID: "session-\(index)")
        }
        let reopened = AgentSessionStatisticsStore(persistence: persistence, agentID: "codex",
                                                   workspaceURL: { URL(fileURLWithPath: "/tmp/lithe-statistics-workspace") })
        #expect(reopened.record(for: "session-0") == nil)
        #expect(reopened.record(for: "session-1")?.turnCount == 1)
        #expect(reopened.record(for: "session-\(AgentSessionStatisticsStore.maximumSessions)") != nil)
        // Without a bound workspace nothing is read or written.
        let unbound = AgentSessionStatisticsStore(persistence: persistence, agentID: "codex", workspaceURL: { nil })
        let saves = persistence.saves
        unbound.save(conversation, sessionID: "session-x")
        #expect(unbound.record(for: "session-1") == nil)
        #expect(persistence.saves == saves)
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

@MainActor
private final class InMemoryStatisticsPersistence: AgentSessionStatisticsPersisting {
    var data: Data?
    private(set) var saves = 0

    func loadStatistics(workspaceURL: URL, agentID: String) -> Data? { data }
    func saveStatistics(_ data: Data, workspaceURL: URL, agentID: String) {
        self.data = data
        saves += 1
    }
}
