import AppKit
import SwiftUI
import LitheAgentConversationModule

/// Direct session switching; full history management retains its existing page.
struct AgentHistoryPopover: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: AgentConnectionModel
    @ObservedObject var history: AgentHistoryFeatureModel
    let agentName: String?
    let onSelect: (String) -> Void
    let onManage: () -> Void
    let onSearch: () -> Void
    let onDismiss: () -> Void
    var isToolWindow = false
    @State private var highlightedID: String?

    private var sessions: [AgentSessionSummary] {
        AgentHistoryPresentation.popupSessions(feature.sessions, openSessionIDs: feature.openSessionIDs, metadata: history.metadata, selectedSessionID: feature.selectedSessionID, locale: locale)
    }

    var body: some View {
        // Computed once per update; the list, empty state and reconciliation share it.
        let sessions = sessions
        VStack(spacing: LitheDropdownMetrics.popupPadding) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            Button { onSelect(session.id) } label: {
                                HStack(spacing: LitheDropdownMetrics.itemHorizontalPadding) {
                                    AgentBrandIcon(name: agentName, size: LitheDropdownMetrics.iconSize, style: .brand)
                                    Text(AgentHistoryPresentation.popupTitle(session,
                                        metadata: history.metadata[session.id], conversation: feature.conversations[session.id], locale: locale))
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                    if let date = AgentHistoryPresentation.date(session.updatedAt) {
                                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                            .font(LitheTheme.smallFont).lineLimit(1).fixedSize()
                                    }
                                }
                            }
                            .buttonStyle(LitheDropdownRowStyle(isSelected: session.id == highlightedID, tracksHover: false))
                            .disabled(!canSelect(session.id))
                            .onHover { if $0, canSelect(session.id), highlightedID != session.id { highlightedID = session.id } }
                            .id(session.id)
                            .accessibilityIdentifier("agent-history-popup-session-\(session.id)")
                        }
                        if sessions.isEmpty {
                            Text(feature.isRefreshingSessions ? "Loading history…" : "No earlier conversations")
                                .font(LitheTheme.settingsFont).foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(LitheDropdownMetrics.itemHorizontalPadding)
                        }
                    }
                }
                .litheScrollViewChrome()
                .onChange(of: highlightedID) { id in if let id { proxy.scrollTo(id) } }
            }
            .frame(height: isToolWindow ? nil : LitheDropdownMetrics.historyViewportHeight)
            .frame(maxHeight: isToolWindow ? .infinity : nil)
            if let error = feature.historyError ?? history.errorMessage {
                LitheBanner(status: .error) { Text(AgentLocalization.message(error, locale: locale)).textSelection(.enabled) }
            }
            if !isToolWindow {
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
                HStack {
                    Button("Search conversation", action: onSearch)
                    Spacer(minLength: 0)
                    Button("Conversation history", action: onManage)
                }
                .buttonStyle(LitheBannerActionStyle())
                .padding(.horizontal, LitheDropdownMetrics.itemHorizontalPadding)
            }
        }
        .padding(LitheDropdownMetrics.popupPadding)
        .frame(width: isToolWindow ? nil : LitheDropdownMetrics.maximumWidth)
        .onAppear {
            reconcileSelection()
            feature.refreshSessions()
        }
        .onChange(of: sessions.map(\.id)) { _ in reconcileSelection() }
        .onChange(of: feature.selectedSessionID) { _ in reconcileSelection() }
        .litheDropdownKeyHandler(handleKey)
        .onExitCommand(perform: onDismiss)
        .accessibilityIdentifier("agent-history-popup")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return false }
        switch event.keyCode {
        case 125, 126:
            guard !sessions.isEmpty else { return false }
            let index = sessions.firstIndex { $0.id == highlightedID } ?? 0
            let offset = event.keyCode == 125 ? 1 : -1
            highlightedID = sessions[min(max(0, index + offset), sessions.count - 1)].id
            return true
        case 36, 76:
            guard let id = highlightedID, canSelect(id),
                  sessions.contains(where: { $0.id == id }) else { return false }
            onSelect(id)
            return true
        default: return false
        }
    }

    private func canSelect(_ id: String) -> Bool {
        id == feature.selectedSessionID || feature.conversations[id]?.isAttached == true
            || (feature.connectionState == .ready && feature.canLoadSessions)
    }

    private func reconcileSelection() {
        if let selected = feature.selectedSessionID, sessions.contains(where: { $0.id == selected }) {
            highlightedID = selected
        } else if !sessions.contains(where: { $0.id == highlightedID }) {
            highlightedID = sessions.first?.id
        }
    }
}
