import AppKit
import SwiftUI
import Testing
import LitheCoreContracts
@testable import Lithe
@testable import LitheAgentConversationModule

@MainActor
@Suite(.serialized)
struct AgentConversationSelectionTests {
    @Test
    func preparingSessionSettingsHidesSavedModelsUntilTheSessionConfirms() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        func agents(_ model: String) -> [AgentOption] {
            [.init(id: "claude-acp", name: "Claude"), .init(id: "codex-acp", name: "Codex", modelName: model)]
        }
        panel.setAgents(agents("Saved model"))
        do {
            _ = try prepare(panel, transport: transport, agentID: "claude-acp", model: "Claude model")
            let host = hostingView(panel)
            let window = hiddenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let claudeToolbar = try toolbarPixels(in: host)

            // Hold each ACP boundary explicitly: first selection, process ready,
            // pending session (including default repair), then the confirmed catalog.
            panel.selectAgent("codex-acp")
            host.layoutSubtreeIfNeeded()
            let loadingToolbar = try toolbarPixels(in: host)
            #expect(loadingToolbar != claudeToolbar)
            panel.setAgents(agents("Another saved model"))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar, "Unconfirmed saved models must not flash")

            let codex = panel.connection(for: "codex-acp")
            try connect(codex, agentID: "codex-acp")
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar)
            codex.receive(try json(["kind": "ready", "agentName": "Codex", "canLoadSessions": true]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar, "Process readiness does not confirm session settings")
            codex.prepareConversation()
            let token = try #require(transport.connections.last?.commands.last?["token"])
            codex.receive(try json(["kind": "sessionCreated", "sessionId": "codex-session", "token": "stale",
                                   "configOptions": options(model: "Wrong model", current: "default")]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar)
            codex.receive(try json(["kind": "sessionCreated", "sessionId": "codex-session", "token": token,
                                   "configOptions": options(model: "Confirmed model", current: "default")]))
            host.layoutSubtreeIfNeeded()
            let confirmedToolbar = try toolbarPixels(in: host)
            #expect(confirmedToolbar != loadingToolbar)
            #expect(codex.selectedConversation?.configOptions.first?.currentLabel == "Confirmed model")
            panel.setAgents(agents("Saved model"))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == confirmedToolbar, "Confirmed choices remain authoritative")

            panel.selectAgent("claude-acp")
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == claudeToolbar)
            panel.selectAgent("codex-acp")
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == confirmedToolbar, "Prepared connections do not reload on every switch")
            #expect(transport.connections.count == 2)

            codex.selectSession("history-session")
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar, "History waits for its own settings")
            codex.receive(try json(["kind": "sessionLoaded", "sessionId": "history-session",
                                   "token": transport.connections.last?.commands.last?["token"] as Any,
                                   "configOptions": options(model: "History model", current: "default")]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) != loadingToolbar)
            #expect(codex.selectedConversation?.configOptions.first?.currentLabel == "History model")
        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test
    func failedOrUnsupportedSettingsStopLoadingAndKeepTheConfiguredFallback() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        func agents(_ model: String) -> [AgentOption] {
            [.init(id: "codex-acp", name: "Codex", modelName: model)]
        }
        panel.setAgents(agents("Saved model"))
        do {
            let codex = panel.connection(for: "codex-acp")
            let host = hostingView(panel)
            let window = hiddenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let loadingToolbar = try toolbarPixels(in: host)

            codex.reportConnectionFailure("Missing API key")
            host.layoutSubtreeIfNeeded()
            let fallbackToolbar = try toolbarPixels(in: host)
            #expect(fallbackToolbar != loadingToolbar, "Connection failures must not keep showing loading")
            panel.setAgents(agents("Another saved model"))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) != fallbackToolbar, "Failed setup still shows the configured model")
            panel.setAgents(agents("Saved model"))

            try connect(codex, agentID: "codex-acp")
            codex.receive(try json(["kind": "ready", "agentName": "Codex", "canLoadSessions": true]))
            host.layoutSubtreeIfNeeded()
            codex.prepareConversation()
            codex.receive(try json(["kind": "requestFailed", "message": "Session failed",
                                   "token": transport.connections.last?.commands.last?["token"] as Any]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == fallbackToolbar, "Creation failures stop waiting")
            #expect(codex.errorMessage == "Session failed")

            codex.prepareConversation()
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar)
            codex.receive(try json(["kind": "sessionCreated", "sessionId": "no-settings",
                                   "token": transport.connections.last?.commands.last?["token"] as Any]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == fallbackToolbar, "An adapter without config options is ready, not loading")
            #expect(codex.selectedConversation?.isAttached == true)
            #expect(codex.selectedConversation?.configOptions.isEmpty == true)

            codex.selectSession("history-session")
            codex.receive(try json(["kind": "requestFailed", "message": "History failed",
                                   "token": transport.connections.last?.commands.last?["token"] as Any]))
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == fallbackToolbar, "History failures stop waiting")
            #expect(codex.selectedConversation?.errorMessage == "History failed")
        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test
    func selectedAgentAndConfirmedModelRefreshWithoutReplacingTheRootView() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex"), .init(id: "claude-acp", name: "Claude")])
        do {
            let codex = try prepare(panel, transport: transport, agentID: "codex-acp", model: "Codex model")
            let claude = try prepare(panel, transport: transport, agentID: "claude-acp", model: "Claude model")
            let host = NSHostingView(rootView: AgentConfiguredConversationView(
                feature: panel, setupError: nil, onSelectAgent: panel.selectAgent,
                onConnect: {}, onOpenSettings: {}, onCopySessionID: { _ in }, onOpenFile: { _ in }
            ))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let codexToolbar = try toolbarPixels(in: host)

            // Only the module selection changes: no AppModel notification or
            // rootView replacement may be needed to render the new connection.
            panel.selectAgent("claude-acp")
            host.layoutSubtreeIfNeeded()
            let claudeToolbar = try toolbarPixels(in: host)
            #expect(claudeToolbar != codexToolbar, "The native toolbar must render Claude and its model")
            #expect(panel.selectedConnection === claude)
            #expect(claude.selectedConversation?.configOptions.first?.currentLabel == "Claude model")

            claude.setConfigOption("model", value: "alternate")
            let command = try #require(transport.connections[1].commands.last)
            #expect(command["kind"] as? String == "setConfigOption")
            #expect(claude.selectedConversation?.configOptions.first?.currentLabel == "Claude model")
            claude.receive(try json(["kind": "sessionConfigured", "sessionId": "claude-acp",
                                     "token": command["token"] as Any,
                                     "configOptions": options(model: "Claude model", current: "alternate")]))
            host.layoutSubtreeIfNeeded()
            let alternateToolbar = try toolbarPixels(in: host)
            #expect(alternateToolbar != claudeToolbar, "Confirmed model changes must render in the native toolbar")
            #expect(claude.selectedConversation?.configOptions.first?.currentLabel == "Alternate model")

            panel.selectAgent("codex-acp")
            host.layoutSubtreeIfNeeded()
            #expect(panel.selectedConnection === codex)
            #expect(try toolbarPixels(in: host) == codexToolbar)
            panel.selectAgent("claude-acp")
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == alternateToolbar)
            #expect(transport.connections.count == 2, "Switching reuses the project connections")

            panel.setAgents([.init(id: "codex-acp", name: "Codex")])
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == codexToolbar)
        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    private func prepare(_ panel: AgentConversationFeatureModel, transport: SelectionTransport,
                         agentID: String, model: String) throws -> AgentConnectionModel {
        let connection = panel.connection(for: agentID)
        try connect(connection, agentID: agentID)
        connection.receive(try json(["kind": "ready", "agentName": agentID, "canLoadSessions": true]))
        connection.prepareConversation()
        let native = try #require(transport.connections.last)
        connection.receive(try json(["kind": "sessionCreated", "sessionId": agentID,
                                     "token": native.commands.last?["token"] as Any,
                                     "configOptions": options(model: model, current: "default")]))
        return connection
    }

    private func connect(_ connection: AgentConnectionModel, agentID: String) throws {
        try connection.connect(configuration: .init(
            agentID: agentID, command: "", arguments: [], workspaceURL: URL(fileURLWithPath: "/example/project"),
            dataDirectory: URL(fileURLWithPath: "/example/agents"), providerProtocol: "responses",
            providerEndpoint: "https://gateway.example.com/v1", apiKey: "test-key", providerName: "Example",
            model: "", allowsInsecureHTTP: false
        ))
    }

    private func hostingView(_ panel: AgentConversationFeatureModel) -> NSHostingView<AgentConfiguredConversationView> {
        NSHostingView(rootView: AgentConfiguredConversationView(
            feature: panel, setupError: nil, onSelectAgent: panel.selectAgent,
            onConnect: {}, onOpenSettings: {}, onCopySessionID: { _ in }, onOpenFile: { _ in }
        ))
    }

    private func hiddenWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func options(model: String, current: String) -> [[String: Any]] {
        [["id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": current,
          "options": [["value": "default", "name": model], ["value": "alternate", "name": "Alternate model"]]]]
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func toolbarPixels(in view: NSView) throws -> Data {
        // Capture only the static bottom toolbar; text-field caret blinking and
        // the transcript are outside the comparison. No image files are written.
        let region = NSRect(x: 16, y: view.isFlipped ? view.bounds.height - 44 : 8,
                            width: view.bounds.width - 32, height: 32)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}

@MainActor
private final class SelectionTransport: AgentConversationTransport {
    var connections: [SelectionConnection] = []
    func open(configuration: AgentLaunchConfiguration, onEvent: @escaping @Sendable (String) -> Void) throws -> any AgentConnection {
        let connection = SelectionConnection()
        connections.append(connection)
        return connection
    }
}

@MainActor
private final class SelectionConnection: AgentConnection {
    var commands: [[String: Any]] = []
    var closeCount = 0
    func send(commandJSON: String) throws {
        commands.append(try #require(JSONSerialization.jsonObject(with: Data(commandJSON.utf8)) as? [String: Any]))
    }
    func close() async { closeCount += 1 }
}
