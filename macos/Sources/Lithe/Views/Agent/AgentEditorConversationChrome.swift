import SwiftUI
import LitheAgentConversationModule

/// Layout constants of the conversation when it is hosted as an editor tab.
enum AgentEditorConversationMetrics {
    static let detailsWidth: CGFloat = 264
    static let detailsPopupHeight: CGFloat = 440
    /// Product breakpoint reserving usable conversation space beside the details column.
    static let detailsMinimumTotalWidth: CGFloat = 716 + detailsWidth + 48
}

/// Trailing details column of the editor conversation. It only rearranges
/// figures the session already reports; nothing here starts a new request.
struct AgentEditorDetailsPanel: View {
    let statistics: AgentSessionStatistics?
    let contextUsage: AgentContextUsage?
    var onClose: (() -> Void)? = nil

    private var composition: AgentModelCall.Context? { statistics?.modelCalls?.latestContext }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                AgentContextPanel(usage: contextUsage, composition: composition, onClose: onClose)
                if let statistics {
                    section("Session") {
                        AgentSessionSummaryCard(statistics: statistics)
                        if let tokens = statistics.tokens { AgentTokenUsageCard(tokens: tokens) }
                    }
                }
            }
            .environment(\.agentStatusCardIsInline, true)
            .padding(14)
        }
        .litheScrollViewChrome()
        .frame(width: AgentEditorConversationMetrics.detailsWidth)
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .overlay(alignment: .leading) { LitheTheme.divider.frame(width: 1) }
        .accessibilityIdentifier("agent-editor-details-panel")
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(AgentPanelStyle.muted)
            VStack(alignment: .leading, spacing: 6) { content() }
                .font(LitheTheme.uiFont(size: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
