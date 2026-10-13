import SwiftUI
import LitheAgentConversationModule

/// The agent's reasoning, separate from its reply. Open while it streams and
/// collapsed once the reply or a tool call follows; a search keeps it open.
struct AgentThoughtRow: View {
    let text: String
    let isStreaming: Bool
    var isSearching = false
    @Binding var expansion: AgentThoughtExpansion

    private var isExpanded: Bool { expansion.isExpanded(isStreaming: isStreaming, isSearching: isSearching) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expansion.toggle(isStreaming: isStreaming, isSearching: isSearching) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 10.5))
                    Text(isStreaming ? "Thinking…" : "Thinking process")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(LitheTheme.tertiaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
            .help(isExpanded ? "Hide thinking" : "Show thinking")
            .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))

            if isExpanded {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(LitheTheme.panelBorder).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Search temporarily reveals a match without replacing the user's disclosure preference.
struct AgentThoughtExpansion {
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
                            .font(.system(size: 10.5))
                            .foregroundStyle(plan.isComplete ? LitheTheme.success : LitheTheme.accent)
                        Text(String(format: String(localized: "Plan %lld/%lld"), plan.completedCount, plan.entries.count))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                            .monospacedDigit()
                        if !expanded, let current = plan.currentEntry {
                            Text(current.content)
                                .font(.system(size: 11.5))
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
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
                .font(.system(size: 10.5))
                .foregroundStyle(color(entry.status))
            Text(entry.content)
                .font(.system(size: 11.5))
                .foregroundStyle(entry.status == .completed ? LitheTheme.tertiaryText : LitheTheme.primaryText)
                .strikethrough(entry.status == .completed, color: LitheTheme.tertiaryText)
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
        case .completed: String(localized: "Completed")
        case .inProgress: String(localized: "Running")
        case .pending: String(localized: "Pending")
        }
    }
}

/// Slash commands matching the draft, shown above the writing area.
struct AgentCommandSuggestionList: View {
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
                    .font(.system(size: 11.5))
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
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AgentPanelStyle.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(command.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(isHighlighted ? AgentPanelStyle.focus.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover()
        .help(command.hint.map { "\(command.invocation) \($0)" } ?? command.description)
    }
}
