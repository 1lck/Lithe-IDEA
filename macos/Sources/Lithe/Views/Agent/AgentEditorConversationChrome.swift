import SwiftUI
import LitheAgentConversationModule
import LitheGitModule

/// Layout constants of the conversation when it is hosted as an editor tab.
enum AgentEditorConversationMetrics {
    static let headerHeight: CGFloat = 40
    static let detailsWidth: CGFloat = 264
    /// The details column is shown only when the centered column keeps its full width.
    static let detailsMinimumTotalWidth = AgentPanelStyle.editorContentMaximumWidth + detailsWidth + 48
}

/// Editor-tab header: conversation title on the leading edge, chat actions on the trailing edge.
struct AgentEditorChatHeader: View {
    @Environment(\.locale) private var locale
    let agentName: String?
    let conversationTitle: String?
    let historyPopup: (@escaping () -> Void) -> AnyView
    let onNew: (() -> Void)?
    let onSearch: () -> Void
    let showsDetails: Bool
    let onToggleDetails: () -> Void
    let onMoveToToolWindow: () -> Void
    let onOpenSettings: () -> Void
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onCopyConversation: (() -> Void)? = nil
    var showsToolbar = true
    var onToggleToolbar: (() -> Void)? = nil
    var activity: AgentActivitySummaryBar? = nil
    @State private var showsHistoryPopup = false

    var body: some View {
        HStack(spacing: 4) {
            Button { showsHistoryPopup.toggle() } label: {
                HStack(spacing: LitheTheme.MainToolbar.comboIconTextGap) {
                    AgentBrandIcon(name: agentName, size: LitheTheme.Metrics.toolbarIconSize, style: .brand)
                    Text(conversationTitle ?? AgentLocalization.string("New Chat", locale: locale))
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    LitheIDEAIcon(resourcePath: "expui/general/chevronDown.svg", size: LitheTheme.Metrics.toolbarIconSize,
                                  fallbackSystemImage: "chevron.down", preservesOriginalColors: true)
                }
                .padding(.leading, LitheTheme.MainToolbar.comboInsets.leading)
                .padding(.trailing, LitheTheme.MainToolbar.comboInsets.trailing)
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.MainToolbar.comboHeight, isIconOnly: false))
            .litheDropdown(isPresented: $showsHistoryPopup) { historyPopup { showsHistoryPopup = false } }
            .help("Conversation history")
            .accessibilityIdentifier("agent-editor-history-open")
            if let activity { activity.id(activity.sessionID) }
            Spacer(minLength: 8)
            iconButton("expui/general/search.svg", fallback: "magnifyingglass", help: "Search conversation",
                       identifier: "agent-editor-search", action: onSearch)
            iconButton("expui/general/add.svg", fallback: "plus", help: "New conversation",
                       identifier: "agent-editor-new-chat", action: { onNew?() })
                .disabled(onNew == nil)
            Button(action: onToggleDetails) {
                LitheIDEAIcon(resourcePath: "expui/status/info.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "info.circle", preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: showsDetails))
            .help(showsDetails ? "Hide Session Details" : "Show Session Details")
            .accessibilityIdentifier("agent-editor-details")
            Button(action: onMoveToToolWindow) {
                LitheIDEAIcon(resourcePath: "expui/general/previewVertically.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "rectangle.rightthird.inset.filled", preservesOriginalColors: true)
            }
            .buttonStyle(LitheIconButtonStyle(size: LitheTheme.Metrics.toolbarIconButtonSize, isSelected: true))
            .help("Show Chats in the AI Tool Window")
            .accessibilityIdentifier("agent-chat-location")
            LitheMenu {
                LitheContextMenuItem.action("Rename Chat", isEnabled: onRename != nil) { onRename?() }
                LitheContextMenuItem.action("Copy Conversation", isEnabled: onCopyConversation != nil) { onCopyConversation?() }
                LitheContextMenuItem.action("Delete Chat",
                    icon: AnyView(LitheIDEAIcon(resourcePath: "expui/general/delete.svg", size: LitheDropdownMetrics.iconSize,
                                               fallbackSystemImage: "trash", preservesOriginalColors: true)),
                    role: .destructive, isEnabled: onDelete != nil) { onDelete?() }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Settings…", action: onOpenSettings)
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Show Toolbar", checked: showsToolbar, leadingCheckmark: true,
                                            isEnabled: onToggleToolbar != nil) { onToggleToolbar?() }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/moreVertical.svg", size: LitheTheme.Metrics.toolbarIconSize,
                              fallbackSystemImage: "ellipsis", preservesOriginalColors: true)
            }
            .litheToolbarIconButton()
            .help("Chat options")
            .accessibilityIdentifier("agent-header-options")
        }
        .padding(.leading, AgentPanelStyle.headerLeadingInset)
        .padding(.trailing, 8)
        .frame(height: AgentEditorConversationMetrics.headerHeight)
        .foregroundStyle(AgentPanelStyle.text)
        .litheWorkbenchSurface(AgentPanelStyle.canvas)
        .overlay(alignment: .bottom) { Divider().overlay(LitheTheme.divider) }
    }

