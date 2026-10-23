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
/// Each section folds independently and remembers its state across launches.
struct AgentEditorDetailsPanel: View {
    let statistics: AgentSessionStatistics?
    let contextUsage: AgentContextUsage?
    /// `nil` hides the section where the host cannot see the transcript's edits.
    var changes: [AgentFileChange]? = nil
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    var onClose: (() -> Void)? = nil
    @AppStorage("lithe.agent.editor.detailsCollapsed") private var collapsedRaw = ""
    @Environment(\.locale) private var locale

    private enum Section: String { case context, changes, session }

    private var composition: AgentModelCall.Context? { statistics?.modelCalls?.latestContext }
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
                if let onClose {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: onClose) {
                            LitheIDEAIcon(resourcePath: "expui/general/close.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                          fallbackSystemImage: "xmark", preservesOriginalColors: true)
                        }
                        .litheToolbarIconButton()
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("agent-context-close")
                    }
                }
                section(.context, title: "Context", summary: contextUsage.map {
                    AgentContextUsagePresentation.percentage($0, locale: locale)
                }) {
                    AgentContextPanel(usage: contextUsage, composition: composition, showsHeader: false)
                }
                if let changes {
                    section(.changes, title: "Changes", summary: changes.isEmpty ? nil : String(changes.count)) {
                        changesList(changes)
                    }
                }
                if let statistics {
                    section(.session, title: "Session", summary: nil) {
                        AgentSessionSummaryCard(statistics: statistics)
                        if let tokens = statistics.tokens { AgentTokenUsageCard(tokens: tokens) }
                    }
                }
            }
            .environment(\.agentStatusCardIsInline, true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .litheScrollViewChrome()
        .frame(width: AgentEditorConversationMetrics.detailsWidth)
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .overlay(alignment: .leading) { LitheTheme.divider.frame(width: 1) }
        .accessibilityIdentifier("agent-editor-details-panel")
    }

    @ViewBuilder private func changesList(_ changes: [AgentFileChange]) -> some View {
        if changes.isEmpty {
            Text("No file edits").font(LitheTheme.uiFont(size: 11.5)).foregroundStyle(AgentPanelStyle.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let totals = AgentActivitySummaryPresentation.lineTotals(changes) {
                    HStack(spacing: 6) {
                        Text(verbatim: "+\(totals.additions)").foregroundStyle(LitheTheme.success)
                        Text(verbatim: "−\(totals.deletions)").foregroundStyle(LitheTheme.error)
                    }
                    .font(LitheTheme.uiFont(size: 11)).monospacedDigit().padding(.bottom, 2)
                }
                ForEach(changes) { change in changeRow(change) }
            }
        }
    }

    private func changeRow(_ change: AgentFileChange) -> some View {
        Button { onOpenFile(AgentToolDetails.Location(path: change.path)) } label: {
            HStack(spacing: 6) {
                Image(systemName: change.isDeletion ? "doc.badge.minus" : "doc.text")
                    .foregroundStyle(change.isDeletion ? LitheTheme.error : AgentPanelStyle.secondary)
                Text((change.path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                if let additions = change.additions, additions > 0 {
                    Text(verbatim: "+\(additions)").foregroundStyle(LitheTheme.success)
                }
                if let deletions = change.deletions, deletions > 0 {
                    Text(verbatim: "−\(deletions)").foregroundStyle(LitheTheme.error)
                }
            }
            .font(LitheTheme.uiFont(size: 11.5)).monospacedDigit()
            .frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover()
        .help(change.path)
        .accessibilityIdentifier("agent-details-change-\(change.path)")
    }

    private func section<Content: View>(_ id: Section, title: LocalizedStringKey, summary: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.contains(id.rawValue)
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggle(id) } label: {
                HStack(spacing: 6) {
                    Text(title).font(LitheTheme.uiFont(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Spacer(minLength: 0)
                    if let summary { Text(verbatim: summary).font(LitheTheme.uiFont(size: 11)).monospacedDigit() }
                }
                .foregroundStyle(isCollapsed ? AgentPanelStyle.secondary : AgentPanelStyle.text)
                .frame(minHeight: 26).contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
            .accessibilityIdentifier("agent-details-section-\(id.rawValue)")
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .font(LitheTheme.uiFont(size: 12))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ id: Section) {
        var set = collapsed
        if !set.insert(id.rawValue).inserted { set.remove(id.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }
}
