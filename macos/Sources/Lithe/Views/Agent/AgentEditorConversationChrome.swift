import SwiftUI
import LitheAgentConversationModule

/// Layout constants of the conversation when it is hosted as an editor tab.
enum AgentEditorConversationMetrics {
    static let detailsWidth: CGFloat = 264
    static let detailsPopupHeight: CGFloat = 440
    /// Width of the editor tab's trailing card column.
    static let detailsColumnWidth: CGFloat = 300
    /// Product breakpoint reserving usable conversation space beside the details column.
    static let detailsMinimumTotalWidth: CGFloat = 716 + detailsColumnWidth + 48
}

/// Session details opened from the tool window composer. The editor tab uses
/// `AgentEditorDetailsColumn`; this popup keeps the tool window's own layout.
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

/// Trailing card column of the editor conversation, in the Claude Desktop
/// layout: one rounded card per section, each folding independently and
/// remembering its state. It only rearranges figures the session already
/// reports; nothing here starts a new request.
struct AgentEditorDetailsColumn: View {
    let statistics: AgentSessionStatistics?
    let contextUsage: AgentContextUsage?
    var changes: [AgentFileChange] = []
    var showsSubscriptionQuota = false
    var subscriptionQuota: AgentSubscriptionQuota? = nil
    var subscriptionAccount: String? = nil
    var quotaFailure: String? = nil
    var activity: AgentActivitySummaryBar? = nil
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    @AppStorage("lithe.agent.editor.detailsCollapsed") private var collapsedRaw = ""
    @State private var showsAllChanges = false
    @Environment(\.locale) private var locale

    private enum Section: String { case context, changes, activity, quota, session }
    /// Changes beyond this many files fold behind "Show more".
    private static let changePreviewCount = 5