    private func iconButton(_ resource: String, fallback: String, help: LocalizedStringKey, identifier: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LitheIDEAIcon(resourcePath: resource, size: LitheTheme.Metrics.toolbarIconSize,
                          fallbackSystemImage: fallback, preservesOriginalColors: true)
        }
        .litheToolbarIconButton()
        .help(help)
        .accessibilityIdentifier(identifier)
    }
}

/// Session statistics drawn as a tab attached to the editor composer's top
/// edge. Turns and tokens keep their hover cards; the context entry opens the
/// collapsible breakdown on click.
struct AgentEditorStatusStrip: View {
    let statistics: AgentSessionStatistics?
    let contextUsage: AgentContextUsage?
    @Environment(\.agentUsesSubscription) private var usesSubscription
    @State private var showsContext = false

    var body: some View {
        HStack(spacing: 10) {
            if let statistics {
                AgentSessionStatusView(statistics: statistics, contextUsage: contextUsage, showsContext: false)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            Button { showsContext.toggle() } label: {
                AgentContextUsageView(usage: contextUsage, composition: statistics?.modelCalls?.latestContext,
                                      showsHoverCard: false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .help("Show context breakdown")
            .litheDropdown(isPresented: $showsContext, opensUpward: true) {
                AgentContextPanel(usage: contextUsage, composition: statistics?.modelCalls?.latestContext)
                    .environment(\.agentUsesSubscription, usesSubscription)
                    .padding(14)
                    .frame(width: AgentContextPanel.popoverWidth)
            }
        }
        .font(LitheTheme.uiFont(size: 11))
        .foregroundStyle(AgentPanelStyle.secondary)
        .padding(.horizontal, 10)
        .frame(height: AgentComposerMetrics.contextHeight)
        .background(AgentPanelStyle.canvas.opacity(0.6), in: AgentTopRoundedRectangle(radius: 8))
        .overlay(AgentTopRoundedRectangle(radius: 8).stroke(LitheTheme.settingsControlBorder, lineWidth: 1))
        .accessibilityIdentifier("agent-editor-status")
    }
}

/// Rectangle with rounded top corners only; macOS 13 has no uneven rounded rectangle.
struct AgentTopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.height / 2, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
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
                section("MCP") { mcpRows }
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
        .overlay(alignment: .leading) { Divider().overlay(LitheTheme.divider) }
        .accessibilityIdentifier("agent-editor-details-panel")
    }

    @ViewBuilder
    private var mcpRows: some View {
        if let composition {
            AgentStatusRow("MCP tools", value: composition.mcpToolCount.formatted(.number.locale(locale)))
            AgentStatusRow("Context tokens",
                           value: "~" + AgentSessionStatusPresentation.compactTokens(composition.mcpToolTokens, locale: locale))
        } else {
            footnote("Turn on Model call statistics in Agent settings and reconnect to see the MCP tools sent with each request.")
        }
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
