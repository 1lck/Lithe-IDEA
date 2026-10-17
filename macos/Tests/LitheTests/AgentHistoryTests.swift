import AppKit
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
struct AgentHistoryTests {
    @Test
    func missingGeneratedTitlesKeepHistoryPromptAndExportFallbacks() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/acp-events-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(fixture["events"] as? [String: Any])
        var event = try #require(events["sessionsWithoutGeneratedTitles"] as? [String: Any])
        try await HistoryFixture().run { fixture in
            fixture.feature.refreshSessions()
            event["token"] = fixture.transport.connection.commands.last?["token"]
            try fixture.emit(event)
            #expect(fixture.feature.sessions.count == 4)
            let locale = Locale(identifier: "en_US")
            for session in fixture.feature.sessions {
                #expect(session.title == nil, "Host null titles must stay absent through history merging")
                #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: nil, locale: locale)
                        == "Untitled conversation")
                var conversation = AgentConversation()
                conversation.isAttached = true
                #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: conversation, locale: locale)
                        == "New Chat")
                // A file-only first prompt still has a user-visible attachment label.
                conversation.messages = [.init(role: .user, text: "📎 /example/project/README.md")]
                #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: conversation, locale: locale)
                        == "📎 /example/project/README.md")
                #expect(AgentHistoryPresentation.popupTitle(session, metadata: .init(title: "My title"),
                                                           conversation: conversation, locale: locale) == "My title")
                let markdown = AgentHistoryDocument.markdown([.init(id: session.id, title: session.title, messages: [])])
                #expect(markdown.hasPrefix("# \(String(localized: "Untitled conversation"))\n"))
            }
        }
    }

    @Test
    func popupIncludesUnsubmittedOpenChatsAndHidesRemovedHistoryWithoutDuplicates() {
        let sessions = [AgentSessionSummary(id: "saved", title: "Saved", updatedAt: "2026-09-26T10:00:00Z"),
                        AgentSessionSummary(id: "removed", title: "Removed")]
        var hidden = AgentHistoryMetadata()
        hidden.isHidden = true
        let rows = AgentHistoryPresentation.popupSessions(sessions,
            openSessionIDs: ["saved", "removed", "new-chat"], metadata: ["removed": hidden])
        #expect(rows.map(\.id) == ["new-chat", "saved"])
        #expect(rows.first?.title == String(localized: "New Chat"))
        #expect(rows.first?.updatedAt == nil, "The UI must not invent an upstream update time")
        #expect(sessions.map(\.id) == ["saved", "removed"], "Displaying an open chat does not modify Agent-owned history")
    }

    @Test
    func managementPageRetainsUnlistedChatsAndSearchesTheirDisplayTitles() {
        let sessions = [AgentSessionSummary(id: "saved", title: "Saved upstream", updatedAt: "2026-10-16T08:00:00Z")]
        var draft = AgentConversation()
        draft.messages = [.init(id: "prompt", role: .user, text: "Draft topic")]
        let metadata = ["hidden": AgentHistoryMetadata(isHidden: true), "saved": AgentHistoryMetadata(isFavorite: true)]
        func rows(_ query: String, _ filter: AgentHistoryFilter) -> [AgentSessionSummary] {
            AgentHistoryPresentation.managementSessions(sessions, openSessionIDs: ["saved", "draft", "hidden"],
                conversations: ["draft": draft], metadata: metadata, query: query, filter: filter)
        }
        #expect(Set(rows("", .all).map(\.id)) == ["saved", "draft"])
        #expect(rows("Draft topic", .all).map(\.id) == ["draft"])
        #expect(rows("", .favorites).map(\.id) == ["saved"])
        #expect(rows("", .removed).map(\.id) == ["hidden"])
        #expect(sessions.map(\.id) == ["saved"], "The management page cannot modify Agent-owned history")
        #expect(draft.messages.first?.text == "Draft topic")
    }

    @Test
    func annotationsSurviveReloadAndStayIsolatedFromAgentTitlesAndOtherScopes() async throws {
        try await HistoryFixture().run { fixture in
            let history = fixture.history
            #expect(history.rename("session-a", title: "  Review authentication  "))
            #expect(history.setFavorite(["session-a", "session-b"], true))
            #expect(history.setHidden(["session-b"], true))
            #expect(!history.rename("session-a", title: " \n "))
            #expect(!history.setFavorite(["missing"], true))
            #expect(fixture.feature.sessions.first?.title == "Original title")

            let restored = fixture.makeHistory()
            #expect(restored.metadata["session-a"]?.title == "Review authentication")
            #expect(restored.metadata["session-a"]?.isFavorite == true)
            #expect(restored.metadata["session-b"]?.isHidden == true)
            #expect(restored.setHidden(["session-b"], false))
            #expect(restored.metadata["session-b"]?.isHidden == false)
            let otherWorkspace = try fixture.persistence.load(workspaceURL: URL(fileURLWithPath: "/example/other"), agentID: "codex")
            let otherAgent = try fixture.persistence.load(workspaceURL: fixture.workspace, agentID: "claude")
            #expect(otherWorkspace.isEmpty)
            #expect(otherAgent.isEmpty)

            // A second window's old snapshot must not erase the first window's title.
            #expect(history.rename("session-a", title: "Latest title"))
            #expect(restored.setFavorite(["session-b"], false))
            #expect(restored.metadata["session-a"]?.title == "Latest title")
        }
    }

    @Test
    func titleAndIDSearchRespectFavoritesRemovalAndTimestampOrdering() {
        let sessions = [
            AgentSessionSummary(id: "alpha", title: "Original", updatedAt: "2026-09-25T10:00:00Z"),
            AgentSessionSummary(id: "beta", title: "Fix café", updatedAt: "2026-09-26T10:00:00.123Z"),
            AgentSessionSummary(id: "removed", title: "Hidden"),
            AgentSessionSummary(id: "untitled")
        ]
        let metadata = ["alpha": AgentHistoryMetadata(title: "Renamed", isFavorite: true),
                        "removed": AgentHistoryMetadata(isHidden: true)]
        let ids = { (query: String, filter: AgentHistoryFilter) in
            AgentHistoryPresentation.sessions(sessions, metadata: metadata, query: query, filter: filter).map(\.id)
        }
        #expect(ids("  ", .all) == ["beta", "alpha", "untitled"])
        #expect(ids("CAFE", .all) == ["beta"])
        #expect(ids(" ALPHA ", .all) == ["alpha"])
        #expect(ids("Renamed", .favorites) == ["alpha"])
        #expect(ids("Original", .all).isEmpty)
        #expect(ids("Hidden", .all).isEmpty)
        #expect(ids("Hidden", .removed) == ["removed"])
        #expect(AgentHistoryPresentation.date("invalid") == nil)
        #expect(AgentHistoryPresentation.date(nil) == nil)
        #expect(AgentHistoryPresentation.date("2026-10-15T08:30:00Z") == Date(timeIntervalSince1970: 1_792_053_000))
        #expect(AgentHistoryPresentation.date("2026-10-15T08:30:00.500Z") == Date(timeIntervalSince1970: 1_792_053_000.5))
        #expect(AgentHistoryPresentation.date("2026-10-15T16:30:00+08:00") == Date(timeIntervalSince1970: 1_792_053_000))
        #expect(AgentHistoryPresentation.messageCount(nil) == nil)
        var conversation = AgentConversation()
        #expect(AgentHistoryPresentation.messageCount(conversation) == nil)
        conversation.isAttached = true
        conversation.messages = [.init(role: .user, text: "Question"), .init(role: .agent, text: "Answer"),
                                 .init(role: .tool, text: "Read file")]
        #expect(AgentHistoryPresentation.messageCount(conversation) == 2)
        conversation.isLoading = true
        #expect(AgentHistoryPresentation.messageCount(conversation) == nil)
    }

    @Test
    func refreshRejectsStaleResultsAndKeepsExistingRowsAfterFailure() async throws {
        try await HistoryFixture().run { fixture in
            fixture.feature.refreshSessions()
            let token = try #require(fixture.transport.connection.commands.last?["token"] as? String)
            let count = fixture.transport.connection.commands.count
            fixture.feature.refreshSessions()
            #expect(fixture.transport.connection.commands.count == count)
            try fixture.emit(["kind": "sessions", "token": "stale", "sessions": []])
            #expect(fixture.feature.sessions.count == 2)
            #expect(fixture.feature.isRefreshingSessions)
            try fixture.emit(["kind": "requestFailed", "token": token, "message": "History unavailable"])
            #expect(!fixture.feature.isRefreshingSessions)
            #expect(fixture.feature.historyError == "History unavailable")
            #expect(fixture.feature.sessions.count == 2)
            fixture.feature.refreshSessions()
            #expect(fixture.feature.historyError == nil)
            let retry = try #require(fixture.transport.connection.commands.last?["token"] as? String)
            try fixture.emit(["kind": "sessions", "token": retry, "sessions": []])
            #expect(fixture.feature.sessions.isEmpty)
            #expect(!fixture.feature.isRefreshingSessions)
        }
    }

    @Test
    func archivedHistoryIsListedReadOnlyAndRejectsStaleOrDuplicateRows() async throws {
        let event = try Self.fixtureEvent("archivedSessions")
        try await HistoryFixture().run(archived: true) { fixture in
            let commands = fixture.transport.connection.commands
            #expect(commands.map { $0["kind"] as? String } == ["listArchivedSessions", "listSessions"])
            let token = try #require(commands[0]["token"] as? String)
            #expect(fixture.feature.isRefreshingArchivedSessions)
            var stale = event
            stale["token"] = "stale"
            try fixture.emit(stale)
            #expect(fixture.feature.archivedSessions.isEmpty)
            var listed = event
            listed["token"] = token
            var rows = try #require(event["sessions"] as? [[String: Any]])
            // Archived while the active listing ran: shown once, as active.
            rows.append(["sessionId": "session-a", "title": "Original title", "updatedAt": NSNull()])
            listed["sessions"] = rows
            listed["complete"] = false
            try fixture.emit(listed)
            #expect(fixture.feature.archivedSessions.map(\.id) == ["archived-session-1"])
            #expect(fixture.feature.archivedSessions.first?.title == "Earlier refactor")
            #expect(!fixture.feature.isArchivedHistoryComplete)
            #expect(!fixture.feature.isRefreshingArchivedSessions)
            #expect(fixture.feature.sessions.map(\.id) == ["session-a", "session-b"])
            #expect(!fixture.transport.connection.commands.contains { $0["kind"] as? String == "unarchiveSession" })
            // Search covers archived rows with the same rules as active ones.
            let matches = AgentHistoryPresentation.sessions(fixture.feature.archivedSessions, metadata: [:],
                                                            query: "refactor", filter: .all)
            #expect(matches.map(\.id) == ["archived-session-1"])
        }
    }

    @Test(arguments: [false, true], [false, true])
    func archivingCoordinatesBothResponseOrdersAndLoadedConversations(archiveFirst: Bool, loaded: Bool) async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            // Complete the initial archive request, then archive a previously active row.
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": [], "complete": true])
            if loaded {
                fixture.transport.connection.onCommand = { [weak feature = fixture.feature] command in
                    guard command["kind"] as? String == "loadSession" else { return }
                    feature?.receive(HistoryFixture.json(["kind": "sessionLoaded", "sessionId": "session-a",
                                                         "token": command["token"] as Any]))
                }
                fixture.feature.selectSession("session-a")
                #expect(fixture.feature.conversations["session-a"]?.isAttached == true)
            }
            fixture.feature.refreshSessions()
            let requests = fixture.transport.connection.commands.suffix(2)
            let archiveToken = try #require(requests.first?["token"] as? String)
            let activeToken = try #require(requests.last?["token"] as? String)
            let archive: [String: Any] = ["kind": "archivedSessions", "token": archiveToken, "complete": true,
                                         "sessions": [["sessionId": "session-a", "title": "Archived upstream"]]]
            let active: [String: Any] = ["kind": "sessions", "token": activeToken,
                                        "sessions": [["sessionId": "session-b", "title": "Still active"]]]
            try fixture.emit(archiveFirst ? archive : active)
            try fixture.emit(archiveFirst ? active : archive)
            #expect(fixture.feature.sessions.map(\.id) == ["session-b"])
            #expect(fixture.feature.archivedSessions.map(\.id) == ["session-a"])
            #expect(fixture.feature.archivedSessions.first?.title == "Archived upstream")
            let activeRows = AgentHistoryPresentation.managementSessions(
                fixture.feature.sessions, openSessionIDs: fixture.feature.openSessionIDs,
                conversations: fixture.feature.conversations,
                archivedSessionIDs: Set(fixture.feature.archivedSessions.map(\.id)),
                metadata: fixture.history.metadata, query: "", filter: .all
            )
            #expect(activeRows.map(\.id) == ["session-b"],
                    "An open archived tab must not reappear as an active local conversation")
            if loaded {
                #expect(fixture.feature.conversations["session-a"]?.isAttached == true,
                        "History reconciliation preserves the locally opened transcript")
                #expect(fixture.feature.openSessionIDs.contains("session-a"))
            }
        }
    }

    @Test
    func removedArchivedConversationRestoresLocalVisibilityWithoutUnarchiving() async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            #expect(fixture.history.rename("session-a", title: "Local title"))
            #expect(fixture.history.setFavorite(["session-a"], true))
            #expect(fixture.history.setHidden(["session-a"], true))
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": [["sessionId": "session-a"]], "complete": true])
            fixture.feature.refreshSessions()
            try fixture.emit(["kind": "sessions", "token": fixture.transport.connection.commands.last?["token"] as Any,
                              "sessions": []])
            let restored = fixture.makeHistory()
            #expect(AgentHistoryPresentation.sessions(fixture.feature.archivedSessions, metadata: restored.metadata,
                                                     query: "", filter: .removed).map(\.id) == ["session-a"])
            let commandCount = fixture.transport.connection.commands.count
            #expect(restored.setHidden(["session-a"], false))
            #expect(fixture.makeHistory().metadata["session-a"]?.isHidden == false)
            #expect(restored.metadata["session-a"]?.title == "Local title")
            #expect(restored.metadata["session-a"]?.isFavorite == true)
            #expect(!restored.canExport(["session-a"]))
            #expect(fixture.transport.connection.commands.count == commandCount,
                    "Local restoration must not load or unarchive the Agent's conversation")
            #expect(fixture.feature.archivedSessions.map(\.id) == ["session-a"])
            #expect(AgentHistoryPresentation.sessions(fixture.feature.archivedSessions, metadata: restored.metadata,
                                                     query: "", filter: .removed).isEmpty)
            #expect(AgentHistoryPresentation.sessions(fixture.feature.archivedSessions, metadata: restored.metadata,
                                                     query: "", filter: .all).map(\.id) == ["session-a"])
        }
    }

    @Test(arguments: ["", "no matching title"])
    func emptyTruncatedArchiveNeverClaimsHistoryIsAbsent(query: String) async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": [], "complete": false])
            #expect(fixture.feature.archivedSessions.isEmpty)
            #expect(AgentHistoryPresentation.emptyState(isRefreshing: false, query: query,
                                                       isArchivedHistoryComplete: fixture.feature.isArchivedHistoryComplete) == .incomplete)
            #expect(AgentHistoryPresentation.emptyState(isRefreshing: false, query: query,
                                                       isArchivedHistoryComplete: true) == (query.isEmpty ? .noHistory : .noMatches))
        }
    }

    @Test
    func unarchivingMovesOnlyTheConfirmedConversationIntoActiveHistory() async throws {
        let event = try Self.fixtureEvent("archivedSessions")
        try await HistoryFixture().run(archived: true) { fixture in
            var listed = event
            listed["token"] = fixture.transport.connection.commands[0]["token"]
            try fixture.emit(listed)
            fixture.transport.connection.onCommand = { command in
                guard command["kind"] as? String == "unarchiveSession" else { return }
                try? fixture.emit(["kind": "requestFailed", "token": command["token"] as Any,
                                   "sessionId": command["sessionId"] as Any,
                                   "message": "Codex could not restore this archived conversation."])
            }
            await #expect(throws: AgentConversationError.self) {
                try await fixture.feature.unarchiveSession("archived-session-1")
            }
            #expect(fixture.feature.archivedSessions.map(\.id) == ["archived-session-1"])
            #expect(fixture.feature.archivedHistoryError != nil)
            #expect(fixture.feature.unarchivingSessionID == nil)

            fixture.transport.connection.onCommand = { command in
                guard command["kind"] as? String == "unarchiveSession" else { return }
                #expect(command["sessionId"] as? String == "archived-session-1")
                try? fixture.emit(["kind": "sessionUnarchived", "token": command["token"] as Any,
                                   "sessionId": "archived-session-1"])
            }
            try await fixture.feature.unarchiveSession("archived-session-1")
            #expect(fixture.feature.archivedSessions.isEmpty)
            #expect(fixture.feature.sessions.first?.id == "archived-session-1")
            #expect(fixture.feature.archivedHistoryError == nil)
            await #expect(throws: AgentConversationError.cannotResume) {
                try await fixture.feature.unarchiveSession("unknown")
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func unarchivingRejectsPreRestoreListsInEitherResponseOrder(archiveFirst: Bool, beforeReturn: Bool) async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            let archived: [[String: Any]] = [["sessionId": "restore-me", "title": "Restore this conversation"],
                                             ["sessionId": "still-archived", "title": "Leave archived"]]
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": archived, "complete": true])
            // Hold both pre-restore list responses while the upstream mutation completes.
            fixture.feature.refreshSessions()
            let oldRequests = Array(fixture.transport.connection.commands.suffix(2))
            let oldArchiveToken = try #require(oldRequests.first?["token"] as? String)
            let oldActiveToken = try #require(oldRequests.last?["token"] as? String)
            let oldArchive: [String: Any] = ["kind": "archivedSessions", "token": oldArchiveToken,
                                              "sessions": archived, "complete": false]
            let oldActive: [String: Any] = ["kind": "sessions", "token": oldActiveToken,
                                             "sessions": [["sessionId": "session-a"], ["sessionId": "session-b"]]]
            let releaseOldResponses = {
                fixture.feature.receive(HistoryFixture.json(archiveFirst ? oldArchive : oldActive))
                fixture.feature.receive(HistoryFixture.json(archiveFirst ? oldActive : oldArchive))
            }
            defer { fixture.transport.connection.onCommand = nil }
            fixture.transport.connection.onCommand = { command in
                switch command["kind"] as? String {
                case "unarchiveSession":
                    fixture.feature.receive(HistoryFixture.json(["kind": "sessionUnarchived",
                        "token": command["token"] as Any, "sessionId": "restore-me"]))
                    // Also exercise buffered events arriving before the continuation resumes.
                    if beforeReturn { releaseOldResponses() }
                case "loadSession":
                    fixture.feature.receive(HistoryFixture.json(["kind": "update", "sessionId": "restore-me",
                        "update": ["sessionUpdate": "user_message_chunk",
                                   "content": ["type": "text", "text": "Restored transcript"]]]))
                    fixture.feature.receive(HistoryFixture.json(["kind": "sessionLoaded", "sessionId": "restore-me",
                                                                  "token": command["token"] as Any]))
                default: break
                }
            }
            try await fixture.feature.unarchiveSession("restore-me")
            if !beforeReturn { releaseOldResponses() }
            #expect(fixture.feature.sessions.map(\.id) == ["restore-me", "session-a", "session-b"])
            #expect(fixture.feature.archivedSessions.map(\.id) == ["still-archived"])
            #expect(fixture.feature.isArchivedHistoryComplete)
            #expect(fixture.feature.isRefreshingSessions && fixture.feature.isRefreshingArchivedSessions,
                    "Old responses must not finish the replacement refresh")
            let newRequests = Array(fixture.transport.connection.commands.suffix(2))
            #expect(newRequests.first?["kind"] as? String == "listArchivedSessions")
            #expect(newRequests.last?["kind"] as? String == "listSessions")
            let newArchiveToken = try #require(newRequests.first?["token"] as? String)
            let newActiveToken = try #require(newRequests.last?["token"] as? String)
            #expect(newArchiveToken != oldArchiveToken && newActiveToken != oldActiveToken)

            fixture.feature.selectSession("restore-me")
            #expect(fixture.feature.selectedSessionID == "restore-me")
            #expect(fixture.feature.conversations["restore-me"]?.messages.map(\.text) == ["Restored transcript"])
            #expect(fixture.feature.conversations["restore-me"]?.hasCompleteHistory == true)
            #expect(fixture.feature.conversations["restore-me"]?.isLoading == false)
            try fixture.emit(["kind": "archivedSessions", "token": newArchiveToken,
                              "sessions": [["sessionId": "still-archived"]], "complete": false])
            try fixture.emit(["kind": "sessions", "token": newActiveToken,
                              "sessions": [["sessionId": "restore-me"], ["sessionId": "session-a"], ["sessionId": "session-b"]]])
            #expect(fixture.feature.sessions.map(\.id) == ["restore-me", "session-a", "session-b"])
            #expect(fixture.feature.archivedSessions.map(\.id) == ["still-archived"])
            #expect(!fixture.feature.isArchivedHistoryComplete, "The replacement archive response remains authoritative")
            #expect(!fixture.feature.isRefreshingSessions && !fixture.feature.isRefreshingArchivedSessions)
            #expect(fixture.feature.conversations["restore-me"]?.isAttached == true)
            #expect(fixture.feature.conversations["restore-me"]?.messages.map(\.text) == ["Restored transcript"])
        }
    }

    @Test
    func unarchivingDiscardsLateFailuresOfSupersededListRequests() async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": [["sessionId": "restore-me"]], "complete": true])
            // Event order: refresh starts, unarchive succeeds, replacement refresh
            // starts, then the host answers both obsolete requests with failures.
            fixture.feature.refreshSessions()
            let oldTokens = fixture.transport.connection.commands.suffix(2).compactMap { $0["token"] as? String }
            #expect(oldTokens.count == 2)
            defer { fixture.transport.connection.onCommand = nil }
            fixture.transport.connection.onCommand = { command in
                guard command["kind"] as? String == "unarchiveSession" else { return }
                fixture.feature.receive(HistoryFixture.json(["kind": "sessionUnarchived",
                    "token": command["token"] as Any, "sessionId": "restore-me"]))
            }
            try await fixture.feature.unarchiveSession("restore-me")
            let newTokens = fixture.transport.connection.commands.suffix(2).compactMap { $0["token"] as? String }
            for token in oldTokens {
                try fixture.emit(["kind": "requestFailed", "token": token, "message": "Obsolete list request failed."])
            }
            #expect(fixture.feature.errorMessage == nil, "An obsolete query must not surface as a conversation error")
            #expect(fixture.feature.historyError == nil && fixture.feature.archivedHistoryError == nil)
            #expect(fixture.feature.isRefreshingSessions && fixture.feature.isRefreshingArchivedSessions)

            // The replacement requests still report their own failures.
            for token in newTokens {
                try fixture.emit(["kind": "requestFailed", "token": token, "message": "Replacement failed."])
            }
            #expect(fixture.feature.historyError == "Replacement failed.")
            #expect(fixture.feature.archivedHistoryError == "Replacement failed.")
            #expect(fixture.feature.errorMessage == nil)
        }
    }

    @Test(arguments: [false, true])
    func unarchivingDoesNotNavigateOverALaterSelection(selectsDuringRestore: Bool) async throws {
        try await HistoryFixture().run(archived: true) { fixture in
            try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                              "sessions": [["sessionId": "restore-me"]], "complete": true])
            defer { fixture.transport.connection.onCommand = nil }
            fixture.transport.connection.onCommand = { command in
                guard command["kind"] as? String == "unarchiveSession" else { return }
                // The user opens another conversation before the restore returns.
                if selectsDuringRestore { fixture.feature.selectSession("session-b") }
                fixture.feature.receive(HistoryFixture.json(["kind": "sessionUnarchived",
                    "token": command["token"] as Any, "sessionId": "restore-me"]))
            }
            let selectionBeforeRestore = fixture.feature.selectedSessionID
            let canOpen = try await fixture.feature.unarchiveSession("restore-me")
            #expect(canOpen == !selectsDuringRestore)
            #expect(fixture.feature.archivedSessions.isEmpty, "The confirmed restore completes either way")
            #expect(fixture.feature.selectedSessionID == (selectsDuringRestore ? "session-b" : selectionBeforeRestore))
        }
    }

    @Test
    func archivedHistoryNeverOutlivesItsConnectionOrAppearsForOtherAgents() async throws {
        let event = try Self.fixtureEvent("archivedSessions")
        try await HistoryFixture().run(archived: true) { fixture in
            var listed = event
            listed["token"] = fixture.transport.connection.commands[0]["token"]
            try fixture.emit(listed)
            #expect(!fixture.feature.archivedSessions.isEmpty)
            await fixture.feature.stop()
            #expect(fixture.feature.archivedSessions.isEmpty)
            #expect(!fixture.feature.canListArchivedSessions)
            try fixture.emit(listed)
            #expect(fixture.feature.archivedSessions.isEmpty)
        }
        try await HistoryFixture().run { fixture in
            #expect(!fixture.feature.canListArchivedSessions)
            #expect(!fixture.transport.connection.commands.contains { $0["kind"] as? String == "listArchivedSessions" })
        }
    }

    private static func fixtureEvent(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/agent/acp-events-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try #require(fixture["events"] as? [String: Any])
        return try #require(events[name] as? [String: Any])
    }

    @Test
    func batchExportReplaysUnopenedHistoryWithoutChangingSelection() async throws {
        try await HistoryFixture().run { fixture in
            let feature = fixture.feature
            fixture.transport.connection.onCommand = { [weak feature] command in
                guard command["kind"] as? String == "loadSession", let feature,
                      let id = command["sessionId"] as? String else { return }
                feature.receive(HistoryFixture.json(["kind": "update", "sessionId": id,
                    "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Question \(id)"]]]))
                feature.receive(HistoryFixture.json(["kind": "update", "sessionId": id,
                    "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Answer \(id)"]]]))
                feature.receive(HistoryFixture.json(["kind": "sessionLoaded", "sessionId": id, "token": command["token"] as Any]))
            }
            fixture.history.export(["session-a", "session-b"])
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.history.errorMessage == nil)
            let markdown = try #require(fixture.exporter.markdown)
            #expect(markdown.contains("Question session-a"))
            #expect(markdown.contains("Answer session-b"))
            #expect(feature.selectedSessionID == nil)
            #expect(feature.openSessionIDs.isEmpty)
            #expect(fixture.transport.connection.commands.filter { $0["kind"] as? String == "loadSession" }.count == 2)
        }
    }

    @Test
    func cancellingExportReleasesItsReplayWaiterAndNeverWritesPartialHistory() async throws {
        try await HistoryFixture().run { fixture in
            let loadStarted = TestGate()
            fixture.transport.connection.onCommand = { command in
                if command["kind"] as? String == "loadSession" { loadStarted.open() }
            }
            fixture.history.export(["session-a"])
            #expect(await loadStarted.waitUntilOpen(), "Export must reach the replay boundary")
            fixture.history.cancelExport()
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.exporter.markdown == nil)
            #expect(fixture.history.errorMessage == nil)
        }
    }

    @Test
    func exportFailureAndSaveCancellationLeaveHistoryIntact() async throws {
        try await HistoryFixture().run { fixture in
            fixture.exporter.destination = nil
            fixture.history.export(["session-a"])
            #expect(!fixture.history.isExporting)
            #expect(fixture.transport.connection.commands.count == 1)
            fixture.exporter.destination = URL(fileURLWithPath: "/example/export.md")
            let feature = fixture.feature
            fixture.transport.connection.onCommand = { [weak feature] command in
                if command["kind"] as? String == "loadSession" {
                    feature?.receive(HistoryFixture.json(["kind": "requestFailed", "token": command["token"] as Any,
                        "sessionId": "session-a", "message": "Replay failed"]))
                }
            }
            fixture.history.export(["session-a"])
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.history.errorMessage == "Replay failed")
            #expect(fixture.exporter.markdown == nil)
            #expect(fixture.feature.sessions.count == 2)
        }
    }

    @Test
    func retryAfterPartialReplayFailureLoadsCompleteHistoryBeforeExporting() async throws {
        try await HistoryFixture().run { fixture in
            let feature = fixture.feature
            fixture.transport.connection.onCommand = { [weak feature] command in
                guard command["kind"] as? String == "loadSession", let feature else { return }
                feature.receive(HistoryFixture.json(["kind": "update", "sessionId": "session-a",
                    "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Partial replay"]]]))
                feature.receive(HistoryFixture.json(["kind": "requestFailed", "token": command["token"] as Any,
                    "sessionId": "session-a", "message": "Replay failed"]))
            }
            fixture.history.export(["session-a"])
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.history.errorMessage == "Replay failed")
            #expect(fixture.exporter.markdown == nil)

            // Hold the retry after its first chunk; exporting must wait for sessionLoaded.
            let retryStarted = TestGate()
            defer { retryStarted.open() }
            fixture.transport.connection.onCommand = { [weak feature] command in
                guard command["kind"] as? String == "loadSession", let feature else { return }
                feature.receive(HistoryFixture.json(["kind": "update", "sessionId": "session-a",
                    "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Complete question"]]]))
                retryStarted.open()
            }
            fixture.history.export(["session-a"])
            #expect(await retryStarted.waitUntilOpen(), "Retry must request a fresh replay")
            #expect(fixture.history.isExporting)
            #expect(fixture.exporter.markdown == nil)
            let token = try #require(fixture.transport.connection.commands.last?["token"] as? String)
            try fixture.emit(["kind": "update", "sessionId": "session-a",
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Complete answer"]]])
            try fixture.emit(["kind": "sessionLoaded", "sessionId": "session-a", "token": token])
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            let markdown = try #require(fixture.exporter.markdown)
            #expect(markdown.contains("Complete question"))
            #expect(markdown.contains("Complete answer"))
            #expect(!markdown.contains("Partial replay"))
            #expect(fixture.history.errorMessage == nil)
            #expect(fixture.transport.connection.commands.filter { $0["kind"] as? String == "loadSession" }.count == 2)

            await feature.stop()
            #expect(feature.canExportTranscript("session-a"), "Disconnecting preserves a completed snapshot")
            let disconnectedTranscript = try await feature.historyTranscript("session-a")
            #expect(disconnectedTranscript.map(\.text) == ["Complete question", "Complete answer"])
        }
    }

    @Test
    func disconnectDuringPartialReplayDoesNotMakeItExportable() async throws {
        try await HistoryFixture().run { fixture in
            let started = TestGate()
            defer { started.open() }
            let feature = fixture.feature
            fixture.transport.connection.onCommand = { [weak feature] command in
                guard command["kind"] as? String == "loadSession", let feature else { return }
                feature.receive(HistoryFixture.json(["kind": "update", "sessionId": "session-a",
                    "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "Partial replay"]]]))
                started.open()
            }
            fixture.history.export(["session-a"])
            #expect(await started.waitUntilOpen())
            await feature.stop()
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.exporter.markdown == nil)
            #expect(!feature.canExportTranscript("session-a"))
        }
    }

    @Test
    func failedMetadataSaveAndExporterWriteDoNotReportSuccess() async throws {
        try await HistoryFixture().run { fixture in
            let persistence = FailingHistoryPersistence()
            let history = AgentHistoryFeatureModel(connection: fixture.feature, workspaceURL: fixture.workspace,
                agentID: "example", persistence: persistence, exporter: fixture.exporter)
            #expect(history.setFavorite(["session-a"], true))
            persistence.fails = true
            #expect(!history.rename("session-a", title: "Unsaved"))
            #expect(history.metadata["session-a"]?.title == nil)
            #expect(history.metadata["session-a"]?.isFavorite == true)
            #expect(history.errorMessage != nil)
            #expect(!history.canExport(["unknown"]))

            fixture.feature.selectSession("session-a")
            let token = try #require(fixture.transport.connection.commands.last?["token"] as? String)
            try fixture.emit(["kind": "sessionLoaded", "sessionId": "session-a", "token": token])
            fixture.exporter.fails = true
            history.export(["session-a"])
            #expect(await awaitChange(on: history, until: { !history.isExporting }))
            #expect(history.errorMessage != nil)
            #expect(fixture.exporter.markdown == nil)
            #expect(fixture.feature.selectedSessionID == "session-a")
        }
    }

    @Test
    func stoppingDuringExportReleasesWaiterWithoutWritingOrPublishingCancellationAsAnError() async throws {
        try await HistoryFixture().run { fixture in
            let started = TestGate()
            fixture.transport.connection.onCommand = { command in
                if command["kind"] as? String == "loadSession" { started.open() }
            }
            fixture.history.export(["session-a"])
            #expect(await started.waitUntilOpen())
            fixture.history.cancelExport()
            await fixture.feature.stop()
            #expect(await awaitChange(on: fixture.history, until: { !fixture.history.isExporting }))
            #expect(fixture.history.errorMessage == nil)
            #expect(fixture.exporter.markdown == nil)
        }
    }

    @Test
    func nativeExporterRejectsBundleDestinations() async {
        let exporter = MacAgentHistoryExporter(storage: UnavailableFileStorage())
        do {
            try await exporter.writeMarkdown("Example", to: URL(fileURLWithPath: "/example/Lithe.app/Contents/Resources/export.md"))
            Issue.record("Export must never write to an installed app bundle")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        }
    }

    @Test
    func runtimeCreatedBeforeProjectOpeningBindsHistoryToTheActualWorkspace() throws {
        let persistence = MacAgentHistoryPersistence(store: HistoryKeyValueStore())
        let workspace = URL(fileURLWithPath: "/example/project")
        try persistence.save(["saved": AgentHistoryMetadata(title: "Persisted title", isFavorite: true)],
                             workspaceURL: workspace, agentID: "codex")
        let feature = AgentConversationFeatureModel(transport: HistoryTransport(), historyPersistence: persistence)
        feature.bindWorkspace(workspace)
        let history = feature.history(for: "codex")
        #expect(history.metadata["saved"]?.title == "Persisted title")
        #expect(history.metadata["saved"]?.isFavorite == true)
        #expect(feature.history(for: "claude").metadata.isEmpty)
    }

    @Test(arguments: [false, true])
    func historyLayoutFitsNarrowAndWidePanelsInBothAppearances(truncated: Bool) async throws {
        try await HistoryFixture().run(archived: truncated) { fixture in
            let history = fixture.history
            #expect(history.setFavorite(["session-a"], true))
            if truncated {
                try fixture.emit(["kind": "archivedSessions", "token": fixture.transport.connection.commands[0]["token"] as Any,
                                  "sessions": [], "complete": false])
                fixture.feature.refreshSessions()
                let requests = fixture.transport.connection.commands.suffix(2)
                try fixture.emit(["kind": "archivedSessions", "token": requests.first?["token"] as Any,
                                  "sessions": [], "complete": false])
                try fixture.emit(["kind": "sessions", "token": requests.last?["token"] as Any, "sessions": []])
                #expect(fixture.feature.sessions.isEmpty && fixture.feature.archivedSessions.isEmpty)
                #expect(!fixture.feature.isRefreshingSessions && !fixture.feature.isRefreshingArchivedSessions)
            }
            for (name, scheme, width) in [("dark-narrow", ColorScheme.dark, 320.0), ("light-narrow", .light, 320.0),
                                          ("dark-wide", .dark, 620.0), ("light-wide", .light, 620.0)] {
                let host = NSHostingView(rootView: AgentHistoryView(
                    feature: fixture.feature, history: history, agentName: "Codex", onBack: {},
                    onCopySessionID: { _ in }, onSelect: { _ in }, onReconnect: {}
                ).environment(\.colorScheme, scheme))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = host
                host.frame.size = NSSize(width: width, height: 600)
                host.layoutSubtreeIfNeeded()
                // ViewThatFits has the wide row's ideal width even when its compact
                // candidate is rendered. Check the actual native search field instead.
                let field = try #require(textField(in: host))
                let fieldFrame = field.convert(field.bounds, to: host)
                #expect(fieldFrame.minX >= 0 && fieldFrame.maxX <= width)
                #expect(fieldFrame.width >= 120)
                // Optional visual evidence uses only synthetic sessions, never user conversations.
                if let folder = ProcessInfo.processInfo.environment["LITHE_AGENT_HISTORY_SCREENSHOTS"],
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("history-\(truncated ? "truncated-" : "")\(name).png"))
                }
            }
        }
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}

