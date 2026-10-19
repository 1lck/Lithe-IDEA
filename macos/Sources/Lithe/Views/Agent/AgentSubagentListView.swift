import SwiftUI
import LitheAgentConversationModule

/// Read-only monitoring of native child sessions. Expanding a child uses the
/// output already delivered by ACP; it never polls logs or creates another agent.
struct AgentSubagentListView: View {
    let subagents: [AgentSubagent]
    let messages: [AgentConversationMessage]
    let onOpenFile: (AgentToolDetails.Location) -> Void
    @Environment(\.locale) private var locale
    @State private var expandedID: String?
    @State private var contentHeight: CGFloat = 0

    private enum Metrics {
        static let rowHeight: CGFloat = 34
        static let maximumHeight: CGFloat = 264
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(subagents) { agent in
                    Button { expandedID = expandedID == agent.id ? nil : agent.id } label: {
                        HStack(spacing: 7) {
                            Image(systemName: icon(agent.state))
                                .foregroundStyle(color(agent.state))
                                .frame(width: 14)
                            Text(verbatim: agent.name.isEmpty ? AgentLocalization.string("Subagent", locale: locale) : agent.name)
                                .lineLimit(1)
                            Text(verbatim: agent.task)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: expandedID == agent.id ? "chevron.down" : "chevron.right")
                                .font(LitheTheme.uiFont(size: 9))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                        .font(LitheTheme.uiFont(size: 11.5))
                        .padding(.horizontal, 10)
                        .padding(.leading, CGFloat(min(agent.depth, 4)) * 8)
                        .frame(height: Metrics.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .litheRowHover()
                    .help(agent.task)
                    .accessibilityValue(stateTitle(agent.state))
                    .accessibilityIdentifier("agent-subagent-\(agent.id)")
                    if expandedID == agent.id {
                        AgentSubagentDetailsView(agent: agent,
                            messages: messages.filter { $0.subagentSessionID == agent.id }, onOpenFile: onOpenFile)
                            .id(agent.id)
                    }
                }
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AgentSubagentContentHeightKey.self, value: geometry.size.height)
            })
        }
        .litheScrollViewChrome()
        .frame(height: min(Metrics.maximumHeight, max(contentHeight, CGFloat(subagents.count) * Metrics.rowHeight)))
        .onPreferenceChange(AgentSubagentContentHeightKey.self) { contentHeight = $0 }
        .onChange(of: subagents.map(\.id)) { ids in
            if let expandedID, !ids.contains(expandedID) { self.expandedID = nil }
        }
    }

    private func icon(_ state: AgentSubagent.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        case .disconnected: "questionmark.circle"
        }
    }

    private func color(_ state: AgentSubagent.State) -> Color {
        switch state {
        case .running: LitheTheme.accent
        case .completed: LitheTheme.success
        case .failed: LitheTheme.error
        case .cancelled, .disconnected: LitheTheme.secondaryText
        }
    }

    private func stateTitle(_ state: AgentSubagent.State) -> String {
        let key: String.LocalizationValue = switch state {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .disconnected: "Disconnected"
        }
        return AgentLocalization.string(key, locale: locale)
    }
}

private struct AgentSubagentContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AgentSubagentDetailsView: View {
    let agent: AgentSubagent
    let messages: [AgentConversationMessage]
    let onOpenFile: (AgentToolDetails.Location) -> Void
    @Environment(\.locale) private var locale
    @State private var thoughtExpansion = AgentThoughtExpansion()

    var body: some View {
        let thought = messages.filter { $0.role == .thought }.map(\.text).joined(separator: "\n\n")
        let output = messages.filter { $0.role == .agent }.map(\.text).joined(separator: "\n\n")
        let tools = messages.filter { $0.role == .tool }
        VStack(alignment: .leading, spacing: 8) {
            if !agent.task.isEmpty {
                Text(verbatim: AgentLocalization.string("Subagent task", locale: locale)).foregroundStyle(LitheTheme.secondaryText)
                Text(verbatim: agent.task).textSelection(.enabled)
            }
            if !thought.isEmpty {
                AgentThoughtRow(text: thought, isStreaming: agent.state == .running, expansion: $thoughtExpansion)
            }
            if !tools.isEmpty {
                AgentToolGroupView(messages: tools, searchText: "", onOpenFile: onOpenFile, embedded: true)
            }
            if !output.isEmpty {
                Text(verbatim: AgentLocalization.string("Subagent output", locale: locale)).foregroundStyle(LitheTheme.secondaryText)
                AgentMarkdownMessage(text: output, size: 11.5).equatable()
            } else if messages.isEmpty {
                Text(verbatim: AgentLocalization.string("No subagent output yet", locale: locale)).foregroundStyle(LitheTheme.secondaryText)
            }
        }
        .font(LitheTheme.uiFont(size: 11.5))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("agent-subagent-details-\(agent.id)")
    }
}
