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

    @Test
    func historyLayoutFitsNarrowAndWidePanelsInBothAppearances() async throws {
        try await HistoryFixture().run { fixture in
            let history = fixture.history
            #expect(history.setFavorite(["session-a"], true))
            for (name, scheme, width) in [("dark-narrow", ColorScheme.dark, 320.0), ("light-wide", .light, 620.0)] {
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
                    try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("history-\(name).png"))
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

    func run(_ operation: (HistoryFixture) async throws -> Void) async throws {
        do {
            try feature.connect(configuration: AgentLaunchConfiguration(
                agentID: "example", command: "example", arguments: [], workspaceURL: workspace,
                dataDirectory: URL(fileURLWithPath: "/example/data"), providerProtocol: "responses",
                providerEndpoint: "https://example.invalid", apiKey: "test", providerName: "Example",
                model: "", allowsInsecureHTTP: false
            ))
            try emit(["kind": "ready", "canListSessions": true, "canLoadSessions": true])
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
