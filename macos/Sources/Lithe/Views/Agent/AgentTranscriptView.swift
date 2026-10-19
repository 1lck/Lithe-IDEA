import AppKit
import SwiftUI
import LitheAgentConversationModule

/// Groups adjacent ACP tool calls without changing the stored transcript.
/// Prose and user messages end a group, preserving the order of the conversation.
enum AgentTranscriptItem: Identifiable {
    case message(AgentConversationMessage)
    case toolGroup([AgentConversationMessage])
    /// `reply` is the ending Agent message, copied from the footer.
    case turnSummary(AgentTurnStatistics, reply: String?)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .toolGroup(let tools): "tools:\(tools[0].id)"
        case .turnSummary(let turn, _): "turn:\(turn.id)"
        }
    }

    var navigationMessageID: String? {
        switch self {
        case .message(let message): message.id
        case .toolGroup(let tools): tools.first?.id
        case .turnSummary(let turn, _): turn.endingMessageID
        }
    }

    /// Replies whose copy button lives in the turn footer. Search filters the
    /// footers out, so while searching every reply keeps its own button.
    static func repliesCopiedFromFooter(_ turns: [AgentTurnStatistics], searchText: String) -> Set<String> {
        searchText.isEmpty ? Set(turns.compactMap(\.endingMessageID)) : []
    }

    func matches(_ searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        switch self {
        case .message(let message): return message.text.localizedStandardContains(searchText)
        case .toolGroup(let tools): return tools.contains { Self.toolMatches($0, searchText) }
        case .turnSummary: return false
        }
    }

    static func toolMatches(_ message: AgentConversationMessage, _ searchText: String) -> Bool {
        message.text.localizedStandardContains(searchText)
            || message.toolDetails.input?.localizedStandardContains(searchText) == true
            || message.toolDetails.output?.localizedStandardContains(searchText) == true
            || message.toolDetails.content.contains {
                $0.title.localizedStandardContains(searchText) || $0.text.localizedStandardContains(searchText)
            } == true
            || message.toolDetails.locations.contains { $0.path.localizedStandardContains(searchText) } == true
    }

    static func grouped(_ messages: [AgentConversationMessage], turns: [AgentTurnStatistics] = []) -> [Self] {
        var items: [Self] = []
        var tools: [AgentConversationMessage] = []
        let summaries = turns.reduce(into: [String: AgentTurnStatistics]()) { result, turn in
            if let ending = turn.endingMessageID { result[ending] = turn }
        }
        for message in messages {
            if message.role == .tool {
                tools.append(message)
            } else {
                if !tools.isEmpty {
                    items.append(.toolGroup(tools))
                    tools.removeAll(keepingCapacity: true)
                }
                items.append(.message(message))
            }
            if let summary = summaries[message.id] {
                if !tools.isEmpty {
                    items.append(.toolGroup(tools))
                    tools.removeAll(keepingCapacity: true)
                }
                items.append(.turnSummary(summary, reply: message.role == .agent ? message.text : nil))
            }
        }
        if !tools.isEmpty { items.append(.toolGroup(tools)) }
        return items
    }
}

/// Live advisories stay visible without being rendered as an Agent reply.
struct AgentSessionNoticeView: View {
    let notice: AgentSessionNotice
    let onDismiss: () -> Void

