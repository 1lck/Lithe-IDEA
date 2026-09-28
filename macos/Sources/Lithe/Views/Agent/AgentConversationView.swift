import SwiftUI
import LitheAgentConversationModule

/// Right-docked Agent panel. It always shows the full conversation layout;
/// sending validates the setup first and points to the in-panel settings.
struct AgentConversationView: View {
    @ObservedObject var model: AppModel
    @State private var showsSettings = false

    private var feature: AgentConversationFeatureModel? { model.agentConversationFeatureIfActive }

    var body: some View {
        VStack(spacing: 0) {
            if showsSettings {
                AgentPanelSettingsView(
                    model: model,
                    settings: model.settings,
                    feature: model.agentManagementFeature,
                    onDone: { showsSettings = false }
                )
            } else if let feature, let connection = feature.selectedConnection, let agentID = feature.selectedAgentID {
                AgentConnectionView(
                    feature: connection,
                    history: feature.history(for: agentID),
                    agents: feature.agents,
                    selectedAgentID: feature.selectedAgentID,
                    onSelectAgent: { model.selectAgentConversationAgent($0) },
                    onConnect: { model.connectAgentConversation() },
                    onOpenSettings: { showsSettings = true },
                    onCopySessionID: { model.copyAgentSessionID($0) },
                    onOpenFile: { model.openAgentFile($0) }
                )
                .id(feature.selectedAgentID)
            } else {
                AgentUnconfiguredConversationView(
                    setupError: model.agentConversationSetupError,
                    onOpenSettings: { showsSettings = true }
                )
            }
        }
        .background(AgentPanelStyle.canvas)
        .workbenchHoverTooltipScope()
        .onAppear { model.activateAgentConversation() }
    }
}

/// Title on the left and icon actions on the right, like a chat client's
/// session header: new conversation, history, settings.
private struct AgentPanelHeader<Actions: View>: View {
    let title: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AgentPanelStyle.text)
                .lineLimit(1)
            Spacer(minLength: 12)
            actions
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(AgentPanelStyle.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AgentPanelStyle.border).frame(height: 1)
        }
    }
}

/// The full conversation layout shown before any Agent can run. Typing is
/// allowed; sending explains what is missing.
private struct AgentUnconfiguredConversationView: View {
    let setupError: AgentConversationError?
    let onOpenSettings: () -> Void
    @State private var notice: String?

    var body: some View {
        AgentPanelHeader(title: String(localized: "New conversation")) {
            Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                .buttonStyle(AgentToolbarButtonStyle())
                .help("Agent Settings")
        }
        AgentConversationLayout {
            VStack(spacing: 0) {
                AgentHeroView(agentName: nil, agentVersion: nil, onTap: onOpenSettings)
                AgentActivitySummaryBar(messages: [])
                if let notice {
                    AgentInlineNotice(text: notice, actionTitle: "Open Agent Settings", action: onOpenSettings)
                }
            }
        } composer: {
            AgentComposerView(
                agents: [],
                selectedAgent: nil,
                isResponding: false,
                isBlocked: false,
                onSend: { _, _ in throw setupError ?? .moduleStarting },
                onCancel: {},
                onSelectAgent: { _ in },
                onOpenSettings: onOpenSettings,
                onError: { notice = $0 }
            )
        }
        .onAppear { notice = setupError?.localizedDescription }
        .onChange(of: setupError) { notice = $0?.localizedDescription }
    }
}

private struct AgentConnectionView: View {
    @ObservedObject var feature: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    let agents: [AgentOption]
    let selectedAgentID: String?
    let onSelectAgent: (String) -> Void
    let onConnect: () -> Void
    let onOpenSettings: () -> Void
    let onCopySessionID: (String) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void
    @State private var localError: String?
    @State private var showsSearch = false
    @State private var searchText = ""
    @State private var showsTabs = false
    @State private var showsHistory = false
    @Environment(\.scenePhase) private var scenePhase

