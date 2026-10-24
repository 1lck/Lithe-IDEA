import SwiftUI
import LitheAgentConversationModule
import LitheCoreContracts

enum AgentHistoryFilter: String, CaseIterable {
    case all, favorites, removed
    var title: LocalizedStringKey { LocalizedStringKey(menuTitle) }
    var menuTitle: String {
        switch self {
        case .all: "All conversations"
        case .favorites: "Pinned"
        case .removed: "Removed conversations"
        }
    }
}

/// Browsing groups of the unfiltered history: favorites first, then by last activity.
enum AgentHistoryGroup: Hashable {
    case favorites, today, yesterday, previous7Days, previous30Days, earlier, unknown

    var title: String {
        switch self {
        case .favorites: "Pinned"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 days"
        case .previous30Days: "Previous 30 days"
        case .earlier: "Earlier"
        case .unknown: "Unknown date"
        }
    }
}

struct AgentHistorySection: Identifiable {
    /// `nil` renders the rows without a heading (search results and filtered lists).
    let group: AgentHistoryGroup?
    let sessions: [AgentSessionSummary]
    var id: AgentHistoryGroup? { group }
}

/// Row data computed once per history change. Rows compare by value, so a model
/// publish that changes nothing visible (streaming text, quota ticks) skips
/// rebuilding and diffing the rows.
struct AgentHistoryRowModel: Identifiable, Equatable {
    let session: AgentSessionSummary
    let title: String
    let messageCount: Int?
    let timeText: String?
    let isCurrent: Bool
    let isFavorite: Bool
    let canOpen: Bool
    var id: String { session.id }
}

/// One flat row for the history list: a section header or a conversation.
/// A single flat `ForEach` keeps `LazyVStack` from mistracking nested,
/// optional-id sections when every conversation lands in one date group.
enum AgentHistoryListItem: Identifiable, Equatable {
    case header(AgentHistoryGroup, Int)
    case row(AgentHistoryRowModel)
    case archiveHeader
    case archivedRow(AgentHistoryRowModel)