    private var composition: AgentModelCall.Context? { statistics?.modelCalls?.latestContext }
    private var breakdown: AgentContextBreakdown { AgentContextBreakdown(usage: contextUsage, composition: composition) }
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var hasActivity: Bool { activity.map { $0.contentHeight > 0 } ?? false }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                card(.context, title: "Context") { contextContent }
                card(.changes, title: "Changes") { changesContent }
                if hasActivity, let activity {
                    card(.activity, title: "Activity") { activity }
                }
                if showsSubscriptionQuota {
                    card(.quota, title: "Quota") {
                        AgentSubscriptionQuotaView(quota: subscriptionQuota, account: subscriptionAccount, failure: quotaFailure)
                    }
                }
                if let statistics {
                    card(.session, title: "Session") {
                        AgentSessionSummaryCard(statistics: statistics)
                        if let tokens = statistics.tokens { AgentTokenUsageCard(tokens: tokens) }
                    }
                }
            }
            .environment(\.agentStatusCardIsInline, true)
            .padding(12)
        }
        .litheScrollViewChrome()
        .frame(width: AgentEditorConversationMetrics.detailsColumnWidth)
        .litheWorkbenchSurface(AgentPanelStyle.header)
        .overlay(alignment: .leading) { LitheTheme.divider.frame(width: 1) }
        .accessibilityIdentifier("agent-editor-details-panel")
    }

    // MARK: Context

    @ViewBuilder private var contextContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: String(format: AgentLocalization.string("Used %@", locale: locale),
                                      AgentContextUsagePresentation.percentage(contextUsage, locale: locale)))
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                    .foregroundStyle(AgentPanelStyle.text)
                Spacer(minLength: 8)
                if let capacity = breakdown.capacity(locale: locale) {
                    Text(verbatim: capacity).font(LitheTheme.uiFont(size: 12)).monospacedDigit()
                        .foregroundStyle(AgentPanelStyle.secondary)
                }
            }
            breakdown.bar
                .frame(height: 4)
                .clipShape(Capsule())
            VStack(spacing: 7) {
                ForEach(AgentContextBreakdown.Segment.allCases, id: \.self) { segment in
                    if segment != .mcpTools || (composition?.mcpToolCount ?? 0) > 0 {
                        legendRow(segment.title, color: segment.color,
                                  tokens: composition.map { segment.tokens($0) })
                    }
                }
                if let free = breakdown.freeTokens {
                    legendRow("Free space", color: AgentPanelStyle.border, tokens: free)
                }
            }
            if composition == nil {
                Text(contextUsage == nil
                     ? "The Agent has not reported context usage yet."
                     : "Turn on Model call statistics, reconnect and send a message to see the breakdown.")
                    .font(LitheTheme.uiFont(size: 10.5))
                    .foregroundStyle(AgentPanelStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("agent-context-panel")
    }

    private func legendRow(_ title: LocalizedStringKey, color: Color, tokens: UInt64?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(AgentPanelStyle.text)
            Spacer(minLength: 6)
            Text(verbatim: tokens.map { AgentSessionStatusPresentation.compactTokens($0, locale: locale) } ?? "—")
                .foregroundStyle(AgentPanelStyle.secondary).monospacedDigit()
            Text(verbatim: tokens.map { breakdown.share($0, locale: locale) } ?? "—")
                .foregroundStyle(AgentPanelStyle.text).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .font(LitheTheme.uiFont(size: 12))
    }

    // MARK: Changes

    @ViewBuilder private var changesContent: some View {
        if changes.isEmpty {
            Text("No file edits").font(LitheTheme.uiFont(size: 12)).foregroundStyle(AgentPanelStyle.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "plusminus.circle").foregroundStyle(AgentPanelStyle.secondary)
                    Text(verbatim: String(format: AgentLocalization.string("Modified files: %lld", locale: locale), Int64(changes.count)))
                        .lineLimit(1).foregroundStyle(AgentPanelStyle.text)
                    Spacer(minLength: 6)
                    if let totals = AgentActivitySummaryPresentation.lineTotals(changes) {
                        Text(verbatim: "+\(totals.additions)").foregroundStyle(LitheTheme.success)
                        Text(verbatim: "−\(totals.deletions)").foregroundStyle(LitheTheme.error)
                    }
                }
                .font(LitheTheme.uiFont(size: 12)).monospacedDigit()
                let visible = showsAllChanges ? changes : Array(changes.prefix(Self.changePreviewCount))
                ForEach(visible) { change in changeRow(change) }
                if changes.count > Self.changePreviewCount {
                    Button(showsAllChanges ? "Show less" : "Show more") { showsAllChanges.toggle() }
                        .buttonStyle(.litheNoPress)
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(AgentPanelStyle.secondary)
                        .accessibilityIdentifier("agent-details-changes-more")
                }
            }
        }
    }

    private func changeRow(_ change: AgentFileChange) -> some View {
        Button { onOpenFile(AgentToolDetails.Location(path: change.path)) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: change.isDeletion ? "doc.badge.minus" : "doc.text")
                    .foregroundStyle(change.isDeletion ? LitheTheme.error : AgentPanelStyle.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text((change.path as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(AgentPanelStyle.text)
                        Spacer(minLength: 4)
                        if let additions = change.additions, additions > 0 {
                            Text(verbatim: "+\(additions)").foregroundStyle(LitheTheme.success)
                        }
                        if let deletions = change.deletions, deletions > 0 {
                            Text(verbatim: "−\(deletions)").foregroundStyle(LitheTheme.error)
                        }
                    }
                    Text(verbatim: Self.directory(of: change.path))
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(AgentPanelStyle.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .font(LitheTheme.uiFont(size: 12)).monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .help(change.path)
        .accessibilityIdentifier("agent-details-change-\(change.path)")
    }

    /// The last two folders, enough to tell same-named files apart.
    static func directory(of path: String) -> String {
        let folders = (path as NSString).deletingLastPathComponent.split(separator: "/")
        return folders.suffix(2).joined(separator: "/")
    }

    // MARK: Card

    private func card<Content: View>(_ id: Section, title: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.contains(id.rawValue)
        return VStack(alignment: .leading, spacing: 12) {
            Button { toggle(id) } label: {
                HStack(spacing: 6) {
                    Text(title).font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(LitheTheme.uiFont(size: 7))
                        .foregroundStyle(AgentPanelStyle.secondary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AgentPanelStyle.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
            .accessibilityIdentifier("agent-details-section-\(id.rawValue)")
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .font(LitheTheme.uiFont(size: 12))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgentPanelStyle.border, lineWidth: 1))
    }

    private func toggle(_ id: Section) {
        var set = collapsed
        if !set.insert(id.rawValue).inserted { set.remove(id.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }
}
