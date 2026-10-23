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
    var sessionID: String? = nil
    var isResponding = false
    var isReviewing = false
    var reviewError: String? = nil
    /// Marks the Agent's saved edits as reviewed; files are left as they are.
    var onKeep: ([AgentFileChange]) -> Void = { _ in }
    /// Reverses only the reported Agent edits after the user confirms.
    var onRestore: ([AgentFileChange]) async -> Void = { _ in }
    var showsSubscriptionQuota = false
    var subscriptionQuota: AgentSubscriptionQuota? = nil
    var subscriptionAccount: String? = nil
    var quotaFailure: String? = nil
    var activity: AgentActivitySummaryBar? = nil
    var onOpenFile: (AgentToolDetails.Location) -> Void = { _ in }
    @AppStorage("lithe.agent.editor.detailsCollapsed") private var collapsedRaw = ""
    @State private var showsAllChanges = false
    @State private var selectedDiff: AgentFileChange?
    @State private var confirmation: [AgentFileChange]?
    @State private var restoration: Restoration?
    @Environment(\.locale) private var locale

    private struct Restoration {
        let id = UUID()
        let changes: [AgentFileChange]
    }

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
        .sheet(item: $selectedDiff) { change in
            AgentFileDiffView(change: change, onOpenFile: onOpenFile)
        }
        .alert("Roll back Agent changes?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button("Roll back", role: .destructive) {
                if let confirmation { restoration = Restoration(changes: confirmation) }
                confirmation = nil
            }
        } message: {
            Text("Only the reported Agent edits will be reversed. Conflicting changes and unsaved editor changes will be preserved.")
        }
        .task(id: restoration?.id) {
            guard let restoration else { return }
            await onRestore(restoration.changes)
            self.restoration = nil
        }
        .onChange(of: sessionID) { _ in
            selectedDiff = nil
            confirmation = nil
            showsAllChanges = false
        }
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

    /// The single entry for reviewing this conversation's edits: totals, keep or
    /// roll back everything, and per-file diff, open and roll back.
    @ViewBuilder private var changesContent: some View {
        if changes.isEmpty && !isReviewing && reviewError == nil {
            Text("No file edits").font(LitheTheme.uiFont(size: 12)).foregroundStyle(AgentPanelStyle.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !changes.isEmpty {
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
                    HStack(spacing: LitheTheme.ActionButton.spacing) {
                        Button("Keep all") { onKeep(changes) }
                            .disabled(isResponding || isReviewing || changes.contains(where: \.isPending))
                            .help("The Agent already saved these files. Mark the current changes as reviewed.")
                            .accessibilityIdentifier("agent-edits-keep-all")
                        Button("Roll back all", role: .destructive) { confirmation = changes }
                            .disabled(isResponding || isReviewing || !changes.allSatisfy(\.canRevert))
                            .accessibilityIdentifier("agent-edits-revert-all")
                        if isReviewing { ProgressView().controlSize(.mini) }
                    }
                    .buttonStyle(LitheActionButtonStyle())
                    .font(LitheTheme.uiFont(size: 11))
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
                if let reviewError {
                    LitheBanner(status: .error) { Text(reviewError).textSelection(.enabled) }
                }
            }
        }
    }

    private func changeRow(_ change: AgentFileChange) -> some View {
        AgentEditorChangeRow(
            change: change,
            canRollBack: !isResponding && !isReviewing && change.canRevert,
            onOpen: { onOpenFile(AgentToolDetails.Location(path: change.path)) },
            onDiff: { selectedDiff = change },
            onRollBack: { confirmation = [change] })
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

/// One edited file in the Changes card. Diff and roll back appear on hover so the
/// list stays as quiet as a plain file list.
private struct AgentEditorChangeRow: View {
    let change: AgentFileChange
    let canRollBack: Bool
    let onOpen: () -> Void
    let onDiff: () -> Void
    let onRollBack: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: change.isDeletion ? "doc.badge.minus" : "doc.text")
                        .foregroundStyle(change.isDeletion ? LitheTheme.error : AgentPanelStyle.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((change.path as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(AgentPanelStyle.text)
                        Text(verbatim: Self.directory(of: change.path))
                            .font(LitheTheme.uiFont(size: 11))
                            .foregroundStyle(AgentPanelStyle.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(change.path)
            .accessibilityIdentifier("agent-edits-open-\(change.path)")
            if isHovering {
                Button(action: onDiff) {
                    LitheSystemIcon(systemImage: "rectangle.split.2x1", size: LitheTheme.Metrics.toolbarIconSize)
                }
                .litheToolbarIconButton()
                .disabled(change.diffs.isEmpty)
                .help("Show Agent diff")
                .accessibilityIdentifier("agent-edits-diff-\(change.path)")
                Button(action: onRollBack) {
                    LitheSystemIcon(systemImage: "arrow.uturn.backward", size: LitheTheme.Metrics.toolbarIconSize)
                }
                .litheToolbarIconButton()
                .disabled(!canRollBack)
                .help(change.canRevert ? "Roll back Agent changes" : "Original content is missing or incomplete.")
                .accessibilityIdentifier("agent-edits-revert-\(change.path)")
            } else {
                HStack(spacing: 6) {
                    if let additions = change.additions, additions > 0 {
                        Text(verbatim: "+\(additions)").foregroundStyle(LitheTheme.success)
                    }
                    if let deletions = change.deletions, deletions > 0 {
                        Text(verbatim: "−\(deletions)").foregroundStyle(LitheTheme.error)
                    }
                }
            }
        }
        .font(LitheTheme.uiFont(size: 12)).monospacedDigit()
        .frame(minHeight: 32)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier("agent-details-change-\(change.path)")
    }

    /// The last two folders, enough to tell same-named files apart.
    static func directory(of path: String) -> String {
        let folders = (path as NSString).deletingLastPathComponent.split(separator: "/")
        return folders.suffix(2).joined(separator: "/")
    }
}