    private var status: LitheBannerStatus {
        switch notice.severity {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    var body: some View {
        LitheBanner(status: status, layout: .editor, dismiss: onDismiss) {
            Text(verbatim: notice.title).litheBannerTitle().lineLimit(2).help(notice.title)
            if let detail = notice.detail, !detail.isEmpty { Text(verbatim: detail).lineLimit(3).help(detail) }
        }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("agent-session-notice")
    }
}

/// Message list of the selected conversation, followed by the pending
/// permission request and a summary of this turn's tool activity.
struct AgentTranscriptView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentConnectionModel
    let agentName: String?
    let agentVersion: String?
    let agents: [AgentOption]
    let onSelectAgent: (String) -> Void
    var searchText = ""
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    var onRestoreFile: (AgentFileChange) async throws -> Void = { _ in throw AgentEditRestoreError.unavailable }
    var isEditorLayout = false
    @State private var navigation = AgentTranscriptNavigationState()
    @State private var showsAgentPicker = false
    // A filtered-out row can be destroyed. Keep its preference in the owning
    // transcript view, isolated by session and message, until the actual data goes away.
    @State private var thoughtExpansions: [String: [String: AgentThoughtExpansion]] = [:]

    var body: some View {
        let conversation = feature.selectedConversation
        let sessionID = feature.selectedSessionID
        let messages = conversation?.transcriptMessages ?? []
        // A load replays the whole history one event at a time. Building rows
        // for every intermediate state is quadratic, so rows wait for the replay to end.
        let isReplaying = conversation?.isLoading == true
        let navigationContent = AgentTranscriptNavigationContent(messages: isReplaying ? [] : messages)
        // Only reasoning that is still streaming opens by default.
        let liveThoughtID = conversation?.responseStatus == .thinking && messages.last?.role == .thought
            ? messages.last?.id : nil
        VStack(spacing: 0) {
            if conversation?.isLoading != true && messages.isEmpty && feature.pendingNewConversationPrompt == nil {
                AgentHeroView(agentName: agentName, agentVersion: agentVersion) {
                    showsAgentPicker = true
                }
                .litheDropdown(isPresented: $showsAgentPicker) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(agents) { agent in
                            Button {
                                showsAgentPicker = false
                                onSelectAgent(agent.id)
                            } label: {
                                HStack {
                                    Text(agent.name)
                                    Spacer()
                                    if agent.name == agentName { Image(systemName: "checkmark") }
                                }
                                .frame(minHeight: LitheDropdownMetrics.rowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(LitheDropdownRowStyle(isSelected: agent.name == agentName))
                        }
                    }
                    .padding(LitheDropdownMetrics.popupPadding)
                    .frame(width: 180)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    advisories.modifier(AgentEditorColumn(isEditor: isEditorLayout))
                }
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if conversation?.isLoading == true {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading conversation…").foregroundStyle(LitheTheme.secondaryText)
                                }
                            }
                            // A load replays the whole history one event at a time. Building rows
                            // for every intermediate state is quadratic, so rows wait for the replay to end.
                            if !isReplaying {
                                AgentTranscriptRows(
                                    messages: messages,
                                    completedTurns: conversation?.completedTurns ?? [],
                                    navigation: navigation,
                                    turnByMessageID: navigationContent.turnByMessageID,
                                    searchText: searchText,
                                    liveThoughtID: liveThoughtID,
                                    thoughtExpansions: sessionID.flatMap { thoughtExpansions[$0] } ?? [:],
                                    setThoughtExpansion: { id, value in
                                        guard let sessionID else { return }
                                        thoughtExpansions[sessionID, default: [:]][id] = value
                                    },
                                    onOpenFile: onOpenFile
                                )
                                .equatable()
                            }
                            if feature.selectedSessionID == nil, let prompt = feature.pendingNewConversationPrompt {
                                AgentMessageRow(message: AgentConversationMessage(id: "pending", role: .user, text: prompt))
                                    .id("pending")
                            }
                            if conversation?.isResponding == true || feature.isCreatingSession {
                                AgentResponseStatusRow(
                                    responseStatus: conversation?.responseStatus ?? .preparing,
                                    startedAt: conversation?.activeTurn?.startedAt ?? feature.pendingNewConversationStartedAt,
                                    hasStreamingThought: liveThoughtID != nil,
                                    retryAttempt: conversation?.retryAttempt,
                                    retryMaxAttempts: conversation?.retryMaxAttempts,
                                    isQuiet: conversation?.isQuiet == true,
                                    onContinueWaiting: { feature.continueWaiting() },
                                    onStop: { feature.cancel() }
                                ).id("responding")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .modifier(AgentEditorColumn(isEditor: isEditorLayout))
                        .padding(.horizontal, isEditorLayout ? 0 : 28)
                        .background(AgentTranscriptNavigationViewport(state: navigation))
                        .litheScrollViewChrome(alwaysShowVertical: true)
                        .background(AgentTranscriptScrollAnchor(
                            sessionID: sessionID,
                            enabled: searchText.isEmpty,
                            revision: .init(lastMessageID: messages.last?.id, lastText: messages.last?.text,
                                lastUserMessageID: messages.last(where: { $0.role == .user })?.id,
                                messageCount: messages.count, completedTurns: conversation?.completedTurns.count ?? 0,
                                permissionID: conversation?.permission?.id, isResponding: conversation?.isResponding == true)
                        ))
                    }
                    // Keep both cards owned by the scroll container so its native
                    // bottom-following probe sees the complete reserved inset.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        advisories.modifier(AgentEditorColumn(isEditor: isEditorLayout))
                    }
                    .overlay(alignment: .trailing) {
                        if searchText.isEmpty && !navigationContent.entries.isEmpty {
                            AgentTranscriptNavigationRail(state: navigation, entries: navigationContent.entries) { id in
                                navigation.beginNavigation()
                                reader.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                    .workbenchHoverTooltipScope()
                }
                .id(sessionID)
            }
        }
        .onChange(of: feature.openSessionIDs) { sessionIDs in
            thoughtExpansions = thoughtExpansions.filter { sessionIDs.contains($0.key) }
        }
        .onChange(of: messages.count) { _ in
            // Use unfiltered messages: changing the search must never discard preferences.
            guard let sessionID = feature.selectedSessionID, let preferences = thoughtExpansions[sessionID] else { return }
            let retainedIDs = Set((feature.selectedConversation?.messages ?? []).map(\.id))
            thoughtExpansions[sessionID] = preferences.filter { retainedIDs.contains($0.key) }
        }
    }

    @ViewBuilder private var advisories: some View {
        // Permissions need the user's next action. Keep the advisory in memory
        // until they are answered instead of consuming the whole transcript viewport.
        if let permission = feature.selectedConversation?.permission {
            AgentPermissionCard(permission: permission, answer: { feature.answerPermission(optionID: $0) }, onOpenFile: onOpenFile)
        } else if let sessionID = feature.selectedSessionID, let notice = feature.selectedConversation?.notice {
            AgentSessionNoticeView(notice: notice) { feature.dismissNotice(notice.id, in: sessionID) }
        }
    }
}

/// Transcript rows as a value of the conversation data. The owning view is
/// re-evaluated for every published model change (quota, sessions, statistics);
/// comparing these inputs keeps scrolling from re-diffing every row each time.
private struct AgentTranscriptRows: View, Equatable {
    let messages: [AgentConversationMessage]
    let completedTurns: [AgentTurnStatistics]
    let navigation: AgentTranscriptNavigationState
    let turnByMessageID: [String: String]
    let searchText: String
    let liveThoughtID: String?
    let thoughtExpansions: [String: AgentThoughtExpansion]
    let setThoughtExpansion: (String, AgentThoughtExpansion) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.completedTurns == rhs.completedTurns
            && lhs.searchText == rhs.searchText && lhs.liveThoughtID == rhs.liveThoughtID
            && lhs.thoughtExpansions == rhs.thoughtExpansions
    }

