import Foundation
import LitheAgentConversationModule
import LitheCoreContracts
import LitheModuleAPI

extension AppModel {
    /// The menu captures its workspace, Agent and session before any async module
    /// startup. A project switch must never redirect the user's file elsewhere.
    func attachFilesToAgent(_ urls: [URL], agentID: String, destination: AgentFileAttachmentDestination,
                            workspace: WorkspaceIdentity) async {
        guard isCurrentWorkspace(workspace) else { return }
        guard isAgentConversationEnabled, configuredAgentOptions.contains(where: { $0.id == agentID }) else {
            showAgentSettings()
            return
        }
        do {
            _ = try AgentFileReference.adding(urls, to: [])
            guard !urls.isEmpty, urls.allSatisfy({ services.fileStorage.metadata(for: $0)?.isRegularFile == true }) else {
                showNotification(String(localized: "Choose existing files to add to a conversation."))
                return
            }
            if agentConversationFeatureIfActive == nil {
                await awaitModuleRuntimeShutdown()
                guard isCurrentWorkspace(workspace) else { return }
                _ = try await services.moduleRuntime.activateCapability(.agentConversation)
            }
            guard isCurrentWorkspace(workspace), isAgentConversationEnabled,
                  let feature = agentConversationFeatureIfActive else { return }
            feature.bindWorkspace(workspace.url)
            feature.setAgents(configuredAgentOptions)
            try feature.attachFiles(urls, agentID: agentID, to: destination)
            selectedAgentConversationID = agentID
            connectAgentConversation()
            if agentChatsInEditor { showAgentChatsInEditor() }
            else { workbenchFeature.setVisibility(.agent, isVisible: true) }
            objectWillChange.send()
            if openDocuments.contains(where: { document in
                document.isDirty && urls.contains { $0.standardizedFileURL == document.url.standardizedFileURL }
            }) {
                showNotification(String(localized: "Files added. Save your editor changes before sending so the Agent can read them."))
            }
        } catch {
            showNotification(String(localized: String.LocalizationValue(error.localizedDescription)))
        }
    }

    var agentChatsInEditor: Bool { editorTabOrderFeature.contains(.agentConversation) }
    var isAgentEditorSelected: Bool { agentChatsInEditor && editorTabOrderFeature.focusedItem == .agentConversation }

    func showAgentChatsInEditor() {
        if !agentChatsInEditor { editorTabOrderFeature.moveToEnd(.agentConversation) }
        selectedChange = nil
        closeBranchComparison()
        editorTabOrderFeature.repositoryDiffSelected = false
        editorTabOrderFeature.databaseSelected = false
        editorTabOrderFeature.focus(.agentConversation)
        workbenchFeature.setVisibility(.agent, isVisible: true)
    }

    func showAgentChatsInToolWindow() {
        let wasSelected = isAgentEditorSelected
        editorTabOrderFeature.remove(.agentConversation)
        if wasSelected, let next = editorTabItems.last { selectEditorTab(next) }
        workbenchFeature.setVisibility(.agent, isVisible: true)
    }

    func copyAgentSessionID(_ id: String) {
        platformUI.copyToClipboard(id)
    }

    func openAgentFile(_ location: AgentToolDetails.Location) {
        guard let workspaceURL, let url = location.fileURL(in: workspaceURL) else {
            showNotification(String(localized: "This file is outside the current project."))
            return
        }
        if let line = location.line {
            navigateToEditorLocation(url: url, line: line - 1, utf16Column: 0)
        } else {
            openFile(url)
        }
    }

    /// A bare `@` offers the loaded workspace inventory; keywords use file search.
    func agentFileMentions(matching query: String) async -> [AgentFileMention] {
        guard let root = workspaceURL?.standardizedFileURL else { return [] }
        let rootComponents = root.pathComponents
        let files = query.isEmpty ? projectFiles : await searchWorkflow.findFiles(query: query)
        guard workspaceURL?.standardizedFileURL == root, !Task.isCancelled else { return [] }
        return Array(files.lazy.compactMap { url -> AgentFileMention? in
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else { return nil }
            return AgentFileMention(path: components.dropFirst(rootComponents.count).joined(separator: "/"), url: url)
        }.prefix(20))
    }

    /// Stores a pasted image so it can be attached like any local file. Agents
    /// read attachments as ACP resource links, so the image must outlive the
    /// paste; it lives in Caches (never the app bundle) and is pruned after a week.
    func saveAgentPastedImage(_ png: Data) throws -> URL {
        let storage = services.fileStorage
        let directory = storage.cacheDirectory().appendingPathComponent("AgentPastedImages", isDirectory: true)
        try storage.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for file in storage.listDirectory(at: directory)
        where (storage.metadata(for: file)?.modificationDate ?? .distantFuture) < cutoff {
            try? storage.removeItem(at: file)
        }
        let url = directory.appendingPathComponent(AgentPastedImage.fileName(), isDirectory: false)
        try storage.writeData(png, to: url, options: .atomic)
        return url
    }

    var isAgentConversationEnabled: Bool {
        guard let snapshot = try? services.moduleRuntime.snapshot(for: .agentConversation) else { return false }
        return snapshot.state != .disabled
    }

    var agentConversationFeatureIfActive: AgentConversationFeatureModel? {
        (services.moduleRuntime.capability(.agentConversation) as? AgentConversationCapability)?.feature
    }

