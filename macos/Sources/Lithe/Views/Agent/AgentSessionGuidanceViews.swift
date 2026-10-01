import SwiftUI
import LitheAgentConversationModule

/// The agent's reasoning, separate from its reply. Open while it streams and
/// collapsed once the reply or a tool call follows; a search keeps it open.
struct AgentThoughtRow: View {
    let text: String
    let isStreaming: Bool
    var isSearching = false
    /// nil follows the streaming state until the user toggles the row.
    @State private var userExpanded: Bool?

    private var isExpanded: Bool { userExpanded ?? (isStreaming || isSearching) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { userExpanded = !isExpanded } label: {
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

/// Plan the agent reported for this conversation, pinned above the activity bar.
/// Collapsed it shows progress and the current step; it stays expandable after the turn.
struct AgentPlanView: View {
    let plan: AgentPlan
    let isResponding: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            if expanded {
                Rectangle().fill(LitheTheme.panelBorder).frame(height: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.header, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(AgentPanelStyle.border, lineWidth: 1))
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentPanelStyle.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                row(command, isHighlighted: index == highlightedIndex).id(command.id)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .frame(maxHeight: 168)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: highlightedIndex) { index in
                        if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPanelStyle.context, in: RoundedRectangle(cornerRadius: 7))
        .padding(1)
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
            .frame(height: 26)
            .background(isHighlighted ? AgentPanelStyle.focus.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .litheRowHover()
        .help(command.hint.map { "\(command.invocation) \($0)" } ?? command.description)
    }
}
