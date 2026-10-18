import SwiftUI
import LitheAgentConversationModule
import LitheCoreContracts

enum AgentHistoryFilter: String, CaseIterable {
    case all, favorites, removed
    var title: LocalizedStringKey { LocalizedStringKey(menuTitle) }
    var menuTitle: String {
        switch self {
        case .all: "All conversations"
        case .favorites: "Favorites"
        case .removed: "Removed conversations"
        }
    }
}

enum AgentHistoryPresentation {
    enum EmptyState { case loading, incomplete, noMatches, noHistory }

    /// A partial upstream scan cannot establish that history or a search is empty.
    static func emptyState(isRefreshing: Bool, query: String, isArchivedHistoryComplete: Bool) -> EmptyState {
        if isRefreshing { return .loading }
        if !isArchivedHistoryComplete { return .incomplete }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noHistory : .noMatches
    }

    static func popupTitle(_ session: AgentSessionSummary, metadata: AgentHistoryMetadata?,
                           conversation: AgentConversation?, locale: Locale = .current) -> String {
        if let title = metadata?.title ?? session.title { return title }
        if let prompt = conversation?.transcriptMessages.first(where: { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return AgentSessionTitle.provisional(prompt.text)
        }
        if let conversation, conversation.isAttached, !conversation.isLoading, conversation.transcriptMessages.isEmpty {
            return AgentLocalization.string("New Chat", locale: locale)
        }
        return AgentLocalization.string("Untitled conversation", locale: locale)
    }

    static func sessions(_ sessions: [AgentSessionSummary], metadata: [String: AgentHistoryMetadata],
                         query: String, filter: AgentHistoryFilter) -> [AgentSessionSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            let entry = metadata[session.id] ?? AgentHistoryMetadata()
            guard entry.isHidden == (filter == .removed), filter != .favorites || entry.isFavorite else { return false }
            let title = entry.title ?? session.title ?? ""
            return query.isEmpty || title.localizedStandardContains(query) || session.id.localizedStandardContains(query)
        }.map { (session: $0, date: date($0.updatedAt)) }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast) }
            return lhs.session.id < rhs.session.id
        }.map(\.session)
    }

    static func popupSessions(_ sessions: [AgentSessionSummary], openSessionIDs: [String],
                              metadata: [String: AgentHistoryMetadata], selectedSessionID: String? = nil, locale: Locale = .current) -> [AgentSessionSummary] {
        let listed = Self.sessions(sessions, metadata: metadata, query: "", filter: .all)
        let knownIDs = Set(sessions.map(\.id))
        let pending = openSessionIDs.reversed().filter {
            !knownIDs.contains($0) && metadata[$0]?.isHidden != true
        }.map { AgentSessionSummary(id: $0, title: AgentLocalization.string("New Chat", locale: locale)) }
        let rows = pending + listed
        return rows.filter { $0.id == selectedSessionID } + rows.filter { $0.id != selectedSessionID }
    }

    /// The original management page also includes open chats that the Agent has
    /// not listed yet. Titles are derived for display without changing its history.
    static func managementSessions(_ sessions: [AgentSessionSummary], openSessionIDs: [String],
                                   conversations: [String: AgentConversation], archivedSessionIDs: Set<String> = [],
                                   metadata: [String: AgentHistoryMetadata],
                                   query: String, filter: AgentHistoryFilter, locale: Locale = .current) -> [AgentSessionSummary] {
        let activeSessions = sessions.filter { !archivedSessionIDs.contains($0.id) }
        let activeOpenIDs = openSessionIDs.filter { !archivedSessionIDs.contains($0) }
        let listedIDs = Set(activeSessions.map(\.id))
        let rows = popupSessions(activeSessions, openSessionIDs: activeOpenIDs, metadata: [:], locale: locale).map { session in
            var row = session
            if !listedIDs.contains(session.id), let prompt = conversations[session.id]?.transcriptMessages.first(where: {
                $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                row.title = AgentSessionTitle.provisional(prompt.text)
            }
            row.title = popupTitle(row, metadata: metadata[session.id], conversation: conversations[session.id], locale: locale)
            return row
        }
        return Self.sessions(rows, metadata: metadata, query: query, filter: filter)
    }

    /// Value-type styles: creating an `ISO8601DateFormatter` per call made
    /// sorting and every history row render measurably slow.
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let dateStyle = Date.ISO8601FormatStyle()

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? fractionalDateStyle.parse(value)) ?? (try? dateStyle.parse(value))
    }

    static func messageCount(_ conversation: AgentConversation?) -> Int? {
        guard let conversation, !conversation.isLoading,
              conversation.isAttached || !conversation.transcriptMessages.isEmpty else { return nil }
        return conversation.transcriptMessages.filter { $0.role == .user || $0.role == .agent }.count
    }
}

