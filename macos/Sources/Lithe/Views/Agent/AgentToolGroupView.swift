import SwiftUI
import LitheAgentConversationModule

/// Compact timeline for adjacent ACP tool calls in a conversation.
struct AgentToolGroupView: View {
    let messages: [AgentConversationMessage]
    let searchText: String
    let onOpenFile: (AgentToolDetails.Location) -> Void

    @State private var expanded = false
    @State private var expandedToolID: String?

    private var failedCount: Int { messages.filter { $0.toolStatus == .failed }.count }
    private var interruptedCount: Int { messages.filter { $0.toolStatus == .interrupted }.count }
    private var completedCount: Int { messages.filter { $0.toolStatus == .completed }.count }
    private var hasExpandedDetails: Bool {
        messages.contains { $0.id == expandedToolID && !$0.toolDetails.isEmpty }
    }
    private var displayedMessages: [AgentConversationMessage] {
        searchText.isEmpty ? messages : messages.filter { AgentTranscriptItem.toolMatches($0, searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text("Tool activity (\(messages.count))")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    summary
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(expanded ? "Hide tool details" : "Show tool details")

            if expanded {
                Rectangle()
                    .fill(LitheTheme.panelBorder)
                    .frame(height: 1)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayedMessages) { message in
                            toolRow(message)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .frame(height: CGFloat(min(displayedMessages.count, 4)) * 32 + (hasExpandedDetails ? 168 : 8))
            }
        }
        .frame(maxWidth: .infinity)
        .background(LitheTheme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(failedCount > 0 ? LitheTheme.error.opacity(0.7) : LitheTheme.panelBorder, lineWidth: 1)
        )
        .onAppear { if !searchText.isEmpty { expanded = true } }
        .onChange(of: searchText) { _ in if !searchText.isEmpty { expanded = true } }
    }

    @ViewBuilder
    private var summary: some View {
        if failedCount > 0 {
            Label("\(failedCount) failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.error)
        } else if interruptedCount > 0 {
            Label("\(interruptedCount) interrupted", systemImage: "pause.circle")
                .foregroundStyle(LitheTheme.warning)
        } else if completedCount == messages.count {
            Label("All completed", systemImage: "checkmark")
                .foregroundStyle(LitheTheme.success)
        } else {
            Text("\(completedCount)/\(messages.count) completed")
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private func toolRow(_ message: AgentConversationMessage) -> some View {
        let isExpanded = expandedToolID == message.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if !message.toolDetails.isEmpty {
                    expandedToolID = isExpanded ? nil : message.id
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Rectangle()
                            .fill(LitheTheme.panelBorder)
                            .frame(width: 1, height: 32)
                        Circle()
                            .fill(LitheTheme.tertiaryText)
                            .frame(width: 5, height: 5)
                    }
                    .frame(width: 16)
                    Text(message.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Circle()
                        .fill(statusColor(for: message.toolStatus))
                        .frame(width: 7, height: 7)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help(message.text)
            .accessibilityValue(statusLabel(for: message.toolStatus))

            if isExpanded && !message.toolDetails.isEmpty {
                AgentToolEvidenceView(details: message.toolDetails, onOpenFile: onOpenFile)
                    .padding(.leading, 24)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LitheTheme.toolHeaderInactive, in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func statusColor(for status: AgentConversationMessage.ToolStatus?) -> Color {
        switch status {
        case .completed: LitheTheme.success
        case .failed: LitheTheme.error
        case .interrupted: LitheTheme.warning
        case .inProgress: LitheTheme.warning
        case .pending, nil: LitheTheme.tertiaryText
        }
    }

    private func statusLabel(for status: AgentConversationMessage.ToolStatus?) -> String {
        switch status {
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        case .inProgress: String(localized: "Running")
        case .pending, nil: String(localized: "Pending")
        }
    }
}
