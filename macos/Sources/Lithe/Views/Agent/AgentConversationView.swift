import SwiftUI
import LitheAgentConversationModule

/// Right-docked Agent panel. Setup lives in the main Settings window.
struct AgentConversationView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    let isEditor: Bool
    @State private var showsWelcome: Bool

    private var feature: AgentConversationFeatureModel? { model.agentConversationFeatureIfActive }

    private var selectableAgents: [AgentOption] {
        AgentWelcomeVisit.builtInAgents.map { builtIn in
            model.configuredAgentOptions.first { $0.id == builtIn.id } ?? builtIn
        } + [.init(id: AgentConfiguration.customAgentID,
                   name: model.settings.agentConfigurations[AgentConfiguration.customAgentID]?.name ?? AgentLocalization.string("Custom Agent", locale: locale))]
    }

    init(model: AppModel, isEditor: Bool = false) {
        self.model = model
        self.isEditor = isEditor
        _showsWelcome = State(initialValue: model.selectedAgentConversationID == nil && AgentWelcomeVisit.shouldShow())
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsWelcome {
                LitheToolWindowHeader(title: "Agent", usesWorkbenchSurface: true) { EmptyView() }
                AgentWelcomeView(
                    onOpenAgent: { agentID in
                        AgentWelcomeVisit.markAgentChosen(agentID: agentID)
                        showsWelcome = false
                        if agentID == AgentConfiguration.customAgentID { model.showAgentSettings(agentID: agentID) }
                        else { model.selectAgentConversationAgent(agentID) }
                    },
                    onOpenProviders: {
                        model.showSettings(category: .providers)
                    }
                )
            } else if let feature,
                      model.selectedAgentConversationID.map({ id in feature.agents.contains { $0.id == id } }) ?? true {
                AgentConfiguredConversationView(
                    feature: feature,
                    setupError: model.agentConversationSetupError,
                    onSelectAgent: { model.selectAgentConversationAgent($0) },
                    onConnect: { model.connectAgentConversation() },
                    onOpenSettings: openSettings,
                    onHide: hidePanel,
                    onCopySessionID: { model.copyAgentSessionID($0) },
                    onOpenFile: { model.openAgentFile($0) },
                    onRestoreFile: { try await model.restoreAgentFile($0) },
                    availableAgents: selectableAgents,
                    historyOnly: !isEditor && model.agentChatsInEditor,
                    showsChatActions: !isEditor,
                    chatsInEditor: model.agentChatsInEditor,
                    onToggleLocation: {
                        if model.agentChatsInEditor { model.showAgentChatsInToolWindow() }
                        else { model.showAgentChatsInEditor() }
                    },
                    onFocusEditor: { model.showAgentChatsInEditor() }
                )
            } else {
                AgentUnconfiguredConversationView(
                    setupError: model.agentConversationSetupError ?? .noAgentConfigured,
                    onOpenSettings: openSettings,
                    onHide: hidePanel,
                    agentName: selectableAgents.first { $0.id == model.selectedAgentConversationID }?.name
                        ?? AgentWelcomeVisit.chosenAgentName(),
                    agents: selectableAgents,
                    onChooseAgent: { id in
                        AgentWelcomeVisit.markAgentChosen(agentID: id)
                        model.selectAgentConversationAgent(id)
                    }
                )
            }
        }
        .frame(maxWidth: isEditor ? AgentPanelStyle.editorContentMaximumWidth : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .workbenchHoverTooltipScope()
        .onAppear {
            if !showsWelcome {
                if model.selectedAgentConversationID == nil, let id = AgentWelcomeVisit.chosenAgentID() {
                    model.selectAgentConversationAgent(id)
                }
                model.activateAgentConversation()
            }
        }
        .onChange(of: model.selectedAgentConversationID) { id in
            if let id {
                AgentWelcomeVisit.markAgentChosen(agentID: id)
                showsWelcome = false
            }
        }
        .onChange(of: showsWelcome) { isVisible in
            if !isVisible { model.activateAgentConversation() }
        }
    }

    private func openSettings() {
        model.showAgentSettings()
    }

    private func hidePanel() {
        model.workbenchFeature.setVisibility(.agent, isVisible: false)
    }
}