@MainActor
private final class HistoryFixture {
    let feature: AgentConnectionModel
    let transport = HistoryTransport()
    let persistence = MacAgentHistoryPersistence(store: HistoryKeyValueStore())
    let exporter = HistoryExporter()
    let workspace = URL(fileURLWithPath: "/example/project")
    lazy var history = makeHistory()

    init() { feature = AgentConnectionModel(transport: transport) }

    func makeHistory() -> AgentHistoryFeatureModel {
        AgentHistoryFeatureModel(connection: feature, workspaceURL: workspace, agentID: "codex",
                                 persistence: persistence, exporter: exporter)
    }

    func run(archived: Bool = false, _ operation: (HistoryFixture) async throws -> Void) async throws {
        do {
            try feature.connect(configuration: AgentLaunchConfiguration(
                agentID: "example", command: "example", arguments: [], workspaceURL: workspace,
                dataDirectory: URL(fileURLWithPath: "/example/data"), providerProtocol: "responses",
                providerEndpoint: "https://example.invalid", apiKey: "test", providerName: "Example",
                model: "", allowsInsecureHTTP: false
            ))
            try emit(["kind": "ready", "canListSessions": true, "canLoadSessions": true, "canListArchivedSessions": archived])
            try emit(["kind": "sessions", "token": transport.connection.commands.last?["token"] as Any,
                "sessions": [["sessionId": "session-a", "title": "Original title", "updatedAt": "2026-09-26T10:00:00Z"],
                             ["sessionId": "session-b", "title": "Another conversation", "updatedAt": "2026-09-25T10:00:00Z"]]])
            try await operation(self)
        } catch {
            history.cancelExport()
            await feature.stop()
            await history.stop()
            throw error
        }
        history.cancelExport()
        await feature.stop()
        await history.stop()
    }