/// In-panel history page: annotations stay in Lithe, transcripts stay with the Agent.
struct AgentHistoryView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    let agentName: String?
    let onBack: () -> Void
    let onCopySessionID: (String) -> Void
    let onSelect: (String) -> Void
    let onReconnect: () -> Void
    @State private var historyListActive = false
    @State private var query = ""
    @State private var filter = AgentHistoryFilter.all
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var editingID: String?
    @State private var editingTitle = ""
    @State private var copiedID: String?
    @State private var pendingRemovalIDs: [String]?
    /// The user's explicit toggle; a new search falls back to the default.
    @State private var archivedExpansion: Bool?
    @State private var pendingUnarchiveID: String?
    /// Opens a conversation once its unarchive completes. Leaving the page
    /// cancels only the navigation; the confirmed upstream restore still finishes.
    @State private var unarchiveOpenTask: Task<Void, Never>?

    private var sessions: [AgentSessionSummary] {
        AgentHistoryPresentation.managementSessions(feature.sessions, openSessionIDs: feature.openSessionIDs,
            conversations: feature.conversations, archivedSessionIDs: Set(feature.archivedSessions.map(\.id)),
            metadata: history.metadata, query: query, filter: filter, locale: locale)
    }
    /// Searched and filtered like active rows; local restoration never loads a transcript.
    private var archived: [AgentSessionSummary] {
        AgentHistoryPresentation.sessions(feature.archivedSessions, metadata: history.metadata, query: query, filter: filter)
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Collapsed by default; a search that matches archived rows reveals them.
    private var isArchivedExpanded: Bool { archivedExpansion ?? (isSearching && !archived.isEmpty) }
    private var visibleIDs: [String] { sessions.map(\.id) }
    private var selected: [String] { visibleIDs.filter(selectedIDs.contains) }

    var body: some View {
        VStack(spacing: 0) {
            LitheToolWindowHeader(title: "Conversation history", usesWorkbenchSurface: true) {
                Button(action: onBack) {
                    HStack(spacing: LitheTheme.Banner.gap) {
                        LitheSystemIcon(systemImage: "arrow.left", size: LitheTheme.Metrics.toolbarIconSize)
                        Text("Back")
                    }
                }
                .litheToolbarIconButton(isIconOnly: false)
                .accessibilityIdentifier("agent-history-back")
            }
            divider
            toolbar
            divider
            if let error = history.errorMessage ?? feature.historyError ?? feature.archivedHistoryError {
                AgentInlineNotice(text: error, status: .error)
                    .padding(.top, 8)
            }
            if case .failed(let message) = feature.connectionState {
                AgentInlineNotice(text: message, status: .error, actionTitle: "Reconnect", action: onReconnect)
                    .padding(.top, 8)
            }
            if history.isExporting {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("Exporting conversations…")
                    Spacer()
                    Button("Cancel") { history.cancelExport() }.buttonStyle(.litheNoPress)
                }.font(LitheTheme.uiFont(size: 12)).padding(12)
            }
            if !feature.isArchivedHistoryComplete {
                Text("Only the most recent archived conversations are shown.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .accessibilityIdentifier("agent-history-archive-incomplete")
            }
            if sessions.isEmpty && archived.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in row(session) }
                        if !archived.isEmpty { archivedSection }
                    }
                }
                .background(LitheToolWindowActivityTracker(isActive: $historyListActive))
            }
        }
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .onAppear { feature.refreshSessions() }
        .onChange(of: visibleIDs) { selectedIDs.formIntersection($0) }
        .onChange(of: query) { _ in archivedExpansion = nil }
        .alert("Confirm deletion", isPresented: Binding(
            get: { pendingRemovalIDs != nil },
            set: { if !$0 { pendingRemovalIDs = nil } }
        ), presenting: pendingRemovalIDs) { ids in
            Button("Cancel", role: .cancel) { pendingRemovalIDs = nil }
            Button("Delete", role: .destructive) {
                if history.setHidden(ids, true) { selectedIDs.subtract(ids) }
            }
        } message: { ids in
            Text(String(format: AgentLocalization.string("Remove %d conversation(s) from history? You can restore them from Removed conversations. The Agent's original records will be kept.", locale: locale), ids.count))
        }
        .alert("Unarchive this conversation?", isPresented: Binding(
            get: { pendingUnarchiveID != nil },
            set: { if !$0 { pendingUnarchiveID = nil } }
        ), presenting: pendingUnarchiveID) { id in
            Button("Cancel", role: .cancel) { pendingUnarchiveID = nil }
            Button("Unarchive and open") {
                pendingUnarchiveID = nil
                unarchiveOpenTask?.cancel()
                unarchiveOpenTask = Task {
                    // Failures are shown through the model's archived history error.
                    let canOpen = (try? await feature.unarchiveSession(id)) == true
                    if canOpen, !Task.isCancelled { onSelect(id) }
                }
            }
        } message: { _ in
            Text(String(format: AgentLocalization.string("Opening it moves the conversation out of %@'s archive and back into its history. Browsing archived conversations never changes them.", locale: locale), agentDisplayName))
        }
        .onDisappear {
            pendingRemovalIDs = nil
            pendingUnarchiveID = nil
            unarchiveOpenTask?.cancel()
            unarchiveOpenTask = nil
        }
        .accessibilityIdentifier("agent-history-page")
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    summaryControls.fixedSize(horizontal: true, vertical: false)
                    searchControls.frame(minWidth: 180, maxWidth: 280)
                }
                VStack(spacing: 10) {
                    summaryControls
                    searchControls
                }
            }
            if isSelecting {
                HStack(spacing: 8) {
                    Button(selected.count == sessions.count && !sessions.isEmpty ? "Deselect all" : "Select all") {
                        selectedIDs = selected.count == sessions.count ? [] : Set(visibleIDs)
                    }.disabled(sessions.isEmpty)
                    Spacer(minLength: 0)
                    LitheMenu {
                        LitheContextMenuItem.action("Export conversations") { history.export(selected) }
                            .disabled(!history.canExport(selected))
                        LitheContextMenuItem.action("Add to favorites") { history.setFavorite(selected, true) }
                        LitheContextMenuItem.action("Remove from favorites") { history.setFavorite(selected, false) }
                        LitheContextMenuItem.separator
                        LitheContextMenuItem.action(
                            filter == .removed ? "Restore conversations" : "Remove from history"
                        ) {
                            if filter == .removed {
                                if history.setHidden(selected, false) { selectedIDs = [] }
                            } else {
                                pendingRemovalIDs = selected
                            }
                        }
                    } label: {
                        Text("Manage selected")
                    }
                    .buttonStyle(.litheNoPress)
                        .disabled(selected.isEmpty)
                }.font(LitheTheme.uiFont(size: 11)).buttonStyle(.litheNoPress)
            }
            if filter == .removed {
                Text("Removed conversations are hidden only in Lithe. The Agent's original records are kept.")
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if feature.connectionState == .ready && !feature.canListArchivedSessions {
                Text(String(format: AgentLocalization.string("%@ does not provide archived conversations.", locale: locale), agentDisplayName))
                    .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("agent-history-archive-unsupported")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var summaryControls: some View {
        HStack(spacing: 8) {
            Text(isSelecting
                 ? String(format: AgentLocalization.string("%d selected", locale: locale), selected.count)
                 : String(format: AgentLocalization.string("%d conversations", locale: locale), sessions.count))
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(AgentPanelStyle.secondary)
            Spacer(minLength: 0)
            Button {
                isSelecting.toggle(); selectedIDs = []; editingID = nil
            } label: {
                Label(isSelecting ? "Done" : "Select", systemImage: "checklist")
                    .font(LitheTheme.uiFont(size: 11))
            }.buttonStyle(LitheSecondaryButtonStyle())
                .accessibilityIdentifier("agent-history-select")
            Button { feature.refreshSessions() } label: {
                if feature.isRefreshingSessions { ProgressView().controlSize(.mini) }
                else { LitheIDEAIcon(resourcePath: "expui/general/refresh.svg", size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true) }
            }.litheToolbarIconButton()
                .disabled(!feature.canRefreshSessions || feature.isRefreshingSessions)
                .help("Refresh history")
                .accessibilityIdentifier("agent-history-refresh")
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            LitheSettingsSearchField("Search conversation titles or IDs…", text: $query)
                .accessibilityIdentifier("agent-history-search")
            LitheMenu {
                for mode in AgentHistoryFilter.allCases {
                    LitheContextMenuItem.action(mode.menuTitle, checked: mode == filter) { filter = mode }
                }
            } label: {
                LitheSystemIcon(systemImage: filter == .favorites ? "star.fill" : "line.3.horizontal.decrease", size: LitheTheme.Metrics.toolbarIconSize)
            }
            .litheToolbarIconButton()
                .help(filter.title)
                .accessibilityIdentifier("agent-history-filter")
        }.foregroundStyle(AgentPanelStyle.secondary)
    }

    @ViewBuilder private var emptyState: some View {
        switch AgentHistoryPresentation.emptyState(
            isRefreshing: feature.isRefreshingSessions || feature.isRefreshingArchivedSessions,
            query: query, isArchivedHistoryComplete: feature.isArchivedHistoryComplete
        ) {
        case .incomplete:
            Spacer(minLength: 0)
        case .loading:
            AgentEmptyStateView(systemImage: "clock", title: "Loading history…", message: "", isBusy: true)
        case .noMatches:
            AgentEmptyStateView(systemImage: "magnifyingglass", title: "No matching conversations",
                               message: AgentLocalization.string("Try another title or session ID.", locale: locale))
        case .noHistory:
            AgentEmptyStateView(systemImage: "clock.arrow.circlepath", title: "No earlier conversations",
                               message: AgentLocalization.string("Conversations for this project and Agent appear here.", locale: locale))
        }
    }

    private var agentDisplayName: String { agentName ?? AgentLocalization.string("This Agent", locale: locale) }

    private var archivedSection: some View {
        VStack(spacing: 0) {
            Button { archivedExpansion = !isArchivedExpanded } label: {
                HStack(spacing: 6) {
                    LitheSystemIcon(systemImage: isArchivedExpanded ? "chevron.down" : "chevron.right", size: 10)
                    Text(String(format: AgentLocalization.string("Archived (%d)", locale: locale), archived.count))
                        .font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    if feature.isRefreshingArchivedSessions || feature.unarchivingSessionID != nil {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress).lithePointer()
            .foregroundStyle(AgentPanelStyle.secondary)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .overlay(alignment: .bottom) { divider }
            .accessibilityIdentifier("agent-history-archived")
            if isArchivedExpanded {
                ForEach(archived) { session in archivedRow(session) }
            }
        }
    }

    /// Upstream unarchive requires consent. Restoring Lithe visibility only clears
    /// local metadata, so it is available independently in Removed conversations.
    private func archivedRow(_ session: AgentSessionSummary) -> some View {
        AgentHistoryRow(
            session: session, title: displayTitle(session), agentName: agentName, messageCount: nil,
            isCurrent: false, isFavorite: false, isRemoved: filter == .removed, isArchived: true, isSelecting: false,
            isSelected: false, isFocused: historyListActive, isEditing: false,
            editingTitle: $editingTitle, isCopied: copiedID == session.id, canExport: false,
            canOpen: feature.connectionState == .ready && feature.unarchivingSessionID == nil,
            onOpen: { pendingUnarchiveID = session.id }, onToggleSelection: {},
            onCopy: { onCopySessionID(session.id); copiedID = session.id },
            onRename: {}, onSave: {}, onCancel: {}, onExport: {}, onFavorite: {},
            onRemove: { history.setHidden([session.id], false) }
        )
    }

    private func row(_ session: AgentSessionSummary) -> some View {
        AgentHistoryRow(
            session: session, title: displayTitle(session), agentName: agentName,
            messageCount: AgentHistoryPresentation.messageCount(feature.conversations[session.id]),
            isCurrent: session.id == feature.selectedSessionID,
            isFavorite: history.metadata[session.id]?.isFavorite == true,
            isRemoved: filter == .removed, isSelecting: isSelecting,
            isSelected: selectedIDs.contains(session.id), isFocused: historyListActive, isEditing: editingID == session.id,
            editingTitle: $editingTitle, isCopied: copiedID == session.id,
            canExport: history.canExport([session.id]),
            canOpen: feature.canLoadSessions && feature.connectionState == .ready
                || feature.conversations[session.id]?.isAttached == true,
            onOpen: { onSelect(session.id) },
            onToggleSelection: {
                if !selectedIDs.insert(session.id).inserted { selectedIDs.remove(session.id) }
            },
            onCopy: { onCopySessionID(session.id); copiedID = session.id },
            onRename: { editingTitle = displayTitle(session); editingID = session.id },
            onSave: { if history.rename(session.id, title: editingTitle) { editingID = nil } },
            onCancel: { editingID = nil },
            onExport: { history.export([session.id]) },
            onFavorite: { history.setFavorite([session.id], history.metadata[session.id]?.isFavorite != true) },
            onRemove: {
                if filter == .removed { history.setHidden([session.id], false) }
                else { pendingRemovalIDs = [session.id] }
            }
        )
    }

    private func displayTitle(_ session: AgentSessionSummary) -> String {
        AgentSessionTitle.title(of: AgentSessionSummary(id: session.id, title: history.title(for: session)), locale: locale)
    }

    private var divider: some View { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
}

private struct AgentHistoryRow: View {
    @Environment(\.locale) private var locale
    let session: AgentSessionSummary
    let title: String
    let agentName: String?
    let messageCount: Int?
    let isCurrent: Bool
    let isFavorite: Bool
    let isRemoved: Bool
    var isArchived = false
    let isSelecting: Bool
    let isSelected: Bool
    let isFocused: Bool
    let isEditing: Bool
    @Binding var editingTitle: String
    let isCopied: Bool
    let canExport: Bool
    let canOpen: Bool
    let onOpen: () -> Void
    let onToggleSelection: () -> Void
    let onCopy: () -> Void
    let onRename: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onExport: () -> Void
    let onFavorite: () -> Void
    let onRemove: () -> Void
    @State private var isHovering = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isSelecting {
                    Button(action: onToggleSelection) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    }.buttonStyle(.litheNoPress).help("Select conversation")
                }
                AgentBrandIcon(name: agentName, size: 18).foregroundStyle(AgentPanelStyle.text)
                if isEditing {
                    TextField("Conversation title", text: $editingTitle)
                        .textFieldStyle(.plain).focused($isTitleFocused)
                        .onSubmit(onSave).onExitCommand(perform: onCancel)
                        .onAppear { isTitleFocused = true }
                    icon("checkmark", "Save title", onSave)
                        .disabled(editingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    icon("xmark", "Cancel", onCancel)
                } else {
                    Button(action: isSelecting ? onToggleSelection : onOpen) {
                        Text(title).font(LitheTheme.uiFont(size: 14, weight: .semibold))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.litheNoPress).lithePointer()
                        .disabled(!isSelecting && !canOpen).help(title)
                    if let date = AgentHistoryPresentation.date(session.updatedAt) {
                        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                            .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
                            .lineLimit(1).fixedSize()
                            .help(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            HStack(spacing: 6) {
                if let messageCount {
                    Text(String(format: AgentLocalization.string("%d messages", locale: locale), messageCount))
                        .lineLimit(1)
                    Text("·")
                }
                if isArchived {
                    Text("Archived")
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().stroke(AgentPanelStyle.border))
                    Text("·")
                }
                Text(String(session.id.prefix(8))).font(LitheTheme.uiFont(size: 10, design: .monospaced))
                    .help(session.id)
                icon(isCopied ? "checkmark" : "doc.on.doc", "Copy session ID", onCopy)
                    .accessibilityIdentifier("agent-history-copy-\(session.id)")
                Spacer(minLength: 0)
                if !isSelecting && !isEditing && isArchived && isRemoved {
                    icon("arrow.uturn.backward", "Restore conversations", onRemove)
                        .accessibilityIdentifier("agent-history-restore-\(session.id)")
                }
                if !isSelecting && !isEditing && !isArchived {
                    HStack(spacing: 2) {
                        if !isRemoved {
                            icon("pencil", "Rename conversation", onRename)
                            icon("arrow.down", "Export conversations", onExport).disabled(!canExport)
                        }
                        icon(isRemoved ? "arrow.uturn.backward" : "trash", isRemoved ? "Restore conversations" : "Remove from history", onRemove)
                        icon(isFavorite ? "star.fill" : "star", "Toggle favorite", onFavorite)
                            .foregroundStyle(isFavorite ? LitheTheme.warning : AgentPanelStyle.secondary)
                    }
                    .opacity(isHovering || isFavorite || isCurrent ? 1 : 0)
                    .accessibilityElement(children: .contain)
                }
            }
            .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
        }
        .foregroundStyle(AgentPanelStyle.text)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .litheSelectionRow(isSelected: isSelected, isFocused: isFocused, cornerRadius: 0)
        .background(isCurrent && !isSelected ? AgentPanelStyle.header : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("agent-history-row-\(session.id)")
    }

    private func icon(_ name: String, _ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { LitheSystemIcon(systemImage: name, size: LitheTheme.Metrics.toolbarIconSize) }
            .litheToolbarIconButton().help(title).accessibilityLabel(title)
    }
}