/// Keep the welcome page until a user chooses an Agent, across projects and launches.
enum AgentWelcomeVisit {
    private static let key = AppSettings.agentSelectionPreferenceKey
    static let builtInAgents = [AgentOption(id: "codex-acp", name: "Codex"),
                               AgentOption(id: "claude-acp", name: "Claude Agent")]

    static func shouldShow(defaults: UserDefaults = .standard) -> Bool {
        chosenAgentID(defaults: defaults) == nil
    }

    static func markAgentChosen(agentID: String, defaults: UserDefaults = .standard) {
        defaults.set(agentID, forKey: key)
    }

    static func chosenAgentID(defaults: UserDefaults = .standard) -> String? {
        defaults.object(forKey: key) as? String
    }

    static func chosenAgentName(defaults: UserDefaults = .standard) -> String? {
        builtInAgents.first { $0.id == chosenAgentID(defaults: defaults) }?.name
    }
}


/// Chat-specific content header using the workbench's shared toolbar controls.
struct AgentChatHeader: View {
    @Environment(\.locale) private var locale
    let agentName: String?
    let onHistory: (() -> Void)?
    let onNew: (() -> Void)?
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    var conversationTitle: String? = nil
    var historyPopup: ((@escaping () -> Void) -> AnyView)? = nil
    var onToggleLocation: (() -> Void)? = nil
    var chatsInEditor = false
    var showsAgentHeading = true
    var showsActions = true
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var showsToolbar = true
    var onToggleToolbar: (() -> Void)? = nil
    @State private var showsHistoryPopup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsActions {
                HStack(spacing: 4) {
                    Button {
                        showsHistoryPopup.toggle()
                    } label: {
                        HStack(spacing: LitheTheme.MainToolbar.comboIconTextGap) {
                            AgentBrandIcon(name: agentName, size: LitheTheme.Metrics.toolbarIconSize, style: .brand)
                            HStack(spacing: LitheTheme.MainToolbar.comboExpandGap) {
                                Text(conversationTitle ?? AgentLocalization.string("Chat History", locale: locale))
                                    .lineLimit(1).truncationMode(.tail)
                                LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                              fallbackSystemImage: "chevron.down", preservesOriginalColors: true)
                            }
                        }
                        .font(LitheTheme.uiFont(size: 13, weight: .regular))
                        .padding(.leading, LitheTheme.MainToolbar.comboInsets.leading)
                        .padding(.trailing, LitheTheme.MainToolbar.comboInsets.trailing)
                    }
                    .buttonStyle(LitheIconButtonStyle(size: LitheTheme.MainToolbar.comboHeight, isIconOnly: false))
                    .litheDropdown(isPresented: $showsHistoryPopup) {
                        if let historyPopup {
                            historyPopup { showsHistoryPopup = false }
                        } else {
                            VStack(alignment: .leading, spacing: LitheDropdownMetrics.popupPadding) {
                                Text("Conversation history is unavailable")
                                    .font(LitheTheme.settingsFont)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                    .frame(maxWidth: .infinity, minHeight: LitheDropdownMetrics.historyViewportHeight,
                                           alignment: .topLeading)
                                if let onHistory {
                                    Button("Conversation history") {
                                        showsHistoryPopup = false
                                        onHistory()
                                    }.buttonStyle(LitheDropdownRowStyle())
                                }
                            }
                            .padding(LitheDropdownMetrics.popupPadding)
                            .frame(width: LitheDropdownMetrics.maximumWidth)
                        }
                    }
                    .disabled(onHistory == nil)
                    .help("Conversation history")
                    .accessibilityIdentifier("agent-history-open")
                    Spacer(minLength: 4)
                    Button { onNew?() } label: {
                        HStack(spacing: 2) {
                            LitheIDEAIcon(resourcePath: "expui/general/add.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                          fallbackSystemImage: "plus", preservesOriginalColors: true)
                            Text("New Chat").lineLimit(1)
                        }
                        .font(LitheTheme.uiFont(size: 13))
                        .padding(.horizontal, 4)
                    }
                    .litheToolbarIconButton(isIconOnly: false)
                    .disabled(onNew == nil)
                    .help("New conversation")
                    .accessibilityIdentifier("agent-new-chat")
                    if let onToggleLocation {
                        Button(action: onToggleLocation) {
                            LitheIDEAIcon(resourcePath: "expui/general/previewVertically.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                          fallbackSystemImage: "rectangle.rightthird.inset.filled", preservesOriginalColors: true)
                        }
                        .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: chatsInEditor))
                        .help(chatsInEditor ? "Show Chats in the AI Tool Window" : "Show Chats in the Editor")
                        .accessibilityIdentifier("agent-chat-location")
                    }
                    LitheMenu {
                        LitheContextMenuItem.action("Rename Chat", isEnabled: onRename != nil) { onRename?() }
                        LitheContextMenuItem.action("Delete Chat",
                            icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: LitheDropdownMetrics.iconSize,
                                                       fallbackSystemImage: "trash", preservesOriginalColors: true)),
                            role: .destructive, isEnabled: onDelete != nil) { onDelete?() }
                        LitheContextMenuItem.separator
                        LitheContextMenuItem.action("Settings…", action: onOpenSettings)
                        LitheContextMenuItem.separator
                        LitheContextMenuItem.action("Show Toolbar", checked: showsToolbar, leadingCheckmark: true,
                                                    isEnabled: onToggleToolbar != nil) { onToggleToolbar?() }
                    } label: {
                        LitheIDEAIcon(resourcePath: "expui/general/moreVertical.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                      fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
                    }
                    .litheToolbarIconButton()
                    .help("Chat options")
                    .accessibilityIdentifier("agent-header-options")
                    LitheSidebarHideButton(title: "Agent", action: onHide)
                }
                .padding(.leading, 12)
                .padding(.trailing, 7)
                .frame(height: LitheTheme.Metrics.toolWindowHeaderHeight)
            }
            if showsAgentHeading {
                HStack(spacing: 8) {
                    AgentBrandIcon(name: agentName, size: 16, style: .brand)
                    Text(agentName ?? AgentLocalization.string("Agent", locale: locale))
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(AgentPanelStyle.text)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("agent-selected-name")
            }
        }
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
    }
}