    private var shouldPollQuota: Bool {
        feature.usesSubscription && feature.connectionState == .ready && scenePhase == .active && !showsHistory
    }

    private var selectedAgent: AgentOption? { agents.first { $0.id == selectedAgentID } }

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
            AgentPanelHeader(title: headerTitle) {
                Button { showsSearch.toggle(); searchText = "" } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(AgentToolbarButtonStyle())
                    .help("Search conversation")
                Button { feature.startNewConversation() } label: { Image(systemName: "plus") }
                    .buttonStyle(AgentToolbarButtonStyle())
                    .help("New conversation")
                    .disabled(feature.selectedSessionID == nil)
                Button { showsTabs.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(AgentToolbarButtonStyle())
                    .help("Conversation tabs")
                Button { showsHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(AgentToolbarButtonStyle())
                    .help("Conversation history")
                    .accessibilityIdentifier("agent-history-open")
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(AgentToolbarButtonStyle())
                    .help("Agent Settings")
            }
            if showsSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(AgentPanelStyle.secondary)
                    TextField("Search conversation", text: $searchText).textFieldStyle(.plain)
                    Button { showsSearch = false; searchText = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(AgentToolbarButtonStyle())
                        .help("Close search")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: 34)
                .background(AgentPanelStyle.context)
            }
            if showsTabs || feature.openSessionIDs.count > 1
                || (feature.selectedSessionID == nil && !feature.openSessionIDs.isEmpty) {
                sessionTabs
            }
            AgentConversationLayout {
                VStack(spacing: 0) {
                    transcript
                    if let error = localError ?? feature.selectedConversation?.configurationError ?? feature.selectedConversation?.errorMessage ?? feature.errorMessage {
                        AgentInlineNotice(text: error)
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
                    configOptions: feature.selectedConversation?.configOptions ?? [],
                    sessionID: feature.selectedSessionID,
                    isConfiguring: feature.selectedConversation?.pendingConfigToken != nil,
                    isCancelling: feature.selectedConversation?.isCancelling == true,
                    contextUsage: feature.selectedConversation?.contextUsage,
                    showsSubscriptionQuota: feature.usesSubscription,
                    subscriptionQuota: feature.subscriptionQuota,
                    subscriptionAccount: feature.subscriptionEmail,
                    quotaFailure: feature.quotaFailure,
                    onSetConfig: { feature.setConfigOption($0, value: $1) }
                )
            }
        }
    }

    private var sessionTabs: some View {
        AgentSessionTabStrip(
            tabs: feature.openSessionIDs.map { id in
                AgentSessionTabItem(
                    id: id,
                    title: feature.sessions.first { $0.id == id }.map(sessionTitle) ?? String(localized: "Untitled conversation"),
                    isSelected: feature.selectedSessionID == id,
                    isBusy: feature.conversations[id]?.isResponding == true,
                    needsAttention: feature.conversations[id]?.permission != nil
                )
            },
            showsNewTab: feature.selectedSessionID == nil,
            isNewTabBusy: feature.isCreatingSession,
            newTabTitle: feature.pendingNewConversationPrompt.map(AgentSessionTitle.provisional),
            onSelect: { feature.selectSession($0) },
            onClose: { feature.closeConversation($0) },
            onNew: { feature.startNewConversation() }
        )
    }

