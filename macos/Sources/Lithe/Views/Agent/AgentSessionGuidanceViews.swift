import SwiftUI
import LitheAgentConversationModule

/// The agent's reasoning, separate from its reply, styled like a tool group:
/// a quiet summary line over a rounded Markdown card. Long reasoning scrolls
/// inside the card and follows the stream. Open while it streams and
/// collapsed once the reply or a tool call follows; a search keeps it open.
struct AgentThoughtRow: View {
    @Environment(\.locale) private var locale
    let text: String
    let isStreaming: Bool
    var isSearching = false
    @Binding var expansion: AgentThoughtExpansion

    /// The card grows with short reasoning and scrolls past this height.
    static let maxCardHeight: CGFloat = 240

    @State private var contentHeight: CGFloat = 0

    private var isExpanded: Bool { expansion.isExpanded(isStreaming: isStreaming, isSearching: isSearching) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expansion.toggle(isStreaming: isStreaming, isSearching: isSearching) } label: {
                HStack(spacing: 5) {
                    if isStreaming { ProgressView().controlSize(.mini) }
                    Text(isStreaming ? "Thinking…" : "Thinking process").lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .font(LitheTheme.uiFont(size: 12.5))
                .foregroundStyle(LitheTheme.secondaryText)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .help(isExpanded ? "Hide thinking" : "Show thinking")
            .accessibilityValue(isExpanded ? AgentLocalization.string("Expanded", locale: locale) : AgentLocalization.string("Collapsed", locale: locale))

            if isExpanded { card }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var card: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    AgentMarkdownMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12)
                        .equatable()
                        .foregroundStyle(LitheTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 0).id(Self.bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AgentThoughtContentHeightKey.self, value: geometry.size.height)
                })
            }
            .litheScrollViewChrome()
            .frame(height: min(max(contentHeight, 1), Self.maxCardHeight))
            .onPreferenceChange(AgentThoughtContentHeightKey.self) { contentHeight = $0 }
            .onChange(of: text) { _ in
                if isStreaming { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onAppear { if isStreaming { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
        }
        .background(LitheTheme.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.panelBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static let bottomID = "agent-thought-bottom"
}

private struct AgentThoughtContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Search temporarily reveals a match without replacing the user's disclosure preference.
struct AgentThoughtExpansion: Equatable {
    private var userExpanded: Bool?

    func isExpanded(isStreaming: Bool, isSearching: Bool) -> Bool {
        isSearching || (userExpanded ?? isStreaming)
    }

    mutating func toggle(isStreaming: Bool, isSearching: Bool) {
        // A matching search must keep its text visible, including after a click.
        guard !isSearching else { return }
        userExpanded = !isExpanded(isStreaming: isStreaming, isSearching: false)
    }
}

/// Plan the agent reported for this conversation, pinned above the activity bar.
/// Collapsed it shows progress and the current step; it stays expandable after the turn.
struct AgentPlanView: View {
    @Environment(\.locale) private var locale
    let plan: AgentPlan
    let isResponding: Bool
    let embedded: Bool
    @State private var expanded = false

    init(plan: AgentPlan, isResponding: Bool, expanded: Bool = false, embedded: Bool = false) {
        self.plan = plan
        self.isResponding = isResponding
        self.embedded = embedded
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(LitheTheme.uiFont(size: 10.5))
                            .foregroundStyle(plan.isComplete ? LitheTheme.success : LitheTheme.accent)
                        Text(String(format: AgentLocalization.string("Plan %lld/%lld", locale: locale), plan.completedCount, plan.entries.count))
                            .font(LitheTheme.uiFont(size: 11.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                            .monospacedDigit()
                        if !expanded, let current = plan.currentEntry {
                            Text(current.content)
                                .font(LitheTheme.uiFont(size: 11.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        LitheIDEAIcon(resourcePath: expanded ? "expui/general/chevronDown.svg" : "expui/general/chevronUp.svg",
                                      size: LitheTheme.Metrics.toolbarIconSize, preservesOriginalColors: true)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(LitheIconButtonStyle(size: 28, isIconOnly: false))
                .help(expanded ? "Hide plan" : "Show plan")
            }

            if expanded || embedded {
                if !embedded { Rectangle().fill(LitheTheme.panelBorder).frame(height: 1) }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .litheScrollViewChrome()
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(embedded ? Color.clear : AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(embedded ? Color.clear : AgentPanelStyle.border, lineWidth: 1))
        .padding(.horizontal, embedded ? 0 : 18)
        .padding(.bottom, embedded ? 0 : 4)
    }

    private func entryRow(_ entry: AgentPlan.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon(entry.status))
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(color(entry.status))
            Text(entry.content)
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(label(entry.status))
    }

    private func icon(_ status: AgentPlan.Entry.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: isResponding ? "circle.dotted" : "circle.lefthalf.filled"
        case .pending: "circle"
        }
    }

    private func color(_ status: AgentPlan.Entry.Status) -> Color {
        switch status {
        case .completed: LitheTheme.success
        case .inProgress: LitheTheme.accent
        case .pending: LitheTheme.tertiaryText
        }
    }

    private func label(_ status: AgentPlan.Entry.Status) -> String {
        switch status {
        case .completed: AgentLocalization.string("Completed", locale: locale)
        case .inProgress: AgentLocalization.string("Running", locale: locale)
        case .pending: AgentLocalization.string("Pending", locale: locale)
        }
    }
}

/// Slash commands matching the draft, shown above the writing area.
struct AgentCommandSuggestionList: View {
    @Environment(\.locale) private var locale
    let commands: [AgentCommand]
    let highlightedIndex: Int
    let onSelect: (AgentCommand) -> Void
    var maximumHeight: CGFloat = defaultMaximumHeight
    static let defaultMaximumHeight: CGFloat = 168
    /// One complete command row including the list's vertical padding and border.
    static let minimumHeight = rowHeight + 2 * contentInset + 2 * borderInset
    private static let rowHeight: CGFloat = 26
    private static let contentInset: CGFloat = 3
    private static let borderInset: CGFloat = 1

    var height: CGFloat {
        let contentHeight = commands.isEmpty ? Self.rowHeight
            : min(maximumHeight, CGFloat(commands.count) * Self.rowHeight + 2 * Self.contentInset)
        return contentHeight + 2 * Self.borderInset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                row(command, isHighlighted: index == highlightedIndex).id(command.id)
                            }
                        }
                        .padding(.vertical, Self.contentInset)
                    }
                    .frame(maxHeight: maximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: highlightedIndex) { index in
                        if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 7))
        .padding(Self.borderInset)
        .frame(height: height)
        .accessibilityLabel("Agent commands")
    }

    private func row(_ command: AgentCommand, isHighlighted: Bool) -> some View {
        Button { onSelect(command) } label: {
            HStack(spacing: 8) {
                Text(command.invocation)
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AgentPanelStyle.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(command.description)
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheDropdownRowStyle(isSelected: isHighlighted))
        .help(command.hint.map { "\(command.invocation) \($0)" } ?? command.description)
    }
}
