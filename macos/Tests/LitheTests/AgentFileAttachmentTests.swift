import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite(.serialized)
struct AgentFileAttachmentTests {
    private let first = URL(fileURLWithPath: "/example/project/中文 File.swift")
    private let second = URL(fileURLWithPath: "/example/project/README.md")

    @Test
    func menusRouteExplicitAgentAndSessionWithoutStartingProcesses() async throws {
        try await withPanel { panel, transport in
            var choices: [(String, AgentFileAttachmentDestination)] = []
            let menu = AgentFileAttachmentMenu.items(agents: panel.agents, currentAgentID: "codex-acp", currentSessionID: "codex-session",
                sessions: { _ in [.init(id: "codex-session", title: "相同标题"), .init(id: "claude-session", title: "相同标题")] }) { agent, destination in
                    choices.append((agent, destination))
                }
            #expect(transport.connections.isEmpty)
            #expect(menu[0].title.contains("Codex"))
            menu[0].action()
            guard case .submenu(let destinations) = menu[1].kind else { Issue.record("Missing Agent groups"); return }
            #expect(destinations.filter(\.isCenteredHeading).map(\.title) == ["Codex", "Claude"])
            #expect(destinations.allSatisfy { if case .submenu = $0.kind { return false }; return true },
                    "The shared context menu supports one child column; destination groups must stay flat")
            destinations[6].action()
            destinations[8].action()
            #expect(choices.map(\.0) == ["codex-acp", "claude-acp", "claude-acp"])
            #expect(choices.map(\.1) == [.session("codex-session"), .newConversation, .session("claude-session")])
            #expect(destinations[7].description != destinations[8].description)
            #expect(panel.fileAttachmentSessions(for: "claude-acp").isEmpty)
            #expect(transport.connections.isEmpty)
        }
    }
    @Test
    func agentsKeepIndependentDraftsAndAttachmentsBeforeConnection() async throws {
        try await withPanel { panel, transport in
            let codex = panel.connection(for: "codex-acp")
            codex.draftText = "Explain this code"
            try panel.attachFiles([first], agentID: "codex-acp", to: .newConversation)
            #expect(codex.draftText == "Explain this code", "A not-yet-created draft is already the new conversation")
            try panel.attachFiles([first, first], agentID: "codex-acp", to: .current)
            try panel.attachFiles([second], agentID: "claude-acp", to: .newConversation)
            #expect(panel.selectedAgentID == "claude-acp")
            #expect(panel.selectedConnection?.draftFiles.map(\.url) == [second])
            #expect(codex.draftText == "Explain this code")
            #expect(codex.draftFiles.map(\.url) == [first])
            #expect(transport.connections.isEmpty, "Adding context alone never sends or starts a process")
        }
    }

    @Test
    func sessionSwitchRestoresDraftsAndRunningTurnIsNotInterrupted() async throws {
        try await withPanel { panel, transport in
            let model = try connect(panel, transport: transport)
            let connection = try #require(transport.connections.last)
            try create(model, connection: connection, id: "first")
            try model.send("Already running")
            model.draftText = "Unsent follow-up"
            try model.attachFiles([first], to: .current)
            try model.attachFiles([second], to: .newConversation)
            try finishCreation(model, connection: connection, id: "second")
            #expect(model.draftText.isEmpty)
            #expect(model.draftFiles.map(\.url) == [second])
            let count = connection.commands.count
            try panel.attachFiles([second], agentID: "codex-acp", to: .session("first"))
            #expect(model.draftText == "Unsent follow-up")
            #expect(model.draftFiles.map(\.url) == [first, second])
            #expect(model.selectedConversation?.isResponding == true)
            #expect(connection.commands.count == count, "No prompt, steering or cancel is issued by attaching")
            model.selectSession("second")
            #expect(model.draftText.isEmpty)
            #expect(model.draftFiles.map(\.url) == [second])
            model.selectSession("first")
            #expect(model.draftText == "Unsent follow-up")
        }
    }

    @Test
    func creationAndFailedHistoryLoadKeepTheCorrectDraft() async throws {
        try await withPanel { panel, transport in
            let model = try connect(panel, transport: transport)
            let connection = try #require(transport.connections.last)
            model.prepareConversation()
            model.draftText = "Pending settings"
            try model.attachFiles([first], to: .current)
            // Select history while newSession is in flight, then deliver its result.
            model.selectSession("history")
            try finishCreation(model, connection: connection, id: "new", token: "lithe-1")
            #expect(model.selectedSessionID == "history")
            #expect(model.draftFiles.isEmpty)
            try model.attachFiles([second], to: .current)
            let load = try #require(connection.commands.last { $0["kind"] as? String == "loadSession" })
            try receive(model, ["kind": "requestFailed", "token": load["token"] as Any, "sessionId": "history", "message": "Failed replay"])
            #expect(model.draftFiles.map(\.url) == [second])
            model.selectSession("new")
            #expect(model.draftText == "Pending settings")
            #expect(model.draftFiles.map(\.url) == [first])
            #expect(connection.commands.allSatisfy { $0["kind"] as? String != "prompt" })
        }
    }

    @Test
    func invalidOrStaleTargetsDoNotChangeSelectionOrDraft() async throws {
        try await withPanel { panel, _ in
            let model = panel.connection(for: "codex-acp")
            model.draftText = "Keep this"
            try model.attachFiles([first], to: .current)
            #expect(throws: AgentFileAttachmentError.self) {
                try panel.attachFiles([second], agentID: "claude-acp", to: .session("missing"))
            }
            #expect(throws: AgentFileAttachmentError.self) {
                try panel.attachFiles([second], agentID: "removed-agent", to: .current)
            }
            #expect(throws: AgentFileReferenceError.self) {
                try panel.attachFiles([second, URL(string: "https://example.com/file")!], agentID: "claude-acp", to: .newConversation)
            }
            #expect(throws: AgentFileReferenceError.self) {
                try model.attachFiles((0...AgentFileReference.maximumCount).map {
                    URL(fileURLWithPath: "/example/project/file\($0).txt")
                }, to: .newConversation)
            }
            #expect(panel.selectedAgentID == "codex-acp")
            #expect(model.draftText == "Keep this")
            #expect(model.draftFiles.map(\.url) == [first])
            #expect(!model.isCreatingSession)
        }
    }

    @Test
    func emptySessionDraftReconnectsWithANewIDWithoutLoadingAnUnpersistedRollout() async throws {
        try await withPanel { panel, transport in
            let model = try connect(panel, transport: transport)
            try create(model, connection: try #require(transport.connections.last), id: "empty")
            model.draftText = "Not sent yet"
            try model.attachFiles([first], to: .current)
            await model.stop()
            _ = try connect(panel, transport: transport)
            let reconnected = try #require(transport.connections.last)
            model.prepareConversation()
            try finishCreation(model, connection: reconnected, id: "replacement")
            #expect(model.selectedSessionID == "replacement")
            #expect(model.draftText == "Not sent yet")
            #expect(model.draftFiles.map(\.url) == [first])
            #expect(reconnected.commands.allSatisfy { $0["kind"] as? String == "newSession" })
            #expect(!model.sessions.contains { $0.id == "empty" })
        }
    }

    @Test
    func cachedDestinationTitlesHonorRenamesAndRemovedHistory() async throws {
        try await withPanel { panel, transport in
            let model = try connect(panel, transport: transport)
            try create(model, connection: try #require(transport.connections.last), id: "existing")
            let history = panel.history(for: "codex-acp")
            #expect(history.rename("existing", title: "Renamed conversation"))
            #expect(panel.fileAttachmentSessions(for: "codex-acp").first?.title == "Renamed conversation")
            #expect(history.setHidden(["existing"], true))
            #expect(panel.fileAttachmentSessions(for: "codex-acp").isEmpty)
            #expect(throws: AgentFileAttachmentError.self) {
                try panel.attachFiles([first], agentID: "codex-acp", to: .session("existing"))
            }
            #expect(model.draftFiles.isEmpty)
        }
    }

    @Test(arguments: [ColorScheme.dark, .light])
    func nativeComposerKeepsBoundAttachmentsWhenInitialSessionArrives(scheme: ColorScheme) async throws {
        try await withPanel { panel, transport in
            let model = try connect(panel, transport: transport)
            let connection = try #require(transport.connections.last)
            let host = NSHostingView(rootView: AgentConfiguredConversationView(feature: panel, setupError: nil,
                onSelectAgent: panel.selectAgent, onConnect: {}, onOpenSettings: {}, onHide: {}, onCopySessionID: { _ in }, onOpenFile: { _ in })
                .frame(width: 480, height: 640).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            model.prepareConversation()
            try model.attachFiles([first], to: .current)
            await render(host)
            try finishCreation(model, connection: connection, id: "new")
            await render(host)
            #expect(model.draftFiles.map(\.url) == [first], "The sessionID view update must not erase routed files")
            #expect(model.composerFocusRequest == 1)
            #expect(host.fittingSize.width <= 480)
        }
    }

    @Test
    func shellStartsModuleLazilyKeepsFailedConnectionDraftAndRejectsStaleWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.swift")
        try Data("saved".utf8).write(to: url)
        let domain = "Lithe.FileAttachmentTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        // Deliberately unresolved providers fail before any CLI can start.
        settings.agentConfigurations["codex-acp"] = .init(name: "Codex", providerID: UUID())
        settings.agentConfigurations["claude-acp"] = .init(name: "Claude", providerID: UUID())
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal).services
        let model = AppModel(settings: settings, services: services)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        do {
            let identity = try #require(model.currentWorkspaceIdentity)
            try await services.moduleRuntime.setEnabled(true, for: .agentConversation)
            await model.attachFilesToAgent([url], agentID: "codex-acp", destination: .current,
                workspace: WorkspaceIdentity(url: root, generation: identity.generation - 1))
            #expect(model.agentConversationFeatureIfActive == nil)
            await model.attachFilesToAgent([url], agentID: "codex-acp", destination: .current, workspace: identity)
            let panel = try #require(model.agentConversationFeatureIfActive)
            #expect(panel.selectedConnection?.draftFiles.map(\.url) == [url])
            #expect(!panel.hasActiveConnection)
            #expect(model.workbenchFeature.isVisible(.agent))
            let codex = try #require(panel.selectedConnection)
            codex.draftText = "Preserve Codex input"
            model.showAgentChatsInEditor()
            await model.attachFilesToAgent([url], agentID: "claude-acp", destination: .newConversation, workspace: identity)
            #expect(model.isAgentEditorSelected)
            #expect(model.selectedAgentConversationID == "claude-acp")
            #expect(panel.selectedConnection?.draftFiles.map(\.url) == [url])
            #expect(codex.draftText == "Preserve Codex input")
            #expect(codex.draftFiles.map(\.url) == [url])
            #expect(try Data(contentsOf: url) == Data("saved".utf8))
        } catch { await model.shutdownProjectSession(); throw error }
        await model.shutdownProjectSession()
    }

    private func render(_ host: NSView) async {
        await withCheckedContinuation { gate in
            DispatchQueue.main.async {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                gate.resume()
            }
        }
    }

    private func withPanel(_ body: (AgentConversationFeatureModel, AttachmentTransport) async throws -> Void) async throws {
        let transport = AttachmentTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex"), .init(id: "claude-acp", name: "Claude")])
        do { try await body(panel, transport) }
        catch { await panel.stop(); throw error }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closed })
    }

    private func connect(_ panel: AgentConversationFeatureModel, transport: AttachmentTransport) throws -> AgentConnectionModel {
        let model = panel.connection(for: "codex-acp")
        try model.connect(configuration: .init(agentID: "codex-acp", command: "", arguments: [],
            workspaceURL: URL(fileURLWithPath: "/example/project"), dataDirectory: URL(fileURLWithPath: "/example/data"),
            providerProtocol: "responses", providerEndpoint: "https://example.com/v1", apiKey: "test", providerName: "Example", model: "", allowsInsecureHTTP: false))
        try receive(model, ["kind": "ready", "canLoadSessions": true])
        return model
    }

    private func create(_ model: AgentConnectionModel, connection: AttachmentConnection, id: String) throws {
        model.prepareConversation()
        try finishCreation(model, connection: connection, id: id)
    }
    private func finishCreation(_ model: AgentConnectionModel, connection: AttachmentConnection, id: String, token: String? = nil) throws {
        let command = try #require(connection.commands.last { $0["kind"] as? String == "newSession" })
        try receive(model, ["kind": "sessionCreated", "token": token ?? command["token"] as? String ?? "", "sessionId": id])
    }
    private func receive(_ model: AgentConnectionModel, _ event: [String: Any]) throws {
        model.receive(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
    }
}

@MainActor
private final class AttachmentTransport: AgentConversationTransport {
    var connections: [AttachmentConnection] = []
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        let connection = AttachmentConnection()
        connections.append(connection)
        return connection
    }
}
@MainActor
private final class AttachmentConnection: AgentConnection {
    var commands: [[String: Any]] = []
    var closed = false
    func send(commandJSON: String) throws {
        commands.append(try #require(JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]))
    }
    func close() async { closed = true }
}
