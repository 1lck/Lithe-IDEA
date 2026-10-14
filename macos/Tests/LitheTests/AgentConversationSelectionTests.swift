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
    func movingPresentationKeepsConnectionDraftAndSession() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex")])
        do {
            let connection = try prepare(panel, transport: transport, agentID: "codex-acp", model: "Model")
            let native = try #require(transport.connections.last)
            connection.draftText = "Unsent prompt"
            connection.draftFiles = [try AgentFileReference(url: URL(fileURLWithPath: "/example/project/notes.txt"))]
            let commandCount = native.commands.count
            var toggles = 0
            let host = NSHostingView(rootView: AgentConfiguredConversationView(feature: panel, setupError: nil,
                onSelectAgent: panel.selectAgent, onConnect: {}, onOpenSettings: {}, onHide: {},
                onCopySessionID: { _ in }, onOpenFile: { _ in },
                onToggleLocation: { toggles += 1 }))
            let window = hiddenWindow(host)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            // The location control sits immediately before More and Hide, all shared 22pt slots.
            try clickNativeView(host, at: NSPoint(x: host.bounds.width - 7 - 22 * 2 - 4 * 2 - 11,
                                                y: LitheTheme.Metrics.toolWindowHeaderHeight / 2))
            #expect(await awaitChange(on: connection) { toggles == 1 })
            host.rootView = AgentConfiguredConversationView(feature: panel, setupError: nil,
                onSelectAgent: panel.selectAgent, onConnect: {}, onOpenSettings: {}, onHide: {},
                onCopySessionID: { _ in }, onOpenFile: { _ in }, historyOnly: true, chatsInEditor: true,
                onToggleLocation: { toggles += 1 })
            host.layoutSubtreeIfNeeded()
            #expect(connection.draftText == "Unsent prompt")
            #expect(connection.draftFiles.count == 1)
            #expect(connection.selectedSessionID == "codex-acp")
            #expect(native.commands.count == commandCount, "Moving does not create or reconnect a session")
            host.rootView = AgentConfiguredConversationView(feature: panel, setupError: nil,
                onSelectAgent: panel.selectAgent, onConnect: {}, onOpenSettings: {}, onHide: {},
                onCopySessionID: { _ in }, onOpenFile: { _ in }, showsChatActions: false, chatsInEditor: true)
            host.layoutSubtreeIfNeeded()
            #expect(connection.draftText == "Unsent prompt" && connection.draftFiles.count == 1)
            connection.startNewConversation()
            #expect(connection.draftText.isEmpty && connection.draftFiles.isEmpty)
        } catch { await panel.stop(); throw error }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test
    func conversationHeaderTracksPromptAndHistoryRenameWithoutReplacingTheRoot() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex")])
        do {
            let feature = try prepare(panel, transport: transport, agentID: "codex-acp", model: "Model")
            let host = hostingView(panel)
            let window = hiddenWindow(host)
            defer { window.close() }
            func headerPixels() throws -> Data {
                host.layoutSubtreeIfNeeded()
                let region = NSRect(x: 0, y: host.isFlipped ? 0 : host.bounds.height - 34, width: 230, height: 34)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
                host.cacheDisplay(in: region, to: bitmap)
                let bytes = try #require(bitmap.bitmapData)
                return Data(bytes: bytes, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            }
            let blank = try headerPixels()
            try feature.send("1")
            let session = try #require(feature.sessions.first { $0.id == "codex-acp" })
            #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: feature.selectedConversation) == "1")
            let prompt = try headerPixels()
            #expect(prompt != blank, "The actual history trigger must replace New Chat with the prompt title")
            let history = panel.history(for: "codex-acp")
            #expect(history.rename(session.id, title: "Reviewed conversation"))
            let renamed = try headerPixels()
            #expect(renamed != prompt, "A local history rename must refresh the existing header")
            #expect(AgentHistoryPresentation.popupTitle(session, metadata: history.metadata[session.id], conversation: feature.selectedConversation) == "Reviewed conversation")
        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test
    func configuredDefaultDoesNotConsumeWelcomeOrStartAgentBeforeUserSelection() async throws {
        let domain = "Lithe.AgentWelcomeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        settings.agentConfigurations["codex-acp"] = .init(name: "Codex", providerID: nil, authentication: .codexSubscription)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .normal).services
        let model = AppModel(settings: settings, services: services)
        do {
            try await services.moduleRuntime.setEnabled(true, for: .agentConversation)
            for _ in 0..<2 {
                model.activateAgentConversation()
                #expect(try services.moduleRuntime.snapshot(for: .agentConversation).isInstantiated == false)
                #expect(model.selectedAgentConversationID == nil)
                #expect(AgentWelcomeVisit.shouldShow(defaults: defaults))
            }
            // Even an already activated module's default must not become a user choice.
            let capability = try #require(try await services.moduleRuntime.activateCapability(.agentConversation) as? AgentConversationCapability)
            capability.feature.setAgents(model.configuredAgentOptions)
            #expect(capability.feature.selectedAgentID == "codex-acp")
            model.connectAgentConversation()
            #expect(model.selectedAgentConversationID == nil)
            #expect(settings.preferredConversationAgentID == nil)
            #expect(!capability.feature.hasActiveConnection)
            #expect(AgentWelcomeVisit.shouldShow(defaults: defaults))
            model.selectAgentConversationAgent("codex-acp")
            #expect(settings.preferredConversationAgentID == "codex-acp")
            #expect(!AgentWelcomeVisit.shouldShow(defaults: defaults))
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
        await model.shutdownProjectSession()
    }

    @Test
    func settingsAndConversationShareSelectionEvenBeforeAgentSetup() async throws {
        let domain = "Lithe.AgentSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = MacUserDefaultsStore(defaults: defaults)
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)

        // Selecting from the conversation must update the shared ID without
        // opening Settings or requiring a configured/active backend module.
        model.selectAgentConversationAgent("claude-acp")
        #expect(model.selectedAgentConversationID == "claude-acp")
        #expect(!model.workbenchFeature.isSettingsPresented)
        #expect(model.agentConversationFeatureIfActive == nil)
        model.showAgentSettings()
        #expect(model.selectedAgentConversationID == "claude-acp")
        let settingsRequest = model.workbenchFeature.settingsCategoryRequest
        model.selectAgentConversationAgent("codex-acp")
        #expect(model.selectedAgentConversationID == "codex-acp")
        #expect(model.workbenchFeature.settingsCategoryRequest == settingsRequest)
        model.showAgentSettings(agentID: AgentConfiguration.customAgentID)
        #expect(model.selectedAgentConversationID == AgentConfiguration.customAgentID)
        #expect(settings.agentConfigurations.isEmpty, "Selection must not manufacture configuration")
        #expect(AppSettings(store: store).preferredConversationAgentID == AgentConfiguration.customAgentID,
                "Both selectors must retain the same preference after reopening")
        await model.shutdownProjectSession()
    }

    @Test(arguments: ["claude-acp", "codex-acp"])
    func closingTheLastTabPreparesSettingsAndAllowsSendingAfterConfirmation(agentID: String) async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: agentID, name: agentID)])
        do {
            let feature = try prepare(panel, transport: transport, agentID: agentID, model: "Confirmed model")
            let native = try #require(transport.connections.last)
            let initialToken = try #require(native.commands.last?["token"] as? String)
            let commandCount = native.commands.count
            let host = hostingView(panel)
            let window = hiddenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let readyToolbar = try toolbarPixels(in: host)

            // Closing the final tab must start real work without another view
            // appearance or connection-state change to escape the loading gate.
            feature.closeConversation(agentID)
            #expect(feature.connectionState == .ready)
            #expect(feature.selectedSessionID == nil)
            #expect(feature.openSessionIDs.isEmpty)
            #expect(feature.conversations[agentID] == nil)
            #expect(feature.isCreatingSession)
            #expect(native.commands.count == commandCount + 1)
            let command = try #require(native.commands.last)
            #expect(command["kind"] as? String == "newSession")
            let token = try #require(command["token"] as? String)
            #expect(token != initialToken)
            feature.closeConversation(agentID)
            feature.prepareConversation()
            #expect(native.commands.count == commandCount + 1, "Pending creation must not be duplicated")
            host.layoutSubtreeIfNeeded()
            let loadingToolbar = try toolbarPixels(in: host)
            #expect(loadingToolbar != readyToolbar)

            feature.receive(try json(["kind": "sessionCreated", "sessionId": agentID, "token": initialToken,
                                      "configOptions": options(model: "Stale model", current: "default")]))
            #expect(feature.selectedSessionID == nil, "The closed session's response must not select it again")
            #expect(feature.isCreatingSession)
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == loadingToolbar)

            let newSessionID = "replacement-session"
            feature.receive(try json(["kind": "sessionCreated", "sessionId": newSessionID, "token": token,
                                      "configOptions": options(model: "Confirmed model", current: "default")]))
            #expect(feature.selectedSessionID == newSessionID)
            #expect(feature.openSessionIDs == [newSessionID])
            #expect(feature.selectedConversation?.isAttached == true)
            #expect(!feature.isCreatingSession)
            host.layoutSubtreeIfNeeded()
            #expect(try toolbarPixels(in: host) == readyToolbar, "Confirmed settings must release the composer loading gate")

            try feature.send("Message after closing the last tab")
            #expect(native.commands.last?["kind"] as? String == "prompt")
            #expect(native.commands.last?["sessionId"] as? String == newSessionID)
            #expect(feature.selectedConversation?.messages.last?.text == "Message after closing the last tab")
        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

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
                onConnect: {}, onOpenSettings: {}, onHide: {}, onCopySessionID: { _ in }, onOpenFile: { _ in }
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

    @Test
    func newChatButtonCreatesARealSessionAndPreventsDuplicateRequests() async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex")])
        do {
            let feature = try prepare(panel, transport: transport, agentID: "codex-acp", model: "Model")
            let native = try #require(transport.connections.last)
            try feature.send("Keep this conversation")
            feature.receive(try json(["kind": "turnFinished", "sessionId": "codex-acp"]))
            let host = hostingView(panel)
            let window = hiddenWindow(host)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let count = native.commands.count
            let textWidth = ("New Chat" as NSString).size(withAttributes: [.font: LitheTheme.uiNSFont(size: 13)]).width
            let buttonWidth = 16 + 2 + textWidth + 8
            // Header trailing inset, two shared icon buttons and two four-point gaps.
            let point = NSPoint(x: host.bounds.width - 7 - 22 * 2 - 4 * 2 - buttonWidth / 2,
                                y: LitheTheme.Metrics.toolWindowHeaderHeight / 2)
            try clickNativeView(host, at: point)
            #expect(await awaitChange(on: feature) { feature.isCreatingSession })
            #expect(native.commands.count == count + 1)
            #expect(native.commands.last?["kind"] as? String == "newSession")
            #expect(feature.isCreatingSession)
            #expect(feature.selectedSessionID == nil)
            host.layoutSubtreeIfNeeded()
            try clickNativeView(host, at: point)
            #expect(native.commands.count == count + 1)
            feature.receive(try json(["kind": "sessionCreated", "sessionId": "new-chat",
                                       "token": native.commands.last?["token"] as Any]))
            host.layoutSubtreeIfNeeded()
            #expect(feature.selectedSessionID == "new-chat")
            #expect(feature.openSessionIDs == ["codex-acp", "new-chat"])
            let session = try #require(feature.sessions.first { $0.id == "new-chat" })
            let conversation = try #require(feature.conversations[session.id])
            #expect(conversation.hasCompleteHistory)
            #expect(AgentHistoryPresentation.popupTitle(session, metadata: nil, conversation: conversation) == String(localized: "New Chat"))
            #expect(AgentHistoryPresentation.popupTitle(session, metadata: .init(title: "Renamed"), conversation: conversation) == "Renamed")
            try clickNativeView(host, at: point)
            #expect(await awaitChange(on: feature) { feature.isCreatingSession })
            #expect(native.commands.count == count + 2, "New Chat becomes usable again after confirmation")
            #expect(feature.conversations["new-chat"] == nil)
            #expect(!feature.sessions.contains { $0.id == "new-chat" })
            #expect(feature.openSessionIDs == ["codex-acp"])
            #expect(feature.conversations["codex-acp"]?.messages.first?.text == "Keep this conversation")
            feature.receive(try json(["kind": "sessionCreated", "sessionId": "replacement",
                                       "token": native.commands.last?["token"] as Any]))
            #expect(feature.openSessionIDs == ["codex-acp", "replacement"])

        } catch {
            await panel.stop()
            throw error
        }
        await panel.stop()
        #expect(transport.connections.allSatisfy { $0.closeCount == 1 })
    }

    @Test(arguments: [false, true])
    func historyPopupLoadsTheChosenSessionThroughTheExistingConnection(useKeyboard: Bool) async throws {
        let transport = SelectionTransport()
        let panel = AgentConversationFeatureModel(transport: transport)
        panel.setAgents([.init(id: "codex-acp", name: "Codex")])
        do {
            let feature = try prepare(panel, transport: transport, agentID: "codex-acp", model: "Model")
            feature.receive(try json(["kind": "ready", "agentName": "Codex", "canLoadSessions": true, "canListSessions": true]))
            let native = try #require(transport.connections.last)
            let listToken = try #require(native.commands.last?["token"] as? String)
            feature.receive(try json(["kind": "sessions", "token": listToken, "sessions": [
                ["sessionId": "earlier", "title": "Earlier conversation", "updatedAt": "2026-09-26T10:00:00Z"]]]))
            let presenter = LitheContextMenuPresenter()
            var dismissals = 0
            let controller = LitheDropdownHostingController(rootView: AnyView(AgentHistoryPopover(feature: feature,
                history: panel.history(for: "codex-acp"), agentName: "Codex",
                onSelect: { id in presenter.dismiss(); feature.selectSession(id) }, onManage: {}, onSearch: {}, onDismiss: {})
                .litheContextMenuSurface()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { presenter.dismiss(); window.close() }
            window.makeKeyAndOrderFront(nil)
            presenter.show(contentController: controller, at: NSPoint(x: 80, y: 600), appearance: nil,
                           parentWindow: window, onDismiss: { dismissals += 1 })
            let host = controller.view
            let popup = try #require(host.window)
            host.layoutSubtreeIfNeeded()
            #expect(AgentHistoryPresentation.popupSessions(feature.sessions, openSessionIDs: feature.openSessionIDs,
                metadata: [:], selectedSessionID: feature.selectedSessionID).map(\.id) == ["codex-acp", "earlier"])
            if useKeyboard {
                popup.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                for (code, characters) in [(UInt16(125), "\u{F701}"), (UInt16(36), "\r")] {
                    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: 0, windowNumber: popup.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                    NSApplication.shared.sendEvent(event)
                    host.layoutSubtreeIfNeeded()
                }
            } else {
                try clickNativeView(host, at: NSPoint(x: 100,
                    y: LitheDropdownMetrics.popupPadding + LitheDropdownMetrics.rowHeight * 1.5))
            }
            #expect(await awaitChange(on: feature) { feature.selectedSessionID == "earlier" })
            #expect(native.commands.last?["kind"] as? String == "loadSession")
            #expect(native.commands.last?["sessionId"] as? String == "earlier")
            #expect(feature.selectedConversation?.isLoading == true)
            #expect(dismissals == 1 && !popup.isVisible, "Selecting a row closes the popup")
            presenter.show(contentController: controller, at: NSPoint(x: 80, y: 600), appearance: nil,
                           parentWindow: window, onDismiss: { dismissals += 1 })
            let reopened = try #require(host.window)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: reopened.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
            NSApplication.shared.sendEvent(escape)
            #expect(dismissals == 2 && !reopened.isVisible)
            presenter.show(contentController: controller, at: NSPoint(x: 80, y: 600), appearance: nil,
                           parentWindow: window, onDismiss: { dismissals += 1 })
            let outsidePopup = try #require(host.window)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 470, y: 620),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
            }
            #expect(dismissals == 3 && !outsidePopup.isVisible)

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
            onConnect: {}, onOpenSettings: {}, onHide: {}, onCopySessionID: { _ in }, onOpenFile: { _ in }
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
