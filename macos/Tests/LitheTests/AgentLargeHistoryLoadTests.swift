import Combine
import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

/// A replayed history is the Agent's whole transcript, one event at a time.
/// These tests pin the contract that keeps opening a very large conversation fast:
/// the replay is collected off the published state and lands in one publication.
@MainActor
struct AgentLargeHistoryLoadTests {
    @Test
    func replayingALargeHistoryPublishesOnceAndKeepsEveryMessageInOrder() throws {
        let fixture = try ReplayFixture()
        let token = try fixture.beginLoad("big")
        var publications = 0
        let observation = fixture.feature.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        let turns = 1_200
        for turn in 0..<turns {
            fixture.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "prompt \(turn)"]])
            fixture.update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "thinking "]])
            fixture.update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "\(turn)"]])
            for tool in 0..<3 {
                let id = "t\(turn)-\(tool)"
                fixture.update(["sessionUpdate": "tool_call", "toolCallId": id, "title": "Read \(tool)", "kind": "read", "status": "in_progress"])
                fixture.update(["sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed"])
            }
            fixture.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "reply \(turn)"]])
        }
        // Replay events must not publish the growing transcript one event at a time.
        #expect(publications < 20, "replay published \(publications) times")
        #expect(fixture.feature.conversations["big"]?.messages.isEmpty == true)
        #expect(fixture.feature.conversations["big"]?.isLoading == true)

        fixture.receive(["kind": "sessionLoaded", "sessionId": "big", "token": token])
        let messages = try #require(fixture.feature.conversations["big"]?.messages)
        #expect(messages.count == turns * 6)
        #expect(messages.first?.role == .user && messages.first?.text == "prompt 0")
        #expect(messages[1].role == .thought && messages[1].text == "thinking 0")
        #expect(messages[2].toolStatus == .completed, "tool updates merge into their call")
        #expect(messages.last?.text == "reply \(turns - 1)")
        #expect(fixture.feature.conversations["big"]?.isLoading == false)
        #expect(fixture.feature.conversations["big"]?.hasCompleteHistory == true)
    }

    @Test
    func aDroppedConnectionKeepsThePartialReplayWithoutMarkingItComplete() throws {
        let fixture = try ReplayFixture()
        _ = try fixture.beginLoad("partial")
        fixture.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "kept"]])
        fixture.update(["sessionUpdate": "tool_call", "toolCallId": "a", "title": "Read", "kind": "read", "status": "in_progress"])
        fixture.receive(["kind": "stopped", "message": "gone"])

        let conversation = try #require(fixture.feature.conversations["partial"])
        #expect(conversation.messages.map(\.text) == ["kept", "Read"])
        #expect(conversation.isLoading == false)
        #expect(conversation.hasCompleteHistory == false)
        #expect(conversation.messages.last?.toolStatus == .interrupted)
    }

    @Test
    func aFailedReloadRestoresTheTranscriptThatWasOpenBefore() async throws {
        let fixture = try ReplayFixture()
        let first = try fixture.beginLoad("again")
        fixture.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "original"]])
        fixture.receive(["kind": "sessionLoaded", "sessionId": "again", "token": first])
        // A new process must load the session again; a failure must bring back the old transcript.
        fixture.receive(["kind": "stopped"])
        await fixture.feature.stop()
        try fixture.connect()
        let second = try fixture.beginLoad("again")
        fixture.update(["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "half"]])
        fixture.receive(["kind": "requestFailed", "token": second, "sessionId": "again", "message": "boom"])

        let conversation = try #require(fixture.feature.conversations["again"])
        #expect(conversation.messages.map(\.text) == ["original"])
        #expect(conversation.isLoading == false)
        #expect(conversation.errorMessage == "boom")
    }

    @Test
    func theTranscriptWindowGrowsToKeepANavigationTargetVisible() {
        let messages = (0..<200).flatMap { turn in [
            AgentConversationMessage(id: "u\(turn)", role: .user, text: "prompt"),
            AgentConversationMessage(id: "a\(turn)", role: .agent, text: "reply"),
        ] }
        let items = AgentTranscriptItem.grouped(messages)
        #expect(items.count == 400)
        // The newest turn is inside the initial window; the oldest needs the whole history.
        #expect(AgentTranscriptWindow.limit(including: "u199", in: items, current: AgentTranscriptWindow.initialItems)
                == AgentTranscriptWindow.initialItems)
        #expect(AgentTranscriptWindow.limit(including: "u0", in: items, current: AgentTranscriptWindow.initialItems) >= 400)
        #expect(AgentTranscriptWindow.limit(including: "missing", in: items, current: 48) == 48)
    }

    @Test
    func historyGroupsFavoritesFirstThenByRecency() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(AgentHistoryPresentation.date("2026-10-23T15:00:00Z"))
        func session(_ id: String, _ date: String?) -> AgentSessionSummary { .init(id: id, title: id, updatedAt: date) }
        let sessions = [
            session("today", "2026-10-23T09:00:00Z"), session("yesterday", "2026-10-22T23:00:00Z"),
            session("week", "2026-10-18T12:00:00Z"), session("month", "2026-10-01T12:00:00Z"),
            session("old", "2026-01-01T12:00:00Z"), session("unknown", nil), session("pinned", "2026-10-23T10:00:00Z"),
        ]
        let metadata = ["pinned": AgentHistoryMetadata(isFavorite: true)]
        let sections = AgentHistoryPresentation.sections(sessions, metadata: metadata, groupsByDate: true, now: now, calendar: calendar)
        #expect(sections.map(\.group) == [.favorites, .today, .yesterday, .previous7Days, .previous30Days, .earlier, .unknown])
        #expect(sections.map { $0.sessions.map(\.id) } == [["pinned"], ["today"], ["yesterday"], ["week"], ["month"], ["old"], ["unknown"]])
        let flat = AgentHistoryPresentation.sections(sessions, metadata: metadata, groupsByDate: false, now: now, calendar: calendar)
        #expect(flat.count == 1 && flat[0].group == nil && flat[0].sessions.count == sessions.count)
    }
}