    /// The panel stays open when the feature is turned off; only the Agent
    /// processes stop and the panel explains how to turn it back on.
    func setAgentConversationEnabled(_ enabled: Bool) async {
        if !enabled {
            agentConversationNeedsAttention = false
        }
        do {
            try await services.moduleRuntime.setEnabled(enabled, for: .agentConversation)
            objectWillChange.send()
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        if enabled, workbenchFeature.isVisible(.agent) {
            activateAgentConversation()
        }
    }

    /// Show or hide the panel. The panel always renders its full layout; the
    /// module is only activated when the feature is enabled.
    func toggleAgentConversation() {
        guard workspaceURL != nil else { return }
        guard toggleToolWindow(.agent) else { return }
        activateAgentConversation()
    }

    func activateAgentConversation() {
        guard selectedAgentConversationID != nil else { return }
        guard isAgentConversationEnabled, agentConversationFeatureIfActive == nil else {
            connectAgentConversation()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await awaitModuleRuntimeShutdown()
                _ = try await services.moduleRuntime.activateCapability(.agentConversation)
                objectWillChange.send()
                connectAgentConversation()
            } catch {
                showNotification(error.localizedDescription)
            }
        }
    }

    /// Why a message cannot be sent right now, before any Agent is involved.
    var agentConversationSetupError: AgentConversationError? {
        if !isAgentConversationEnabled { return .featureDisabled }
        if configuredAgentOptions.isEmpty { return .noAgentConfigured }
        if agentConversationFeatureIfActive == nil { return .moduleStarting }
        return nil
    }

    /// Which local CLI configuration an agent follows, if any.
    static func localConfigurationSource(for agentID: String) -> AIConfigurationSourceKind? {
        switch agentID {
        case "codex-acp": .codex
        case "claude-acp": .claude
        default: nil
        }
    }

    /// Read the user's own CLI configuration (endpoint, model, API key) and
    /// bind it to `agentID`. Lithe keeps following that file; nothing is
    /// copied into Lithe settings except the provider profile. The commit
    /// message provider is left untouched.
    @discardableResult
    func importLocalConfiguration(for agentID: String, source: AIConfigurationSourceKind, name: String) -> Bool {
        guard let configuration = loadAIConfigurations().first(where: { $0.source == source }) else {
            detectedAIConfigurations.removeAll { $0.source == source }
            showNotification(String(format: String(localized: "No %@ configuration was found on this Mac."), source.title))
            return false
        }
        let commitProviderID = settings.commitMessageAI.activeProviderID
        let provider = settings.importAIConfiguration(configuration)
        settings.commitMessageAI.activeProviderID = commitProviderID
        try? services.secureStore.delete(key: provider.apiKeyIdentifier)
        detectedAIConfigurations.removeAll { $0.source == source }
        detectedAIConfigurations.append(configuration)
        settings.setAgentProvider(provider.id, for: agentID, name: name)
        showNotification(String(format: String(localized: "%@ now follows your local %@ configuration."), name, source.title))
        return true
    }

    /// Directory holding Lithe-managed ACP adapter installs.
    var agentDataDirectory: URL {
        services.fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe", isDirectory: true)
    }

    /// Agents with a provider assigned in Settings › Agents, for the panel.
    var configuredAgentOptions: [AgentOption] {
        settings.agentConfigurations
            .filter { id, configuration in
                configuration.isConfigured
                    && (id != AgentConfiguration.customAgentID
                        || !settings.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .map { id, configuration -> AgentOption in
                let provider = settings.agentProvider(for: id)
                let model = configuration.authentication == .codexSubscription ? "Codex subscription" : (provider?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                return AgentOption(id: id, name: configuration.name, modelName: model.isEmpty ? provider?.name : model)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Refresh the panel's agents and start the selected one if needed.
    func connectAgentConversation() {
        guard !isChangingAgentProvider else { return }
        guard let selectedAgentConversationID else { return }
        guard let feature = agentConversationFeatureIfActive else { return }
        if let workspaceURL { feature.bindWorkspace(workspaceURL) }
        feature.onAttentionChanged = { [weak self] needsAttention in
            self?.agentConversationNeedsAttention = needsAttention
        }
        feature.setAgents(configuredAgentOptions)
        guard feature.agents.contains(where: { $0.id == selectedAgentConversationID }) else { return }
        feature.selectAgent(selectedAgentConversationID)
        guard let agentID = feature.selectedAgentID else { return }
        let connection = feature.connection(for: agentID)
        guard !connection.hasActiveConnection else { return }
        do {
            // Refresh the displayed fallback even when credential validation fails.
            defer { feature.setAgents(configuredAgentOptions) }
            let configuration = try agentLaunchConfiguration(agentID: agentID)
            try connection.connect(configuration: configuration)
        } catch {
            // The panel shows the reason and offers a retry.
            connection.reportConnectionFailure(error.localizedDescription)
        }
    }

    func selectAgentConversationAgent(_ agentID: String) {
        selectedAgentConversationID = agentID
        agentConversationFeatureIfActive?.selectAgent(agentID)
        connectAgentConversation()
    }

    func agentLaunchConfiguration(agentID: String) throws -> AgentLaunchConfiguration {
        guard let workspaceURL else { throw AgentConversationError.notConnected }
        return try AgentLaunchConfigurationResolver(settings: settings,
            configurationSources: services.aiConfigurationSources,
            credentialResolver: services.credentialResolver)
            .resolve(agentID: agentID, workspaceURL: workspaceURL, dataDirectory: agentDataDirectory)
    }
}