    var body: some View {
        let transcript = AgentTranscriptItem.grouped(messages, turns: completedTurns).filter { $0.matches(searchText) }
        let turnEndingIDs = AgentTranscriptItem.repliesCopiedFromFooter(completedTurns, searchText: searchText)
        if !searchText.isEmpty && transcript.isEmpty {
            Text("No matching messages")
                .foregroundStyle(AgentPanelStyle.secondary)
        }
        ForEach(transcript) { item in
            Group {
                switch item {
                case .message(let message):
                    AgentMessageRow(
                        message: message,
                        isStreamingThought: liveThoughtID == message.id,
                        isSearching: !searchText.isEmpty,
                        endsTurn: turnEndingIDs.contains(message.id),
                        thoughtExpansion: Binding(
                            get: { thoughtExpansions[message.id] ?? AgentThoughtExpansion() },
                            set: { setThoughtExpansion(message.id, $0) }
                        ),
                        onOpenFile: onOpenFile
                    )
                case .toolGroup(let tools):
                    AgentToolGroupView(messages: tools, searchText: searchText, onOpenFile: onOpenFile)
                case .turnSummary(let turn, let reply):
                    AgentTurnStatisticsView(statistics: turn, reply: reply)
                }
            }
            .background(AgentTranscriptNavigationAnchor(state: navigation, turnID: turnByMessageID[item.navigationMessageID ?? ""]))
            .id(item.id)
        }
        .environment(\.openURL, AgentMarkdownLink.openAction(onOpenFile: onOpenFile))
    }
}