// Claude Code reports one rate-limit window per reply; the subscription quota
// accumulates them and stays valid until a window resets, not after two minutes.
@MainActor
struct AgentClaudeSubscriptionQuotaTests {
    @Test
    func rateLimitReportsAccumulateIntoPassiveWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHour: [String: Any] = ["status": "allowed", "rateLimitType": "five_hour", "utilization": 0.36,
                                       "resetsAt": 1_800_010_000]
        var quota = try #require(AgentSubscriptionQuota.claudeRateLimit(fiveHour, at: now))
        #expect(quota.source == .claude && quota.windows.count == 1)
        #expect(quota.windows[0].limitSeconds == 5 * 3_600)
        #expect(abs((quota.windows[0].usedPercent ?? 0) - 36) < 0.001)
        quota = try #require(quota.mergingClaudeRateLimit(
            ["rateLimitType": "seven_day", "utilization": 0.83, "resetsAt": 1_800_200_000], at: now))
        #expect(quota.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(quota.mostUsedWindow?.id == "seven_day")
        // A newer report for the same window replaces it.
        quota = try #require(quota.mergingClaudeRateLimit(
            ["rateLimitType": "five_hour", "utilization": 0.5, "resetsAt": 1_800_010_000], at: now))
        #expect(quota.windows.count == 2 && abs((quota.windows[0].usedPercent ?? 0) - 50) < 0.001)
        // Passive: an hour later is still current; after a reset it is stale.
        #expect(!quota.isStale(at: now.addingTimeInterval(3_600)))
        #expect(quota.isStale(at: Date(timeIntervalSince1970: 1_800_010_001)))
        // Overage, unknown kinds and out-of-range utilization are never guessed.
        #expect(quota.mergingClaudeRateLimit(["rateLimitType": "overage", "utilization": 0.2], at: now) == nil)
        #expect(AgentSubscriptionQuota.claudeRateLimit(["status": "allowed"], at: now) == nil)
        let invalid = try #require(AgentSubscriptionQuota.claudeRateLimit(
            ["rateLimitType": "seven_day_opus", "utilization": 7.5], at: now))
        #expect(invalid.windows[0].usedPercent == nil && invalid.windows[0].name == "Opus")
    }

    @Test
    func onlyAClaudeSubscriptionConnectionKeepsReportedQuota() throws {
        for authentication in [AgentAuthentication.claudeSubscription, .apiKey] {
            let transport = ReplayFixtureTransport()
            let panel = AgentConversationFeatureModel(transport: transport)
            panel.setAgents([.init(id: "claude-acp", name: "Claude")])
            let feature = try #require(panel.selectedConnection)
            try feature.connect(configuration: .init(agentID: "claude-acp", command: "", arguments: [],
                workspaceURL: URL(fileURLWithPath: "/example/project"), dataDirectory: URL(fileURLWithPath: "/example/agents"),
                providerProtocol: "", providerEndpoint: "", apiKey: "", providerName: "", model: "",
                allowsInsecureHTTP: false, authentication: authentication))
            func receive(_ value: [String: Any]) {
                feature.receive(String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
            }
            receive(["kind": "ready", "agentName": "Claude"])
            receive(["kind": "update", "sessionId": "s", "update": [
                "sessionUpdate": "usage_update", "used": 1_000, "size": 200_000,
                "_meta": ["_claude/rateLimit": ["rateLimitType": "five_hour", "utilization": 0.4]]]])
            #expect(feature.usesClaudeSubscription == (authentication == .claudeSubscription))
            #expect(!feature.usesSubscription, "Codex polling and account events stay off")
            #expect((feature.subscriptionQuota != nil) == (authentication == .claudeSubscription))
        }
    }
}

