import SwiftUI
import LitheAgentConversationModule
import LitheGitModule

/// Layout constants of the conversation when it is hosted as an editor tab.
enum AgentEditorConversationMetrics {
    static let detailsWidth: CGFloat = 264
    static let detailsPopupHeight: CGFloat = 440
    /// Product breakpoint reserving usable conversation space beside the details column.
    static let detailsMinimumTotalWidth: CGFloat = 716 + detailsWidth + 48
}

/// Trailing details column of the editor conversation. It only rearranges
/// figures the session already reports; nothing here starts a new request.
struct AgentEditorDetailsPanel<Workspace: View>: View {
    @Environment(\.locale) private var locale
    let statistics: AgentSessionStatistics?
    let contextUsage: AgentContextUsage?
    let fileChanges: [AgentFileChange]
    @ViewBuilder let workspace: () -> Workspace

    private var composition: AgentModelCall.Context? { statistics?.modelCalls?.latestContext }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                AgentContextPanel(usage: contextUsage, composition: composition)
                section("Changes") {
                    workspace()
                    changeRows
                }
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

    @ViewBuilder
    private var changeRows: some View {
        if fileChanges.isEmpty {
            footnote("This conversation has not edited any files.")
        } else {
            let additions = fileChanges.compactMap(\.additions).reduce(0, +)
            let deletions = fileChanges.compactMap(\.deletions).reduce(0, +)
            HStack(spacing: 6) {
                Text("Agent edits").foregroundStyle(AgentPanelStyle.secondary).lineLimit(1)
                Spacer(minLength: 12)
                Text(verbatim: "+\(additions)").foregroundStyle(LitheTheme.success)
                Text(verbatim: "-\(deletions)").foregroundStyle(LitheTheme.error)
            }
            .monospacedDigit()
            AgentStatusRow("Edited files", value: fileChanges.count.formatted(.number.locale(locale)))
        }
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

    private func footnote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(LitheTheme.uiFont(size: 10.5))
            .foregroundStyle(AgentPanelStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Current branch and working-tree change count from the Git module, observed
/// directly because AppModel does not relay this optional module's changes.
struct AgentEditorGitSummary: View {
    let feature: GitFeatureModel?

    var body: some View {
        if let feature { AgentEditorGitRows(feature: feature) }
    }
}

private struct AgentEditorGitRows: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: GitFeatureModel

    var body: some View {
        if feature.gitRepositoryRoot != nil {
            AgentStatusRow("Branch", value: feature.currentBranch)
            AgentStatusRow("Changed files", value: feature.gitChanges.count.formatted(.number.locale(locale)))
        }
    }
}