/// Compact empty-conversation hint; the composer and this icon both switch agents.
struct AgentHeroView: View {
    @Environment(\.locale) private var locale
    let agentName: String?
    let agentVersion: String?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                AgentBrandIcon(name: agentName, size: LitheTheme.Metrics.toolbarIconSize, style: .brand)
            }
            .litheToolbarIconButton()
            .accessibilityLabel("Switch Agent")
            Text("Start the session by sending a message")
                .font(LitheTheme.uiFont(size: 13))
                .foregroundStyle(AgentPanelStyle.logo)
            Spacer(minLength: 0)
            if let agentVersion, !agentVersion.isEmpty {
                Text("v\(agentVersion)")
                    .font(LitheTheme.uiFont(size: 10, weight: .medium))
                    .foregroundStyle(AgentPanelStyle.secondary)
            }
        }
        .padding(.leading, AgentPanelStyle.iconButtonLeadingInset)
        .padding(.trailing, 20)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .help("Switch Agent")
    }
}

private struct AgentPermissionCard: View {
    @Environment(\.locale) private var locale
    let permission: AgentPermissionPrompt
    let answer: (String?) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(LitheTheme.warning)
                Text("Permission required")
                    .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
            }
            Text(permission.title)
                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !permission.details.isEmpty {
                ScrollView {
                    AgentToolEvidenceView(details: permission.details, onOpenFile: onOpenFile)
                }
                .frame(maxHeight: 180)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(permission.choices) { choice in
                    Button(choice.label) { answer(choice.id) }
                        .buttonStyle(.bordered)
                        .tint(choice.kind?.hasPrefix("reject") == true ? LitheTheme.error : LitheTheme.accent)
                }
                if !permission.choices.contains(where: { $0.kind?.hasPrefix("reject") == true }) {
                    Button("Deny") { answer(nil) }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitheTheme.warning.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct AgentMessageRow: View {
    @Environment(\.locale) private var locale
    let message: AgentConversationMessage
    var isStreamingThought = false
    var isSearching = false
    /// The turn footer below carries this reply's copy button.
    var endsTurn = false
    var thoughtExpansion: Binding<AgentThoughtExpansion> = .constant(AgentThoughtExpansion())
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    @State private var isHovered = false

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .bottom, spacing: 4) {
                Spacer(minLength: 40)
                AgentCopyButton(text: message.text, help: "Copy message")
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                    if let delivery = message.delivery {
                        Group {
                            switch delivery {
                            case .sending: Text("Sending…")
                            case .received: Text("Agent received")
                            case .failed(let reason): Text(AgentLocalization.message(reason, locale: locale)).foregroundStyle(LitheTheme.error)
                            }
                        }
                        .font(LitheTheme.uiFont(size: 10))
                        .foregroundStyle(AgentPanelStyle.secondary)
                    }
                }
                    .font(LitheTheme.uiFont(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LitheTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .onHover { isHovered = $0 }
        case .agent:
            VStack(alignment: .leading, spacing: 2) {
                AgentMarkdownMessage(text: message.text)
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !endsTurn {
                    AgentCopyButton(text: message.text, help: "Copy message")
                        .opacity(isHovered ? 1 : 0)
                        .allowsHitTesting(isHovered)
                }
            }
            .onHover { isHovered = $0 }
        case .thought:
            AgentThoughtRow(text: message.text, isStreaming: isStreamingThought, isSearching: isSearching,
                            expansion: thoughtExpansion)
        case .tool:
            AgentToolGroupView(messages: [message], searchText: "", onOpenFile: onOpenFile)
        }
    }
}