    @ViewBuilder
    private var transcript: some View {
        switch feature.connectionState {
        case .idle, .connecting:
            AgentEmptyStateView(
                systemImage: "sparkles",
                title: "Starting the Agent…",
                message: String(localized: "The Agent process starts when this panel opens."),
                isBusy: true
            )
            .onAppear {
                if feature.connectionState == .idle { onConnect() }
            }
        case .authenticationRequired:
            AgentEmptyStateView(systemImage: "person.crop.circle", title: "Sign in to Codex",
                message: String(localized: "Use your local ChatGPT account. No API key or URL is needed."),
                actionTitle: "Sign in with ChatGPT", action: { feature.authenticate() },
                secondaryActionTitle: "Agent Settings", secondaryAction: onOpenSettings)
        case .authenticating:
            AgentEmptyStateView(systemImage: "person.crop.circle", title: "Waiting for ChatGPT sign-in…",
                message: String(localized: "Complete sign-in in your browser. Your credentials are managed by Codex."),
                actionTitle: "Cancel", action: { Task { await feature.cancelAuthentication() } }, isBusy: true)
        case .failed(let message):
            if feature.selectedConversation?.messages.isEmpty == false {
                AgentTranscriptView(
                    feature: feature, agentName: selectedAgent?.name ?? feature.agentName,
                    agentVersion: feature.agentVersion, agents: agents,
                    onSelectAgent: onSelectAgent, searchText: searchText, onOpenFile: onOpenFile
                )
                AgentInlineNotice(text: message)
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
                onOpenFile: onOpenFile
            )
        }
    }

    private var headerTitle: String {
        guard let id = feature.selectedSessionID else { return String(localized: "New conversation") }
        return feature.sessions.first { $0.id == id }.map(sessionTitle) ?? String(localized: "Untitled conversation")
    }

    private func sessionTitle(_ session: AgentSessionSummary) -> String {
        AgentSessionTitle.title(of: AgentSessionSummary(id: session.id, title: history.title(for: session)))
    }
}

struct AgentSessionTabItem: Identifiable, Equatable {
    let id: String
    let title: String
    let isSelected: Bool
    let isBusy: Bool
    let needsAttention: Bool
}

/// Agent badge on the left, then one tab per open conversation and a "new" button.
/// One tab per open conversation and a "new" button.
struct AgentSessionTabStrip: View {
    let tabs: [AgentSessionTabItem]
    let showsNewTab: Bool
    let isNewTabBusy: Bool
    var newTabTitle: String? = nil
    let onSelect: (String) -> Void
    let onClose: (String) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        AgentSessionTab(
                            title: tab.title,
                            isSelected: tab.isSelected,
                            isBusy: tab.isBusy,
                            needsAttention: tab.needsAttention,
                            select: { onSelect(tab.id) },
                            close: { onClose(tab.id) }
                        )
                    }
                    if showsNewTab {
                        AgentSessionTab(
                            title: newTabTitle ?? String(localized: "New conversation"),
                            isSelected: true,
                            isBusy: isNewTabBusy,
                            needsAttention: false,
                            select: {},
                            close: nil
                        )
                    }
                }
            }
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("New conversation")
            .disabled(showsNewTab)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(LitheTheme.toolHeaderInactive)
    }
}

private struct AgentSessionTab: View {
    let title: String
    let isSelected: Bool
    let isBusy: Bool
    let needsAttention: Bool
    let select: () -> Void
    let close: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView().controlSize(.mini)
            } else if needsAttention {
                Circle().fill(LitheTheme.warning).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: 140)
            if let close, isHovering || isSelected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .lithePointer()
                .foregroundStyle(LitheTheme.tertiaryText)
                .help("Close conversation")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
        .background(
            RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius)
                .fill(isSelected ? LitheTheme.activeTabBackground : (isHovering ? LitheTheme.hoverBackground : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

struct AgentEmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    /// Already localized; callers format dynamic values into it.
    let message: String
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    var secondaryActionTitle: LocalizedStringKey? = nil
    var secondaryAction: (() -> Void)? = nil
    var isBusy = false

    var body: some View {
        VStack(spacing: 10) {
            if isBusy {
                ProgressView().controlSize(.regular)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LitheTheme.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(LitheTheme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 26, fontSize: 12))
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 26, fontSize: 12))
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentInlineNotice: View {
    let text: String
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(LitheTheme.warning)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 24, fontSize: 11.5))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(10)
        .background(LitheTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.warning.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

enum AgentSessionTitle {
    static func title(of session: AgentSessionSummary) -> String {
        guard let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return String(localized: "Untitled conversation")
        }
        return title
    }

    static func provisional(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }
}