    func emit(_ event: [String: Any]) throws { feature.receive(Self.json(event)) }
    static func json(_ event: [String: Any]) -> String {
        // All callers supply fixed JSON-compatible fake events.
        String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }
}

@MainActor
private final class HistoryTransport: AgentConversationTransport {
    let connection = HistoryConnection()
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        connection
    }
}

@MainActor
private final class HistoryConnection: AgentConnection {
    var commands: [[String: Any]] = []
    var onCommand: (([String: Any]) -> Void)?
    func send(commandJSON: String) throws {
        let command = try #require(JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any])
        commands.append(command)
        onCommand?(command)
    }
    func close() async {}
}

@MainActor
private final class HistoryExporter: AgentHistoryExporting {
    var destination: URL? = URL(fileURLWithPath: "/example/export.md")
    var markdown: String?
    var fails = false
    func chooseDestination() -> URL? { destination }
    func writeMarkdown(_ markdown: String, to url: URL) async throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        self.markdown = markdown
    }
}

@MainActor
private final class FailingHistoryPersistence: AgentHistoryPersisting {
    var fails = false
    private var metadata: [String: AgentHistoryMetadata] = [:]
    func load(workspaceURL: URL, agentID: String) throws -> [String: AgentHistoryMetadata] { metadata }
    func save(_ metadata: [String: AgentHistoryMetadata], workspaceURL: URL, agentID: String) throws {
        if fails { throw CocoaError(.fileWriteNoPermission) }
        self.metadata = metadata
    }
}

private final class HistoryKeyValueStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
