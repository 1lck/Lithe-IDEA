import AppKit
import SwiftUI
import LitheAgentConversationModule

/// A turn's intermediate text and tools share one disclosure. The trailing
/// Agent reply stays outside it; the stored transcript and event order stay intact.
enum AgentTranscriptItem: Identifiable {
    case message(AgentConversationMessage)
    case processGroup([AgentConversationMessage])
    case toolGroup([AgentConversationMessage])
    /// `reply` is the ending Agent message, copied from the footer.
    case turnSummary(AgentTurnStatistics, reply: String?)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .processGroup(let messages): "process:\(messages[0].id)"
        case .toolGroup(let tools): "tools:\(tools[0].id)"
        case .turnSummary(let turn, _): "turn:\(turn.id)"
        }
    }

    var navigationMessageID: String? {
        switch self {
        case .message(let message): message.id
        case .processGroup(let messages): messages.first?.id
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
        case .message(let message):
            return message.text.localizedStandardContains(searchText)
                || message.plan?.entries.contains { $0.content.localizedStandardContains(searchText) } == true
                || message.shownDesktopCard?.searchableText.localizedStandardContains(searchText) == true
        case .processGroup(let messages): return messages.contains {
            $0.role == .tool ? Self.toolMatches($0, searchText) : $0.text.localizedStandardContains(searchText)
        }
        case .toolGroup(let tools): return tools.contains { Self.toolMatches($0, searchText) }
        case .turnSummary: return false
        }
    }

    /// Suggested replies answer only the latest turn; Desktop drops them once the conversation moves on.
    func isStaleNextStep(lastMessageID: String?, isResponding: Bool) -> Bool {
        guard case .message(let message) = self, case .nextStep = message.shownDesktopCard else { return false }
        return isResponding || message.id != lastMessageID
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
        var pending: [AgentConversationMessage] = []
        let summaries = turns.reduce(into: [String: AgentTurnStatistics]()) { result, turn in
            if let ending = turn.endingMessageID { result[ending] = turn }
        }
        func flush() {
            // ACP has no final/commentary role. Only text after the last thought
            // or tool is presented as the reply; earlier prose is process narration.
            if let lastActivity = pending.lastIndex(where: { $0.role != .agent }) {
                let process = Array(pending[...lastActivity])
                // Notices that triggered no thinking or tool use have no process to join.
                if process.allSatisfy(Self.isQuietNotification) {
                    items += process.map(Self.message)
                } else {
                    items.append(.processGroup(process))
                }
                items += pending.dropFirst(lastActivity + 1).map(Self.message)
            } else {
                items += pending.map(Self.message)
            }
            pending.removeAll(keepingCapacity: true)
        }
        for message in messages {
            if message.role == .user, case .markup(let entries) = AgentUserMessagePresentation.of(message), entries.isEmpty {
                // Model-only reminders and caveats are not conversation.
                continue
            }
            if case .nextStep = message.shownDesktopCard {
                // Suggested replies follow the turn they end, after its summary.
            } else if message.plan != nil || message.shownDesktopCard != nil {
                // A replayed plan snapshot is what the Agent reported at that point;
                // it stays on the transcript like Claude Desktop's checklist.
                // Desktop shows its chapters, tasks and pull requests the same way.
                flush()
                items.append(.message(message))
            } else if Self.isQuietNotification(message) {
                // A finished background task wakes the Agent for a follow-up turn.
                // The notice joins that turn's collapsed process instead of
                // interrupting the transcript between two replies.
                pending.append(message)
            } else if message.role == .user {
                flush()
                items.append(.message(message))
            } else if message.role == .tool || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pending.append(message)
            }
            if let summary = summaries[message.id] {
                let reply = pending.last.flatMap { $0.role == .agent ? $0.text : nil }
                flush()
                items.append(.turnSummary(summary, reply: reply))
            }
            if case .nextStep = message.shownDesktopCard {
                flush()
                items.append(.message(message))
            }
        }
        flush()
        return items
    }

    /// A successful background-task notice: protocol markup that needs no attention.
    /// Failures stay on the transcript where the user can see them.
    static func isQuietNotification(_ message: AgentConversationMessage) -> Bool {
        guard message.role == .user, case .markup(let entries) = AgentUserMessagePresentation.of(message), !entries.isEmpty else { return false }
        return entries.allSatisfy {
            if case .taskNotification(let notification) = $0 { return !notification.isFailure }
            return false
        }
    }

    /// Within an expanded process, keep prose in order and combine adjacent tools.
    static func processContents(_ messages: [AgentConversationMessage]) -> [Self] {
        var items: [Self] = []
        var tools: [AgentConversationMessage] = []
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
        }
        if !tools.isEmpty { items.append(.toolGroup(tools)) }
        return items
    }
}