    var id: String {
        switch self {
        case .header(let group, _): "header-\(group.title)"
        case .row(let model): model.id
        case .archiveHeader: "archived-group"
        case .archivedRow(let model): "archived-" + model.id
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
        if let prompt = firstPrompt(conversation) {
            return AgentSessionTitle.provisional(prompt.text)
        }
        if let conversation, conversation.isAttached, !conversation.isLoading, !hasTranscript(conversation) {
            return AgentLocalization.string("New Chat", locale: locale)
        }
        return AgentLocalization.string("Untitled conversation", locale: locale)
    }

    // `transcriptMessages` filters and copies the whole conversation. History
    // rows are rebuilt on every model publish, so these helpers scan in place
    // and stop at the first match instead.

    /// The first non-empty user prompt of the main Agent (users never belong to a subagent).
    private static func firstPrompt(_ conversation: AgentConversation?) -> AgentConversationMessage? {
        conversation?.messages.first {
            $0.role == .user && $0.subagentSessionID == nil
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func hasTranscript(_ conversation: AgentConversation) -> Bool {
        conversation.messages.contains { $0.subagentSessionID == nil || $0.role == .tool }
    }

    /// Everything about a loaded conversation that can change a history title.
    /// Streaming text past the first prompt leaves it unchanged.
    static func titleKey(_ conversation: AgentConversation) -> String {
        "\(firstPrompt(conversation)?.text ?? "")|\(conversation.isAttached)|\(conversation.isLoading)|\(hasTranscript(conversation))"
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

    /// `sessions` is already ordered newest first, so every group keeps that order.
    static func sections(_ sessions: [AgentSessionSummary], metadata: [String: AgentHistoryMetadata],
                         groupsByDate: Bool, now: Date = Date(), calendar: Calendar = .current) -> [AgentHistorySection] {
        guard groupsByDate else { return sessions.isEmpty ? [] : [AgentHistorySection(group: nil, sessions: sessions)] }
        let startOfToday = calendar.startOfDay(for: now)
        func offset(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday }
        let yesterday = offset(1), week = offset(7), month = offset(30)
        var buckets: [AgentHistoryGroup: [AgentSessionSummary]] = [:]
        for session in sessions {
            let group: AgentHistoryGroup
            if metadata[session.id]?.isFavorite == true { group = .favorites }
            else if let date = date(session.updatedAt) {
                if date >= startOfToday { group = .today }
                else if date >= yesterday { group = .yesterday }
                else if date >= week { group = .previous7Days }
                else if date >= month { group = .previous30Days }
                else { group = .earlier }
            } else { group = .unknown }
            buckets[group, default: []].append(session)
        }
        return [AgentHistoryGroup.favorites, .today, .yesterday, .previous7Days, .previous30Days, .earlier, .unknown]
            .compactMap { group in buckets[group].map { AgentHistorySection(group: group, sessions: $0) } }
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
        // One O(n) pass builds the rows and `sessions` sorts them once: O(n log n).
        // The final order is by activity date, so pre-sorting here was redundant.
        let activeSessions = sessions.filter { !archivedSessionIDs.contains($0.id) }
        let listedIDs = Set(activeSessions.map(\.id))
        let pending = openSessionIDs.reversed().filter { !archivedSessionIDs.contains($0) && !listedIDs.contains($0) }
            .map { AgentSessionSummary(id: $0, title: AgentLocalization.string("New Chat", locale: locale)) }
        let rows = (pending + activeSessions).map { session in
            var row = session
            if !listedIDs.contains(session.id), let prompt = firstPrompt(conversations[session.id]) {
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

    /// Upstream timestamps repeat across every list refresh; parse each one once.
    private static let parsedDates = NSCache<NSString, NSDate>()

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let cached = parsedDates.object(forKey: value as NSString) { return cached as Date }
        guard let parsed = (try? fractionalDateStyle.parse(value)) ?? (try? dateStyle.parse(value)) else { return nil }
        parsedDates.setObject(parsed as NSDate, forKey: value as NSString)
        return parsed
    }

    /// Counts main-Agent prompts and replies in one pass without copying the transcript.
    static func messageCount(_ conversation: AgentConversation?) -> Int? {
        guard let conversation, !conversation.isLoading else { return nil }
        var count = 0
        var hasTranscript = false
        for message in conversation.messages where message.subagentSessionID == nil || message.role == .tool {
            hasTranscript = true
            if message.role == .user || (message.role == .agent && message.plan == nil) { count += 1 }
        }
        return conversation.isAttached || hasTranscript ? count : nil
    }

    /// Time label for a history row: "N minutes ago" inside the first hour, then
    /// the concrete last-update time (clock time today, date + time otherwise).
    static func updatedTime(_ value: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        timeLabel(value, now: now, calendar: calendar, locale: locale)?.text
    }

    /// Parses the timestamp once and returns both the concrete date and its label.
    /// History rows scroll a long list, so every row must avoid re-parsing the
    /// ISO 8601 timestamp several times per layout pass.
    static func timeLabel(_ value: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> (date: Date, text: String)? {
        guard let date = date(value) else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            if minutes < 1 { return (date, AgentLocalization.string("just now", locale: locale)) }
            return (date, String(format: AgentLocalization.string("%d minutes ago", locale: locale), minutes))
        }
        return (date, AgentTurnStatisticsPresentation.completionTime(date, now: now, calendar: calendar, locale: locale))
    }
}

/// Remembers the last built history so that model publishes which change nothing
/// the list shows cost O(1)–O(n) comparisons instead of a rebuild.
///
/// Streaming in an open conversation publishes the connection model every few
/// dozen milliseconds. Sorting is O(n log n) and only reruns when the sessions,
/// annotations, search or filter change; row data only rebuilds when a visible
/// input changes; the list compares one revision number instead of every row.
@MainActor
final class AgentHistoryRowsCache {
    struct Key: Equatable {
        let sessions: [AgentSessionSummary]
        let openSessionIDs: [String]
        let archivedSessionIDs: Set<String>
        let metadata: [String: AgentHistoryMetadata]
        let conversationTitles: [String: String]
        let query: String
        let filter: AgentHistoryFilter
        let localeIdentifier: String
    }

    /// Everything that changes how rows look, apart from the sorted sessions.
    struct ItemsKey: Equatable {
        let rowsRevision: Int
        let archivedRevision: Int
        let selectedSessionID: String?
        let canOpenListed: Bool
        let canOpenArchived: Bool
        let conversations: [String: ConversationState]
        let groupsByDate: Bool
        /// Relative labels ("5 minutes ago") and date groups advance per minute.
        let minute: Int
        let localeIdentifier: String
    }

    struct ConversationState: Equatable {
        let messageCount: Int?
        let isAttached: Bool
    }

    private var key: Key?
    private var cached: [AgentSessionSummary] = []
    private(set) var rowsRevision = 0
    private var archivedKey: [AgentSessionSummary]?
    private(set) var archivedRevision = 0
    private var itemsKey: ItemsKey?
    private var items: [AgentHistoryListItem] = []
    private var archivedItems: [AgentHistoryRowModel] = []
    private(set) var itemsRevision = 0
    /// Message counts keyed by the transcript length they were computed for.
    private var counts: [String: (length: Int, isLoading: Bool, isAttached: Bool, count: Int?)] = [:]

    func rows(for key: Key, build: () -> [AgentSessionSummary]) -> [AgentSessionSummary] {
        if key != self.key {
            cached = build()
            self.key = key
            rowsRevision &+= 1
        }
        return cached
    }

    func noteArchived(_ archived: [AgentSessionSummary]) {
        if archived != archivedKey {
            archivedKey = archived
            archivedRevision &+= 1
        }
    }

    /// Streaming appends text to the last message without changing the count.
    func conversationState(_ id: String, _ conversation: AgentConversation) -> ConversationState {
        let length = conversation.messages.count
        if let entry = counts[id], entry.length == length, entry.isLoading == conversation.isLoading,
           entry.isAttached == conversation.isAttached {
            return ConversationState(messageCount: entry.count, isAttached: entry.isAttached)
        }
        let count = AgentHistoryPresentation.messageCount(conversation)
        counts[id] = (length, conversation.isLoading, conversation.isAttached, count)
        return ConversationState(messageCount: count, isAttached: conversation.isAttached)
    }

    /// Forget counts of conversations whose tabs were closed.
    func pruneConversations(keeping ids: Dictionary<String, AgentConversation>.Keys) {
        if counts.count > ids.count { counts = counts.filter { ids.contains($0.key) } }
    }

    func items(for key: ItemsKey,
               build: () -> (items: [AgentHistoryListItem], archived: [AgentHistoryRowModel])) -> (items: [AgentHistoryListItem], archived: [AgentHistoryRowModel], revision: Int) {
        if key != itemsKey {
            let built = build()
            items = built.items
            archivedItems = built.archived
            itemsKey = key
            itemsRevision &+= 1
        }
        return (items, archivedItems, itemsRevision)
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
    @State private var pendingRemovalIDs: [String]?
    /// The user's explicit toggle; a new search falls back to the default.
    @State private var archivedExpansion: Bool?
    @State private var pendingUnarchiveID: String?
    /// Opens a conversation once its unarchive completes. Leaving the page
    /// cancels only the navigation; the confirmed upstream restore still finishes.
    @State private var unarchiveOpenTask: Task<Void, Never>?
    @State private var rowsCache = AgentHistoryRowsCache()

    private var sessions: [AgentSessionSummary] {
        let archivedIDs = Set(feature.archivedSessions.map(\.id))
        let key = AgentHistoryRowsCache.Key(
            sessions: feature.sessions, openSessionIDs: feature.openSessionIDs, archivedSessionIDs: archivedIDs,
            metadata: history.metadata, conversationTitles: feature.conversations.mapValues(AgentHistoryPresentation.titleKey),
            query: query, filter: filter, localeIdentifier: locale.identifier)
        return rowsCache.rows(for: key) {
            AgentHistoryPresentation.managementSessions(feature.sessions, openSessionIDs: feature.openSessionIDs,
                conversations: feature.conversations, archivedSessionIDs: archivedIDs,
                metadata: history.metadata, query: query, filter: filter, locale: locale)
        }
    }
    /// Searched and filtered like active rows; local restoration never loads a transcript.
    private var archived: [AgentSessionSummary] {
        AgentHistoryPresentation.sessions(feature.archivedSessions, metadata: history.metadata, query: query, filter: filter)
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // Sorting and filtering run once per evaluation, not once per use.
        let rows = sessions
        let archivedRows = archived
        let rowIDs = rows.map(\.id)
        return VStack(spacing: 0) {
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
            toolbar(count: rows.count, visible: rowIDs)
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
            if rows.isEmpty && archivedRows.isEmpty {
                emptyState
            } else {
                list(rows: rows, archivedRows: archivedRows)
            }
        }
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .onAppear { feature.refreshSessionsIfNeeded() }
        .onChange(of: rowIDs) { selectedIDs.formIntersection($0) }
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

    private func toolbar(count: Int, visible: [String]) -> some View {
        let selected = visible.filter(selectedIDs.contains)
        return VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    summaryControls(count: count, selectedCount: selected.count).fixedSize(horizontal: true, vertical: false)
                    searchControls.frame(minWidth: 180, maxWidth: 280)
                }
                VStack(spacing: 10) {
                    summaryControls(count: count, selectedCount: selected.count)
                    searchControls
                }
            }
            if isSelecting {
                HStack(spacing: 8) {
                    Button(selected.count == count && count > 0 ? "Deselect all" : "Select all") {
                        selectedIDs = selected.count == count ? [] : Set(visible)
                    }.disabled(count == 0)
                    Spacer(minLength: 0)
                    LitheMenu {
                        LitheContextMenuItem.action("Export conversations") { history.export(selected) }
                            .disabled(!history.canExport(selected))
                        LitheContextMenuItem.action("Pin conversation") { history.setFavorite(selected, true) }
                        LitheContextMenuItem.action("Unpin conversation") { history.setFavorite(selected, false) }
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

    private func summaryControls(count: Int, selectedCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(isSelecting
                 ? String(format: AgentLocalization.string("%d selected", locale: locale), selectedCount)
                 : String(format: AgentLocalization.string("%d conversations", locale: locale), count))
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(AgentPanelStyle.secondary)
            Spacer(minLength: 0)
            Button {
                isSelecting.toggle(); selectedIDs = []; editingID = nil
            } label: {
                Label(isSelecting ? "Done" : "Select", systemImage: "checklist")
                    .font(LitheTheme.uiFont(size: 11))
            }.buttonStyle(LitheActionButtonStyle())
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
            LitheSearchField("Search conversation titles or IDs…", text: $query)
                .accessibilityIdentifier("agent-history-search")
            LitheMenu {
                for mode in AgentHistoryFilter.allCases {
                    LitheContextMenuItem.action(mode.menuTitle, checked: mode == filter) { filter = mode }
                }
            } label: {
                LitheSystemIcon(systemImage: filter == .favorites ? "pin.fill" : "line.3.horizontal.decrease", size: LitheTheme.Metrics.toolbarIconSize)
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

    private func list(rows: [AgentSessionSummary], archivedRows: [AgentSessionSummary]) -> some View {
        rowsCache.noteArchived(archivedRows)
        var conversationStates: [String: AgentHistoryRowsCache.ConversationState] = [:]
        let conversations = feature.conversations
        for (id, conversation) in conversations {
            conversationStates[id] = rowsCache.conversationState(id, conversation)
        }
        rowsCache.pruneConversations(keeping: conversations.keys)
        let now = Date()
        let groupsByDate = filter == .all && !isSearching
        let key = AgentHistoryRowsCache.ItemsKey(
            rowsRevision: rowsCache.rowsRevision, archivedRevision: rowsCache.archivedRevision,
            selectedSessionID: feature.selectedSessionID,
            canOpenListed: feature.canLoadSessions && feature.connectionState == .ready,
            canOpenArchived: feature.connectionState == .ready && feature.unarchivingSessionID == nil,
            conversations: conversationStates, groupsByDate: groupsByDate,
            minute: Int(now.timeIntervalSinceReferenceDate / 60), localeIdentifier: locale.identifier)
        let built = rowsCache.items(for: key) {
            buildItems(rows: rows, archivedRows: archivedRows, key: key, now: now)
        }
        return AgentHistoryList(
                items: built.items, archived: built.archived, revision: built.revision,
                isArchivedExpanded: archivedExpansion ?? (isSearching && !archivedRows.isEmpty),
                isArchivedBusy: feature.isRefreshingArchivedSessions || feature.unarchivingSessionID != nil,
                isRemovedFilter: filter == .removed, isSelecting: isSelecting, selectedIDs: selectedIDs,
                editingID: editingID, editingText: editingTitle, editingTitle: $editingTitle,
                isFocused: historyListActive, actions: rowActions
            )
            .equatable()
        .background(LitheToolWindowActivityTracker(isActive: $historyListActive))
    }

    /// One O(n) pass. Model properties are read once, not once per row.
    private func buildItems(rows: [AgentSessionSummary], archivedRows: [AgentSessionSummary],
                            key: AgentHistoryRowsCache.ItemsKey, now: Date) -> (items: [AgentHistoryListItem], archived: [AgentHistoryRowModel]) {
        let metadata = history.metadata
        let calendar = Calendar.current
        func row(_ session: AgentSessionSummary, canOpen: Bool, state: AgentHistoryRowsCache.ConversationState?) -> AgentHistoryRowModel {
            let annotation = metadata[session.id]
            return AgentHistoryRowModel(
                session: session,
                title: AgentSessionTitle.title(of: AgentSessionSummary(id: session.id, title: annotation?.title ?? session.title), locale: locale),
                messageCount: state?.messageCount,
                timeText: AgentHistoryPresentation.timeLabel(session.updatedAt, now: now, calendar: calendar, locale: locale)?.text,
                isCurrent: session.id == key.selectedSessionID,
                isFavorite: annotation?.isFavorite == true,
                canOpen: canOpen)
        }
        var items: [AgentHistoryListItem] = []
        items.reserveCapacity(rows.count + 8)
        for section in AgentHistoryPresentation.sections(rows, metadata: metadata, groupsByDate: key.groupsByDate,
                                                         now: now, calendar: calendar) {
            if let group = section.group { items.append(.header(group, section.sessions.count)) }
            for session in section.sessions {
                let state = key.conversations[session.id]
                items.append(.row(row(session, canOpen: key.canOpenListed || state?.isAttached == true, state: state)))
            }
        }
        // Upstream unarchive requires consent. Restoring Lithe visibility only clears
        // local metadata, so it is available independently in Removed conversations.
        let archived = archivedRows.map { row($0, canOpen: key.canOpenArchived, state: nil) }
        return (items, archived)
    }

    private var rowActions: AgentHistoryRowActions {
        AgentHistoryRowActions(
            open: { onSelect($0) },
            openArchived: { pendingUnarchiveID = $0 },
            toggleSelection: { id in if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) } },
            copy: { onCopySessionID($0) },
            rename: { model in editingTitle = model.title; editingID = model.id },
            save: { id in if history.rename(id, title: editingTitle) { editingID = nil } },
            cancel: { editingID = nil },
            export: { history.export([$0]) },
            canExport: { history.canExport([$0]) },
            favorite: { id in history.setFavorite([id], history.metadata[id]?.isFavorite != true) },
            remove: { id in
                if filter == .removed { history.setHidden([id], false) }
                else { pendingRemovalIDs = [id] }
            },
            restoreArchived: { history.setHidden([$0], false) },
            toggleArchived: { archivedExpansion = !(archivedExpansion ?? (isSearching && !archived.isEmpty)) })
    }

    private var divider: some View { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
}

/// Row callbacks keyed by session; closures are excluded from the list's equality.
struct AgentHistoryRowActions {
    let open: (String) -> Void
    let openArchived: (String) -> Void
    let toggleSelection: (String) -> Void
    let copy: (String) -> Void
    let rename: (AgentHistoryRowModel) -> Void
    let save: (String) -> Void
    let cancel: () -> Void
    let export: (String) -> Void
    /// Evaluated when a row's menu opens, never for every row on each refresh.
    let canExport: (String) -> Bool
    let favorite: (String) -> Void
    let remove: (String) -> Void
    let restoreArchived: (String) -> Void
    let toggleArchived: () -> Void
}

/// The scrolling content of the history page, compared by value. The page view
/// observes the whole connection model; this keeps unrelated publishes from
/// rebuilding every visible row.
private struct AgentHistoryList: View, Equatable {
    @Environment(\.locale) private var locale
    let items: [AgentHistoryListItem]
    let archived: [AgentHistoryRowModel]
    /// Bumped by the cache whenever `items` or `archived` are rebuilt.
    let revision: Int
    let isArchivedExpanded: Bool
    let isArchivedBusy: Bool
    let isRemovedFilter: Bool
    let isSelecting: Bool
    let selectedIDs: Set<String>
    let editingID: String?
    /// Compared so typing in the rename field still refreshes the row.
    let editingText: String
    let editingTitle: Binding<String>
    let isFocused: Bool
    let actions: AgentHistoryRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.isArchivedExpanded == rhs.isArchivedExpanded && lhs.isArchivedBusy == rhs.isArchivedBusy
            && lhs.isRemovedFilter == rhs.isRemovedFilter && lhs.isSelecting == rhs.isSelecting
            && lhs.selectedIDs == rhs.selectedIDs && lhs.editingID == rhs.editingID
            && lhs.editingText == rhs.editingText && lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        let visible = items + (archived.isEmpty ? [] : [.archiveHeader]
            + (isArchivedExpanded ? archived.map(AgentHistoryListItem.archivedRow) : []))
        LitheTreeList(visible, id: \.id, selection: Binding<Set<String>>(
            get: { selectedIDs },
            set: { next in
                for id in next.symmetricDifference(selectedIDs) { actions.toggleSelection(id) }
            }), togglesSelectionOnClick: isSelecting,
            hierarchy: { item in
                switch item {
                case .header: .init(isSelectable: false)
                case .archiveHeader: .init(isBranch: true, isExpanded: isArchivedExpanded, isSelectable: false)
                case .row: .init(isSelectable: isSelecting)
                case .archivedRow: .init(depth: 1, isSelectable: false)
                }
            }, onExpansion: { item, expanded in
                if case .archiveHeader = item, expanded != isArchivedExpanded { actions.toggleArchived() }
            }, multiline: true
        ) { item in
            switch item {
            case .header(let group, let count): header(group, count: count)
            case .row(let model): row(model)
            case .archiveHeader: archiveHeader
            case .archivedRow(let model):
                AgentHistoryRow(model: model, isArchived: true, isRemoved: isRemovedFilter, isSelecting: false,
                                isSelected: false, isFocused: isFocused, isEditing: false,
                                editingTitle: editingTitle, actions: actions)
            }
        }
    }

    private func row(_ model: AgentHistoryRowModel) -> AgentHistoryRow {
        AgentHistoryRow(model: model, isRemoved: isRemovedFilter, isSelecting: isSelecting,
                        isSelected: selectedIDs.contains(model.id), isFocused: isFocused,
                        isEditing: editingID == model.id, editingTitle: editingTitle, actions: actions)
    }

    private func header(_ group: AgentHistoryGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(AgentLocalization.string(String.LocalizationValue(group.title), locale: locale))
            Text(verbatim: String(count)).monospacedDigit().foregroundStyle(AgentPanelStyle.muted)
            Spacer(minLength: 0)
        }
        .font(LitheTheme.uiFont(size: 11, weight: .semibold))
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private var archiveHeader: some View {
        HStack(spacing: 6) {
            Text(String(format: AgentLocalization.string("Archived (%d)", locale: locale), archived.count))
                .font(LitheTheme.uiFont(size: 12, weight: .semibold))
            if isArchivedBusy { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.vertical, 10)
        .accessibilityIdentifier("agent-history-archived")
    }

}

private struct AgentHistoryRow: View {
    @Environment(\.locale) private var locale
    let model: AgentHistoryRowModel
    var isArchived = false
    let isRemoved: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let isFocused: Bool
    let isEditing: Bool
    let editingTitle: Binding<String>
    let actions: AgentHistoryRowActions
    @State private var isHovering = false
    @FocusState private var isTitleFocused: Bool

    /// A fixed height lets the lazy stack place rows without measuring them.
    static let height: CGFloat = 56

    private var showsMenu: Bool { !isSelecting && !isEditing && !isArchived }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleLine
            if !isEditing { detailLine }
        }
        .foregroundStyle(AgentPanelStyle.text)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
        .background(model.isCurrent && !isSelected ? AgentPanelStyle.header : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-history-row-\(model.id)")
    }

    @ViewBuilder private var titleLine: some View {
        HStack(spacing: 10) {
            if isSelecting {
                Button { actions.toggleSelection(model.id) } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                }.buttonStyle(.litheNoPress).help("Select conversation")
            }
            if isEditing {
                TextField("Conversation title", text: editingTitle)
                    .textFieldStyle(.plain).focused($isTitleFocused)
                    .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    .onSubmit { actions.save(model.id) }.onExitCommand(perform: actions.cancel)
                    .onAppear { isTitleFocused = true }
                icon("checkmark", "Save title") { actions.save(model.id) }
                    .disabled(editingTitle.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                icon("xmark", "Cancel", actions.cancel)
            } else {
                titleButton
                if showsMenu {
                    // Only the hovered or current row mounts the shared menu anchor;
                    // a scrolling list must not keep one native anchor per row.
                    if isHovering || model.isCurrent { menu }
                    else { Color.clear.frame(width: LitheTheme.Metrics.toolbarIconButtonSize,
                                             height: LitheTheme.Metrics.toolbarIconButtonSize) }
                } else if isArchived && isRemoved {
                    icon("arrow.uturn.backward", "Restore conversations") { actions.restoreArchived(model.id) }
                        .accessibilityIdentifier("agent-history-restore-\(model.id)")
                }
            }
        }
    }

    private var titleButton: some View {
        Button {
            if isSelecting { actions.toggleSelection(model.id) }
            else if isArchived { actions.openArchived(model.id) }
            else { actions.open(model.id) }
        } label: {
            HStack(spacing: 6) {
                if model.isFavorite && !isRemoved {
                    LitheSystemIcon(systemImage: "pin.fill", size: 10).foregroundStyle(AgentPanelStyle.secondary)
                }
                Text(model.title).font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .disabled(!isSelecting && !model.canOpen)
        .accessibilityIdentifier("agent-history-open-\(model.id)")
    }

    private var menu: some View {
        LitheMenu {
            if isRemoved {
                LitheContextMenuItem.action("Restore conversations") { actions.remove(model.id) }
            } else {
                LitheContextMenuItem.action(model.isFavorite ? "Unpin conversation" : "Pin conversation") { actions.favorite(model.id) }
                LitheContextMenuItem.action("Rename conversation") { actions.rename(model) }
                LitheContextMenuItem.action("Fork conversation", isEnabled: false) {}
                LitheContextMenuItem.action("Archive conversation", isEnabled: false) {}
                LitheContextMenuItem.action("Copy session ID") { actions.copy(model.id) }
                LitheContextMenuItem.action("Export conversations", isEnabled: actions.canExport(model.id)) { actions.export(model.id) }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Delete chat",
                    icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: LitheDropdownMetrics.iconSize,
                                               fallbackSystemImage: "trash", preservesOriginalColors: true)),
                    role: .destructive) { actions.remove(model.id) }
            }
        } label: {
            LitheSystemIcon(systemImage: "ellipsis", size: LitheTheme.Metrics.toolbarIconSize)
        }
        .litheToolbarIconButton()
        .help("Conversation actions")
        .accessibilityLabel("Conversation actions")
        .accessibilityIdentifier("agent-history-menu-\(model.id)")
    }

    private var detailLine: some View {
        HStack(spacing: 6) {
            if let messageCount = model.messageCount {
                Text(String(format: AgentLocalization.string("%d messages", locale: locale), messageCount))
            }
            if model.messageCount != nil, model.timeText != nil { Text(verbatim: "·") }
            if let timeText = model.timeText { Text(verbatim: timeText) }
            if isArchived {
                Text("Archived")
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(AgentPanelStyle.border))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(LitheTheme.uiFont(size: 11)).foregroundStyle(AgentPanelStyle.secondary)
        .padding(.leading, isSelecting ? 28 : 0)
    }

    private func icon(_ name: String, _ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { LitheSystemIcon(systemImage: name, size: LitheTheme.Metrics.toolbarIconSize) }
            .litheToolbarIconButton().help(title).accessibilityLabel(title)
    }
}