/// Observe selection where the selected connection is resolved. AppModel does
/// not forward this optional module's changes, and each connection owns its UI.
struct AgentConfiguredConversationView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentConversationFeatureModel
    let setupError: AgentConversationError?
    let onSelectAgent: (String) -> Void
    let onConnect: () -> Void
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    let onCopySessionID: (String) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void
    var onRestoreFile: (AgentFileChange) async throws -> Void = { _ in throw AgentEditRestoreError.unavailable }
    var availableAgents: [AgentOption]? = nil
    var historyOnly = false
    var showsChatActions = true
    var chatsInEditor = false
    var onToggleLocation: (() -> Void)? = nil
    var onFocusEditor: (() -> Void)? = nil

    var body: some View {
        if let connection = feature.selectedConnection, let agentID = feature.selectedAgentID {
            AgentConnectionView(
                feature: connection,
                history: feature.history(for: agentID),
                agents: availableAgents ?? feature.agents,
                selectedAgentID: agentID,
                onSelectAgent: onSelectAgent,
                onConnect: onConnect,
                onOpenSettings: onOpenSettings,
                onHide: onHide,
                onCopySessionID: onCopySessionID,
                onOpenFile: onOpenFile,
                onRestoreFile: onRestoreFile,
                historyOnly: historyOnly, showsChatActions: showsChatActions, chatsInEditor: chatsInEditor,
                onToggleLocation: onToggleLocation, onFocusEditor: onFocusEditor
            )
            .id(agentID)
        } else {
            AgentUnconfiguredConversationView(setupError: setupError, onOpenSettings: onOpenSettings,
                                              onHide: onHide, agents: availableAgents ?? AgentWelcomeVisit.builtInAgents,
                                              onChooseAgent: onSelectAgent)
        }
    }
}