@MainActor
private final class ReplayFixture {
    let transport = ReplayFixtureTransport()
    let panel: AgentConversationFeatureModel
    let feature: AgentConnectionModel
    private var sessionID = ""

    init() throws {
        panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "fixture", name: "Fixture")])
        feature = panel.selectedConnection!
        try connect()
    }

    func connect() throws {
        try feature.connect(configuration: .init(agentID: "fixture", command: "", arguments: [],
            workspaceURL: URL(fileURLWithPath: "/example/project"), dataDirectory: URL(fileURLWithPath: "/example/agents"),
            providerProtocol: "responses", providerEndpoint: "https://example.invalid", apiKey: "", providerName: "Fixture",
            model: "", allowsInsecureHTTP: false))
        receive(["kind": "ready", "agentName": "Fixture", "canLoadSessions": true, "canListSessions": true])
    }

    /// Selects an unopened session, which sends `loadSession`, and returns its token.
    func beginLoad(_ id: String) throws -> String {
        sessionID = id
        let listToken = try #require(transport.connection.commands.last?["token"] as? String)
        receive(["kind": "sessions", "token": listToken, "sessions": [["sessionId": id, "title": id]]])
        feature.selectSession(id)
        let load = try #require(transport.connection.commands.last { $0["kind"] as? String == "loadSession" })
        return try #require(load["token"] as? String)
    }

    func update(_ value: [String: Any]) { receive(["kind": "update", "sessionId": sessionID, "update": value]) }

    func receive(_ value: [String: Any]) {
        feature.receive(String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}

@MainActor
private final class ReplayFixtureTransport: AgentConversationTransport {
    let connection = ReplayFixtureConnection()
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection { connection }
}

@MainActor
private final class ReplayFixtureConnection: AgentConnection {
    var commands: [[String: Any]] = []
    func send(commandJSON: String) throws {
        commands.append(try #require(JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]))
    }
    func close() async {}
}