/// A conversation of any size opens on its latest items; earlier ones are
/// built only when asked for. Laying out every row of a long history before
/// the first paint made opening a large conversation take seconds.
enum AgentTranscriptWindow {
    static let initialItems = 48
    static let pageItems = 96

    /// Smallest limit that keeps `anchorID` and everything after it in the window.
    static func limit(including anchorID: String, in items: [AgentTranscriptItem], current: Int) -> Int {
        guard let index = items.firstIndex(where: { $0.id == anchorID || $0.navigationMessageID == anchorID }) else { return current }
        return max(current, items.count - index + 2)
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
    // A reference the rows share; only the overlay observes it, so opening an image does not re-evaluate this view.
    @State private var imageViewer = AgentImageViewerState()
    // A filtered-out row can be destroyed. Keep its preference in the owning
    // transcript view, isolated by session and message, until the actual data goes away.
    @State private var thoughtExpansions: [String: [String: AgentThoughtExpansion]] = [:]
    /// How many trailing transcript items each session currently builds.
    @State private var windowLimits: [String: Int] = [:]

    var body: some View {
        let conversation = feature.selectedConversation
        let sessionID = feature.selectedSessionID
        let messages = conversation?.transcriptMessages ?? []
        // A load replays the whole history one event at a time. Building rows
        // for every intermediate state is quadratic, so rows wait for the replay to end.
        let isReplaying = conversation?.isLoading == true
        let navigationContent = AgentTranscriptNavigationContent(messages: isReplaying ? [] : messages)
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
                                    liveProcessMessageID: conversation?.isResponding == true ? messages.last?.id : nil,
                                    isEditorLayout: isEditorLayout,
                                    limit: searchText.isEmpty ? (sessionID.flatMap { windowLimits[$0] } ?? AgentTranscriptWindow.initialItems) : .max,
                                    showEarlier: { anchorID in
                                        guard let sessionID else { return }
                                        windowLimits[sessionID, default: AgentTranscriptWindow.initialItems] += AgentTranscriptWindow.pageItems
                                        // The new rows sit above the viewport; keep the reader where it was.
                                        // Scroll again after layout resolves the newly inserted rows.
                                        reader.scrollTo(anchorID, anchor: .top)
                                        DispatchQueue.main.async { reader.scrollTo(anchorID, anchor: .top) }
                                    },
                                    thoughtExpansions: sessionID.flatMap { thoughtExpansions[$0] } ?? [:],
                                    setThoughtExpansion: { id, value in
                                        guard let sessionID else { return }
                                        thoughtExpansions[sessionID, default: [:]][id] = value
                                    },
                                    onOpenFile: onOpenFile,
                                    onDesktopDraft: { text, inNewConversation in
                                        feature.fillDraft(text, inNewConversation: inNewConversation)
                                    }
                                )
                                .equatable()
                            }
                            if feature.selectedSessionID == nil, let prompt = feature.pendingNewConversationPrompt {
                                AgentMessageRow(message: AgentConversationMessage(id: "pending", role: .user, text: prompt), isEditorLayout: isEditorLayout)
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
                        // Only the trailing navigation rail needs the extra gutter.
                        .padding(.trailing, isEditorLayout ? 0 : 28)
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
                                if let sessionID {
                                    let items = AgentTranscriptItem.grouped(messages, turns: conversation?.completedTurns ?? [])
                                    let current = windowLimits[sessionID] ?? AgentTranscriptWindow.initialItems
                                    let needed = AgentTranscriptWindow.limit(including: id, in: items, current: current)
                                    if needed > current {
                                        windowLimits[sessionID] = needed
                                        // The target does not exist until this update inserts it.
                                        DispatchQueue.main.async { reader.scrollTo(id, anchor: .top) }
                                    }
                                }
                                reader.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                    .workbenchHoverTooltipScope()
                }
                .id(sessionID)
            }
        }
        .environment(\.agentImageViewer, imageViewer)
        .overlay { AgentImageViewerOverlay(state: imageViewer) }
        .onChange(of: feature.openSessionIDs) { sessionIDs in
            thoughtExpansions = thoughtExpansions.filter { sessionIDs.contains($0.key) }
            windowLimits = windowLimits.filter { sessionIDs.contains($0.key) }
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

/// Only this overlay observes the viewer, so opening an image leaves the rows untouched.
private struct AgentImageViewerOverlay: View {
    @ObservedObject var state: AgentImageViewerState

    var body: some View {
        if let gallery = state.gallery {
            AgentImageViewer(state: state, gallery: gallery)
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
    let liveProcessMessageID: String?
    let isEditorLayout: Bool
    let limit: Int
    let showEarlier: (String) -> Void
    let thoughtExpansions: [String: AgentThoughtExpansion]
    let setThoughtExpansion: (String, AgentThoughtExpansion) -> Void
    let onOpenFile: (AgentToolDetails.Location) -> Void
    let onDesktopDraft: (String, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messages == rhs.messages && lhs.completedTurns == rhs.completedTurns
            && lhs.searchText == rhs.searchText && lhs.liveThoughtID == rhs.liveThoughtID && lhs.limit == rhs.limit
            && lhs.liveProcessMessageID == rhs.liveProcessMessageID
            && lhs.isEditorLayout == rhs.isEditorLayout
            && lhs.thoughtExpansions == rhs.thoughtExpansions
    }

    var body: some View {
        let matching = AgentTranscriptItem.grouped(messages, turns: completedTurns).filter {
            $0.matches(searchText) && !$0.isStaleNextStep(lastMessageID: messages.last?.id, isResponding: liveProcessMessageID != nil)
        }
        let hidden = limit < matching.count ? matching.count - limit : 0
        let transcript = hidden > 0 ? Array(matching[hidden...]) : matching
        let turnEndingIDs = AgentTranscriptItem.repliesCopiedFromFooter(completedTurns, searchText: searchText)
        if !searchText.isEmpty && transcript.isEmpty {
            Text("No matching messages")
                .foregroundStyle(AgentPanelStyle.secondary)
        }
        if hidden > 0, let first = transcript.first {
            AgentShowEarlierRow(hiddenCount: hidden) { showEarlier(first.id) }
        }
        ForEach(transcript) { item in
            Group {
                switch item {
                case .message(let message) where message.plan != nil:
                    AgentPlanView(plan: message.plan!, isResponding: false, horizontalInset: 0)
                case .message(let message) where message.shownDesktopCard != nil:
                    AgentDesktopCardView(card: message.shownDesktopCard!, onDraft: onDesktopDraft)
                case .message(let message):
                    AgentMessageRow(
                        message: message,
                        isStreamingThought: liveThoughtID == message.id,
                        isSearching: !searchText.isEmpty,
                        endsTurn: turnEndingIDs.contains(message.id),
                        isEditorLayout: isEditorLayout,
                        thoughtExpansion: Binding(
                            get: { thoughtExpansions[message.id] ?? AgentThoughtExpansion() },
                            set: { setThoughtExpansion(message.id, $0) }
                        ),
                        onOpenFile: onOpenFile
                    )
                case .processGroup(let messages):
                    AgentProcessGroupView(
                        messages: messages,
                        isStreaming: messages.contains { $0.id == liveProcessMessageID },
                        searchText: searchText,
                        expansion: Binding(
                            get: { thoughtExpansions[messages[0].id] ?? AgentThoughtExpansion() },
                            set: { setThoughtExpansion(messages[0].id, $0) }
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

/// Row that reveals the items outside the transcript window.
private struct AgentShowEarlierRow: View {
    let hiddenCount: Int
    let onShow: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: onShow) {
            Text(String(format: AgentLocalization.string("Show %lld earlier items", locale: locale), hiddenCount))
                .font(LitheTheme.uiFont(size: 12))
                .foregroundStyle(AgentPanelStyle.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(AgentPanelStyle.context, in: Capsule())
        }
        .buttonStyle(.litheNoPress)
        .lithePointer()
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("agent-transcript-show-earlier")
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
            VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) {
                ForEach(permission.choices) { choice in
                    Button(choice.label, role: choice.kind?.hasPrefix("reject") == true ? .destructive : nil) { answer(choice.id) }
                        .buttonStyle(LitheActionButtonStyle())
                }
                if !permission.choices.contains(where: { $0.kind?.hasPrefix("reject") == true }) {
                    Button("Deny", role: .destructive) { answer(nil) }
                        .buttonStyle(LitheActionButtonStyle())
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
    /// Editor tab: Claude Desktop's neutral bubble instead of the panel's tinted one.
    var isEditorLayout = false
    var thoughtExpansion: Binding<AgentThoughtExpansion> = .constant(AgentThoughtExpansion())
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    @State private var isHovered = false

    var body: some View {
        switch message.role {
        case .user:
            if case .markup(let entries) = AgentUserMessagePresentation.of(message) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        AgentClaudeCodeEntryRow(entry: entry)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                userBubble
            }
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

    /// Attached image files and replayed pictures show as thumbnails that open
    /// the viewer; the text keeps the user's words and non-image attachments.
    private var userBubble: some View {
        var content = AgentUserMessageContent.parse("")
        if case .bubble(let parsed) = AgentUserMessagePresentation.of(message) { content = parsed }
        let images = (message.images + content.images).uniquedByID
        return HStack(alignment: .bottom, spacing: 4) {
            Spacer(minLength: 40)
            if !content.text.isEmpty {
                AgentCopyButton(text: content.text, help: "Copy message")
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
            VStack(alignment: .trailing, spacing: 6) {
                if !images.isEmpty { AgentUserImages(images: images, hiddenCount: content.hiddenImageCount) }
                if !content.text.isEmpty { Text(content.text) }
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
                .font(LitheTheme.uiFont(size: isEditorLayout ? 14 : 13))
                .textSelection(.enabled)
                .padding(.horizontal, isEditorLayout ? 14 : 12)
                .padding(.vertical, isEditorLayout ? 10 : 8)
                .background(isEditorLayout ? AnyShapeStyle(AgentPanelStyle.context) : AnyShapeStyle(LitheTheme.accent.opacity(0.18)),
                            in: RoundedRectangle(cornerRadius: isEditorLayout ? 16 : 10))
        }
        .onHover { isHovered = $0 }
    }
}

/// How a user message is drawn, parsed once. The regex scans touch the whole text,
/// and rows re-evaluate on hover and while the transcript streams, so the result is cached.
private enum AgentUserMessagePresentation {
    case markup([AgentClaudeCodeEntry])
    case bubble(AgentUserMessageContent)

    private final class Box { let value: AgentUserMessagePresentation; init(_ value: AgentUserMessagePresentation) { self.value = value } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()

    static func of(_ message: AgentConversationMessage) -> Self {
        let key = "\(message.id)#\(message.text.utf8.count)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value: Self
        if let entries = AgentClaudeCodeMarkup.parse(message.text) {
            value = .markup(entries)
        } else {
            value = .bubble(AgentUserMessageContent.parse(AgentClaudeCodeMarkup.removingModelOnlyBlocks(message.text)))
        }
        cache.setObject(Box(value), forKey: key)
        return value
    }
}

extension AgentTaskNotification {
    private static let shellSummary = try! NSRegularExpression(
        pattern: "^Background command \"(.+)\" (?:completed|failed) \\(exit code (-?\\d+)\\)$")

    /// One line for the transcript. Claude Code words shell-task summaries in
    /// English (`Background command "…" completed (exit code 0)`); those are
    /// shown in the interface language, and any other summary is kept verbatim.
    func displayText(locale: Locale) -> String {
        guard let summary else {
            return AgentLocalization.string(isFailure ? "Background task ended" : "Background task finished", locale: locale)
        }
        guard let match = Self.shellSummary.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
              let name = Range(match.range(at: 1), in: summary), let code = Range(match.range(at: 2), in: summary) else {
            return summary
        }
        if summary[code] == "0" {
            return String(format: AgentLocalization.string("Background command finished: %@", locale: locale), String(summary[name]))
        }
        return String(format: AgentLocalization.string("Background command ended (exit code %@): %@", locale: locale),
                      String(summary[code]), String(summary[name]))
    }
}

/// Claude Code's own markup in a user message, shown as a quiet status line or output block.
struct AgentClaudeCodeEntryRow: View {
    @Environment(\.locale) private var locale
    let entry: AgentClaudeCodeEntry

    var body: some View {
        switch entry {
        case .taskNotification(let notification):
            let failed = notification.isFailure
            line(systemImage: failed ? "exclamationmark.circle" : "checkmark.circle", isError: failed,
                 text: notification.displayText(locale: locale))
                .help(notification.outputFile ?? "")
                .accessibilityIdentifier("agent-task-notification")
        case .command(let name, let arguments):
            line(systemImage: "chevron.right.square", isError: false,
                 text: [name, arguments].compactMap { $0 }.joined(separator: " "), monospaced: true)
                .accessibilityIdentifier("agent-command-entry")
        case .shell(let command):
            line(systemImage: "terminal", isError: false, text: command, monospaced: true)
                .accessibilityIdentifier("agent-shell-entry")
        case .output(let text, let isError):
            Text(verbatim: text)
                .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                .foregroundStyle(isError ? LitheTheme.error : LitheTheme.secondaryText)
                .lineLimit(12)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LitheTheme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("agent-command-output")
        case .interrupted(let text):
            line(systemImage: "pause.circle", isError: false, text: text)
                .accessibilityIdentifier("agent-interrupted-entry")
        case .summary(let text, let tools):
            AgentCollapsedBlock(title: AgentLocalization.string("Conversation continued from a summary", locale: locale),
                                systemImage: "text.append", detail: tools, text: text)
                .accessibilityIdentifier("agent-summary-entry")
        case .skill(let name, let body):
            AgentCollapsedBlock(title: String(format: AgentLocalization.string("Skill loaded: %@", locale: locale), name),
                                systemImage: "sparkles", detail: nil, text: body)
                .accessibilityIdentifier("agent-skill-entry")
        case .context(let name, let body):
            AgentCollapsedBlock(title: String(format: AgentLocalization.string("Context: %@", locale: locale), name),
                                systemImage: "tray.full", detail: nil, text: body)
                .accessibilityIdentifier("agent-context-entry")
        }
    }

    private func line(systemImage: String, isError: Bool, text: String, monospaced: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(LitheTheme.uiFont(size: 11))
                .foregroundStyle(isError ? LitheTheme.error : LitheTheme.tertiaryText)
            Text(verbatim: text)
                .font(monospaced ? LitheTheme.uiFont(size: 12, design: .monospaced) : LitheTheme.uiFont(size: 12.5))
                .lineLimit(2)
        }
        .foregroundStyle(LitheTheme.secondaryText)
        .textSelection(.enabled)
    }
}

/// Long Claude Code-owned text (recap, skill instructions, host context) behind a one-line header.
private struct AgentCollapsedBlock: View {
    let title: String
    let systemImage: String
    let detail: String?
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    Text(verbatim: title).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .font(LitheTheme.uiFont(size: 12.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail {
                        Text(verbatim: detail)
                            .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    AgentMarkdownMessage(text: text, size: 12)
                        .equatable()
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LitheTheme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
            }
        }
    }
}
