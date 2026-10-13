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

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func messageCount(_ conversation: AgentConversation?) -> Int? {
        guard let conversation, !conversation.isLoading,
              conversation.isAttached || !conversation.messages.isEmpty else { return nil }
        return conversation.messages.filter { $0.role == .user || $0.role == .agent }.count
    }
}

/// In-panel history page: annotations stay in Lithe, transcripts stay with the Agent.
struct AgentHistoryView: View {
    @ObservedObject var feature: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    let agentName: String?
    let onBack: () -> Void
    let onCopySessionID: (String) -> Void
    let onSelect: (String) -> Void
    let onReconnect: () -> Void
    @State private var query = ""
    @State private var filter = AgentHistoryFilter.all
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var editingID: String?
    @State private var editingTitle = ""
    @State private var copiedID: String?
    @State private var pendingRemovalIDs: [String]?

    private var sessions: [AgentSessionSummary] {
        AgentHistoryPresentation.sessions(feature.sessions, metadata: history.metadata, query: query, filter: filter)
    }
    private var visibleIDs: [String] { sessions.map(\.id) }
    private var selected: [String] { visibleIDs.filter(selectedIDs.contains) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) { Label("Back", systemImage: "arrow.left") }
                    .buttonStyle(.litheNoPress).lithePointer()
                    .accessibilityIdentifier("agent-history-back")
                Spacer()
                Text("Conversation history").fontWeight(.medium)
            }
            .foregroundStyle(AgentPanelStyle.secondary)
            .font(LitheTheme.uiFont(size: 12))
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(AgentPanelStyle.header)
            divider
            toolbar
            divider
            if let error = history.errorMessage ?? feature.historyError {
                AgentInlineNotice(text: error)
                    .padding(.top, 8)
            }
            if case .failed(let message) = feature.connectionState {
                AgentInlineNotice(text: message, actionTitle: "Reconnect", action: onReconnect)
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
            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in row(session) }
                    }
                }
            }
        }
        .background(AgentPanelStyle.canvas)
        .onChange(of: visibleIDs) { selectedIDs.formIntersection($0) }
        .alert("Confirm deletion", isPresented: Binding(
            get: { pendingRemovalIDs != nil },
            set: { if !$0 { pendingRemovalIDs = nil } }
        ), presenting: pendingRemovalIDs) { ids in
            Button("Cancel", role: .cancel) { pendingRemovalIDs = nil }
            Button("Delete", role: .destructive) {
                if history.setHidden(ids, true) { selectedIDs.subtract(ids) }
            }
        } message: { ids in
            Text(String(format: String(localized: "Remove %d conversation(s) from history? You can restore them from Removed conversations. The Agent's original records will be kept."), ids.count))
        }
        .onDisappear { pendingRemovalIDs = nil }
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
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var summaryControls: some View {
        HStack(spacing: 8) {
            Text(isSelecting
                 ? String(format: String(localized: "%d selected"), selected.count)
                 : String(format: String(localized: "%d conversations"), sessions.count))
                .font(LitheTheme.uiFont(size: 12)).foregroundStyle(AgentPanelStyle.secondary)
            Spacer(minLength: 0)
            Button {
                isSelecting.toggle(); selectedIDs = []; editingID = nil
            } label: {
                Label(isSelecting ? "Done" : "Select", systemImage: "checklist")
                    .font(LitheTheme.uiFont(size: 11))
            }.buttonStyle(.bordered).controlSize(.small)
                .accessibilityIdentifier("agent-history-select")
            Button { feature.refreshSessions() } label: {
                if feature.isRefreshingSessions { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(.bordered).controlSize(.small)
                .disabled(!feature.canRefreshSessions || feature.isRefreshingSessions)
                .help("Refresh history")
                .accessibilityIdentifier("agent-history-refresh")
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search conversation titles or IDs…", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("agent-history-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.litheNoPress).help("Clear search")
                } else { Image(systemName: "magnifyingglass") }
            }
            .font(LitheTheme.uiFont(size: 12))
            .padding(.horizontal, 10).frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AgentPanelStyle.border))
            LitheMenu {
                for mode in AgentHistoryFilter.allCases {
                    LitheContextMenuItem.action(mode.menuTitle, checked: mode == filter) { filter = mode }
                }
            } label: {
                Image(systemName: filter == .favorites ? "star.fill" : "line.3.horizontal.decrease")
            }
            .buttonStyle(.litheNoPress)
                .fixedSize()
                .frame(width: 24).help(filter.title)
                .accessibilityIdentifier("agent-history-filter")
        }.foregroundStyle(AgentPanelStyle.secondary)
    }

    @ViewBuilder private var emptyState: some View {
        if feature.isRefreshingSessions {
            AgentEmptyStateView(systemImage: "clock", title: "Loading history…", message: "", isBusy: true)
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AgentEmptyStateView(systemImage: "magnifyingglass", title: "No matching conversations",
                               message: String(localized: "Try another title or session ID."))
        } else {
            AgentEmptyStateView(systemImage: "clock.arrow.circlepath", title: "No earlier conversations",
                               message: String(localized: "Conversations for this project and Agent appear here."))
        }
    }

    private func row(_ session: AgentSessionSummary) -> some View {
        AgentHistoryRow(
            session: session, title: displayTitle(session), agentName: agentName,
            messageCount: AgentHistoryPresentation.messageCount(feature.conversations[session.id]),
            isCurrent: session.id == feature.selectedSessionID,
            isFavorite: history.metadata[session.id]?.isFavorite == true,
            isRemoved: filter == .removed, isSelecting: isSelecting,
            isSelected: selectedIDs.contains(session.id), isEditing: editingID == session.id,
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
        AgentSessionTitle.title(of: AgentSessionSummary(id: session.id, title: history.title(for: session)))
    }

    private var divider: some View { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
}

private struct AgentHistoryRow: View {
    let session: AgentSessionSummary
    let title: String
    let agentName: String?
    let messageCount: Int?
    let isCurrent: Bool
    let isFavorite: Bool
    let isRemoved: Bool
    let isSelecting: Bool
    let isSelected: Bool
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
                    Text(String(format: String(localized: "%d messages"), messageCount))
                        .lineLimit(1)
                    Text("·")
                }
                Text(String(session.id.prefix(8))).font(LitheTheme.uiFont(size: 10, design: .monospaced))
                    .help(session.id)
                icon(isCopied ? "checkmark" : "doc.on.doc", "Copy session ID", onCopy)
                    .accessibilityIdentifier("agent-history-copy-\(session.id)")
                Spacer(minLength: 0)
                if !isSelecting && !isEditing {
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
        .background(isSelected ? AgentPanelStyle.selected : (isHovering || isCurrent ? AgentPanelStyle.header : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(AgentPanelStyle.border).frame(height: 1) }
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("agent-history-row-\(session.id)")
    }

    private func icon(_ name: String, _ title: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(LitheTheme.uiFont(size: 11)).frame(width: 22, height: 22) }
            .buttonStyle(.litheNoPress).lithePointer().help(title).accessibilityLabel(title)
    }
}