/// Keep the composer available before setup so sending explains what is missing.
struct AgentUnconfiguredConversationView: View {
    @Environment(\.locale) private var locale
    let setupError: AgentConversationError?
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    var agentName: String? = nil
    var agents: [AgentOption] = AgentWelcomeVisit.builtInAgents
    var onChooseAgent: ((String) -> Void)? = nil
    @State private var notice: String?
    @State private var showsHistory = false

    var body: some View {
        ZStack {
            conversation
                .opacity(showsHistory ? 0 : 1)
                .allowsHitTesting(!showsHistory)
                .accessibilityHidden(showsHistory)
            if showsHistory {
                VStack(spacing: 0) {
                    LitheToolWindowHeader(title: "Conversation history", usesWorkbenchSurface: true) {
                        Button("Back") { showsHistory = false }
                            .litheToolbarIconButton(isIconOnly: false)
                            .accessibilityIdentifier("agent-unconfigured-history-back")
                    }
                    AgentEmptyStateView(systemImage: "clock.arrow.circlepath",
                        title: "Conversation history is unavailable",
                        message: setupError?.localizedDescription ?? AgentLocalization.string("No Agent is set up yet", locale: locale),
                        actionTitle: "Open Agent Settings", action: onOpenSettings)
                }
                .litheWorkbenchSurface(AgentPanelStyle.canvas)
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            AgentChatHeader(agentName: agentName, onHistory: { showsHistory = true },
                            onNew: {
                                notice = String(format: "Cannot create a new conversation: %@",
                                                (setupError ?? .noAgentConfigured).localizedDescription)
                            },
                            onOpenSettings: onOpenSettings, onHide: onHide)
            AgentConversationLayout {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Start the session by sending a message", systemImage: "key.horizontal")
                        .font(LitheTheme.uiFont(size: 13))
                        .foregroundStyle(AgentPanelStyle.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                    if let notice {
                        AgentInlineNotice(text: notice)
                    }
                }
            } composer: {
                AgentComposerView(
                    agents: agents, selectedAgent: nil, isResponding: false, isBlocked: false,
                    onSend: { _, _ in throw setupError ?? .moduleStarting },
                    onCancel: {}, onSelectAgent: { id in
                        onChooseAgent?(id)
                    }, onOpenSettings: onOpenSettings,
                    onError: { notice = $0 }, fallbackAgentName: agentName
                )
            }
        }
        .onAppear { notice = setupError?.localizedDescription }
        .onChange(of: setupError) { notice = $0?.localizedDescription }
    }
}

private struct AgentConnectionView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    let agents: [AgentOption]
    let selectedAgentID: String?
    let onSelectAgent: (String) -> Void
    let onConnect: () -> Void
    let onOpenSettings: () -> Void
    let onHide: () -> Void
    let onCopySessionID: (String) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void
    let onRestoreFile: (AgentFileChange) async throws -> Void
    var historyOnly = false
    var showsChatActions = true
    var chatsInEditor = false
    var onToggleLocation: (() -> Void)? = nil
    var onFocusEditor: (() -> Void)? = nil
    @State private var localError: String?
    @State private var showsSearch = false
    @State private var searchText = ""
    @State private var showsHistory = false
    @State private var renameSessionID: String?
    @State private var renameTitle = ""
    @State private var deleteSessionID: String?
    @AppStorage("lithe.agent.showToolbar") private var showsToolbar = true
    @State private var draftReset = 0
    @Environment(\.scenePhase) private var scenePhase

    private var canDeleteConversation: Bool {
        guard let conversation = feature.selectedConversation else { return false }
        return !conversation.isResponding && !conversation.isLoading
            && conversation.pendingConfigToken == nil && conversation.permission == nil
    }

    private var shouldPollQuota: Bool {
        feature.usesSubscription && feature.connectionState == .ready && scenePhase == .active && !showsHistory && !historyOnly
    }

    private var selectedAgent: AgentOption? { agents.first { $0.id == selectedAgentID } }

    /// A saved provider model is not the current session's confirmed model.
    /// Include the ready-to-create gap, but stop waiting on failure or sign-in.
    private var isPreparingSession: Bool {
        switch feature.connectionState {
        case .idle, .connecting:
            return true
        case .ready:
            return feature.isCreatingSession || feature.selectedConversation?.isLoading == true
                || (feature.selectedSessionID == nil && feature.errorMessage == nil)
        case .authenticationRequired, .authenticating, .failed:
            return false
        }
    }

    var body: some View {
        ZStack {
            conversation
                .opacity(showsHistory ? 0 : 1)
                .allowsHitTesting(!showsHistory)
                .accessibilityHidden(showsHistory)
            if showsHistory {
                AgentHistoryView(feature: feature, history: history, agentName: selectedAgent?.name,
                                 onBack: { showsHistory = false }, onCopySessionID: onCopySessionID,
                                 onSelect: { feature.selectSession($0); showsHistory = false },
                                 onReconnect: onConnect)
            }
        }
        .alert("Rename Chat", isPresented: Binding(
            get: { renameSessionID != nil }, set: { if !$0 { renameSessionID = nil } }
        ), presenting: renameSessionID) { id in
            TextField("Name", text: $renameTitle)
            Button("Cancel", role: .cancel) { renameSessionID = nil }
            Button("Save") {
                if !history.rename(id, title: renameTitle) { localError = history.errorMessage }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Confirm deletion", isPresented: Binding(
            get: { deleteSessionID != nil }, set: { if !$0 { deleteSessionID = nil } }
        ), presenting: deleteSessionID) { id in
            Button("Cancel", role: .cancel) { deleteSessionID = nil }
            Button("Delete", role: .destructive) {
                guard feature.selectedSessionID == id, canDeleteConversation else { return }
                if history.setHidden([id], true) { feature.closeConversation(id) }
                else { localError = history.errorMessage }
            }
        } message: { _ in
            Text(String(format: AgentLocalization.string("Remove %d conversation(s) from history? You can restore them from Removed conversations. The Agent's original records will be kept.", locale: locale), 1))
        }
        .task(id: shouldPollQuota) {
            guard shouldPollQuota else { return }
            while !Task.isCancelled {
                feature.refreshQuota()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
        .onAppear { feature.prepareConversation() }
        .onChange(of: feature.connectionState) { state in
            if state == .ready { feature.prepareConversation() }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            AgentChatHeader(
                agentName: selectedAgent?.name ?? feature.agentName,
                onHistory: { showsHistory = true },
                onNew: feature.isCreatingSession ? nil : startNewConversation,
                onOpenSettings: onOpenSettings,
                onHide: onHide,
                conversationTitle: historyOnly ? AgentLocalization.string("AI Chat", locale: locale) : conversationTitle,
                historyPopup: { dismiss in
                    AnyView(AgentHistoryPopover(feature: feature, history: history,
                        agentName: selectedAgent?.name ?? feature.agentName,
                        onSelect: { id in dismiss(); feature.selectSession(id) },
                        onManage: { dismiss(); showsHistory = true },
                        onSearch: { dismiss(); showsSearch = true }, onDismiss: dismiss))
                },
                onToggleLocation: onToggleLocation, chatsInEditor: chatsInEditor,
                showsAgentHeading: !historyOnly, showsActions: showsChatActions,
                onRename: feature.selectedSessionID.map { id in {
                    renameTitle = conversationTitle ?? ""
                    renameSessionID = id
                } },
                onDelete: canDeleteConversation ? {
                    if canDeleteConversation { deleteSessionID = feature.selectedSessionID }
                } : nil,
                showsToolbar: showsToolbar,
                onToggleToolbar: { showsToolbar.toggle() }
            )
            if historyOnly {
                AgentHistoryPopover(feature: feature, history: history, agentName: selectedAgent?.name ?? feature.agentName,
                    onSelect: { id in feature.selectSession(id); onFocusEditor?() },
                    onManage: { showsHistory = true }, onSearch: { showsSearch = true }, onDismiss: {},
                    isToolWindow: true)
            } else {
                if showsSearch {
                    HStack(spacing: 6) {
                        LitheIDEAIcon(resourcePath: "expui/general/search.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        LitheSearchTextField("Search conversation", text: $searchText)
                        Button { showsSearch = false; searchText = "" } label: {
                            LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                        }
                            .litheToolbarIconButton()
                            .help("Close search")
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .frame(height: 34)
                    .litheWorkbenchSurface(AgentPanelStyle.context)
                }
                AgentConversationLayout {
                    VStack(spacing: 0) {
                        transcript
                        if let error = localError ?? feature.selectedConversation?.configurationError ?? feature.selectedConversation?.errorMessage ?? feature.errorMessage {
                            AgentInlineNotice(text: error, status: .error)
                        }
                    }
                } composer: {
                    AgentComposerView(
                        agents: agents,
                        selectedAgent: selectedAgent,
                        isResponding: feature.selectedConversation?.isResponding == true,
                        isBlocked: feature.isCreatingSession
                            || feature.selectedConversation?.isLoading == true
                            || feature.connectionState != .ready,
                        onSend: { try feature.send($0, files: $1) },
                        onCancel: { feature.cancel() },
                        onSelectAgent: onSelectAgent,
                        onOpenSettings: onOpenSettings,
                        onError: { localError = $0 },
                        configOptions: feature.selectedConversation?.displayConfigOptions ?? [],
                        sessionID: feature.selectedSessionID,
                        isPreparingSession: isPreparingSession,
                        isConfiguring: feature.selectedConversation?.pendingConfigToken != nil,
                        isCancelling: feature.selectedConversation?.isCancelling == true,
                        contextUsage: feature.selectedConversation?.contextUsage,
                        sessionStatistics: feature.selectedConversation?.sessionStatistics,
                        showsSubscriptionQuota: feature.usesSubscription,
                        subscriptionQuota: feature.subscriptionQuota,
                        subscriptionAccount: feature.subscriptionEmail,
                        quotaFailure: feature.quotaFailure,
                        onSetConfig: { feature.setConfigOption($0, value: $1) },
                        commands: feature.selectedConversation?.availableCommands ?? [],
                        showsToolbar: showsToolbar, draftText: $feature.draftText, draftFiles: $feature.draftFiles
                    )
                    .id(draftReset)
                }
            }
        }
    }

    private var conversationTitle: String? {
        guard let id = feature.selectedSessionID else {
            return feature.isCreatingSession ? AgentLocalization.string("New Chat", locale: locale) : nil
        }
        let session = feature.sessions.first { $0.id == id } ?? AgentSessionSummary(id: id)
        return AgentHistoryPresentation.popupTitle(session, metadata: history.metadata[id],
                                                  conversation: feature.conversations[id], locale: locale)
    }

    /// New Chat retains the existing guarded session action.
    private func startNewConversation() {
        guard feature.connectionState == .ready else {
            let reason: String
            if case .failed(let message) = feature.connectionState { reason = message }
            else { reason = AgentConversationError.notConnected.localizedDescription }
            localError = String(format: "Cannot create a new conversation: %@", reason)
            return
        }
        guard !feature.isCreatingSession else { return }
        feature.startNewConversation()
        if feature.isCreatingSession {
            if historyOnly { onFocusEditor?() }
            draftReset += 1
            localError = nil
            showsSearch = false
            searchText = ""
        }
    }

    @ViewBuilder
    private var transcript: some View {
        switch feature.connectionState {
        case .idle, .connecting:
            AgentEmptyStateView(
                systemImage: "sparkles",
                title: "Starting the Agent…",
                message: "The Agent process starts when this panel opens.",
                isBusy: true
            )
            .onAppear {
                if feature.connectionState == .idle { onConnect() }
            }
        case .authenticationRequired:
            AgentEmptyStateView(systemImage: "person.crop.circle", title: "Sign in to Codex",
                message: "Use your local ChatGPT account. No API key or URL is needed.",
                actionTitle: "Sign in with ChatGPT", action: { feature.authenticate() },
                secondaryActionTitle: "Agent Settings", secondaryAction: onOpenSettings)
        case .authenticating:
            AgentEmptyStateView(systemImage: "person.crop.circle", title: "Waiting for ChatGPT sign-in…",
                message: "Complete sign-in in your browser. Your credentials are managed by Codex.",
                actionTitle: "Cancel", action: { Task { await feature.cancelAuthentication() } }, isBusy: true)
        case .failed(let message):
            if feature.selectedConversation?.messages.isEmpty == false {
                AgentTranscriptView(
                    feature: feature, agentName: selectedAgent?.name ?? feature.agentName,
                    agentVersion: feature.agentVersion, agents: agents,
                    onSelectAgent: onSelectAgent, searchText: searchText, onOpenFile: onOpenFile,
                    onRestoreFile: onRestoreFile
                )
                AgentInlineNotice(text: message, status: .error)
                Button("Reconnect", action: onConnect).padding(.bottom, 8)
            } else {
            AgentEmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "The Agent could not start",
                message: message,
                actionTitle: "Retry",
                action: onConnect,
                secondaryActionTitle: "Agent Settings",
                secondaryAction: onOpenSettings
            )
            }
        case .ready:
            AgentTranscriptView(
                feature: feature,
                agentName: selectedAgent?.name ?? feature.agentName,
                agentVersion: feature.agentVersion,
                agents: agents,
                onSelectAgent: onSelectAgent,
                searchText: searchText,
                onOpenFile: onOpenFile,
                onRestoreFile: onRestoreFile
            )
        }
    }

    private func sessionTitle(_ session: AgentSessionSummary) -> String {
        AgentSessionTitle.title(of: AgentSessionSummary(id: session.id, title: history.title(for: session)), locale: locale)
    }
}

struct AgentEmptyStateView: View {
    @Environment(\.locale) private var locale
    let systemImage: String
    let title: LocalizedStringKey
    /// Product localization key or an exact diagnostic supplied by the workflow.
    let message: String
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    var secondaryActionTitle: LocalizedStringKey? = nil
    var secondaryAction: (() -> Void)? = nil
    var isBusy = false
    var bundle: Bundle = .main

    var body: some View {
        VStack(spacing: LitheTheme.Banner.gap) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(LitheTheme.uiFont(size: LitheTheme.Metrics.toolbarIconSize))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            Text(title, bundle: bundle)
                .font(LitheTheme.settingsStrongFont)
                .foregroundStyle(LitheTheme.primaryText)
            Text(AgentLocalization.string(String.LocalizationValue(message), locale: locale, bundle: bundle))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.EditorEmptyState.label)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(LitheSecondaryButtonStyle())
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(LitheSecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentInlineNotice: View {
    @Environment(\.locale) private var locale
    let text: String
    var status: LitheBannerStatus = .warning
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        LitheBanner(status: status) {
            Text(AgentLocalization.message(text, locale: locale)).textSelection(.enabled)
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(.horizontal, AgentComposerMetrics.horizontalInset)
        .padding(.bottom, 4)
    }
}

enum AgentSessionTitle {
    static func title(of session: AgentSessionSummary, locale: Locale = .current) -> String {
        guard let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return AgentLocalization.string("Untitled conversation", locale: locale)
        }
        return title
    }

    static func provisional(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}

/// Observe title notifications directly; AppModel does not relay connection messages.
struct AgentEditorTabTitle: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    var body: some View {
        if let feature = model.agentConversationFeatureIfActive,
           let connection = feature.selectedConnection, let id = feature.selectedAgentID {
            AgentEditorConnectionTitle(connection: connection, history: feature.history(for: id))
        } else { Text("AI Chat").font(LitheTheme.uiFont(size: 13)) }
    }
}

private struct AgentEditorConnectionTitle: View {
    @Environment(\.locale) private var locale
    @ObservedObject var connection: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    var body: some View {
        let id = connection.selectedSessionID
        let session = connection.sessions.first { $0.id == id }
        let title = session.map {
            AgentHistoryPresentation.popupTitle($0, metadata: history.metadata[$0.id], conversation: connection.conversations[$0.id], locale: locale)
        } ?? AgentLocalization.string("New Chat", locale: locale)
        HStack(spacing: 7) {
            AgentBrandIcon(name: connection.agentName, size: 16, style: .brand)
            Text(title).font(LitheTheme.uiFont(size: 13)).lineLimit(1).truncationMode(.tail)
        }
        .help(title)
    }
}
