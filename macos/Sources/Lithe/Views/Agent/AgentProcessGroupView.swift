import SwiftUI
import LitheAgentConversationModule

/// One disclosure for the whole turn's process. Hidden content has no rows or
/// reserved height; expanded content uses the transcript's own scrolling surface.
struct AgentProcessGroupView: View {
    @Environment(\.locale) private var locale
    let messages: [AgentConversationMessage]
    let isStreaming: Bool
    let searchText: String
    @Binding var expansion: AgentThoughtExpansion
    let onOpenFile: (AgentToolDetails.Location) -> Void

    private var isExpanded: Bool {
        expansion.isExpanded(isStreaming: isStreaming, isSearching: !searchText.isEmpty)
    }

    private var headerButton: some View {
        Button { expansion.toggle(isStreaming: isStreaming, isSearching: !searchText.isEmpty) } label: {
            HStack(spacing: 5) {
                if isStreaming { ProgressView().controlSize(.mini) }
                Text("Thinking process").lineLimit(1)
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
        .accessibilityIdentifier("agent-process-group-header")
    }

    private var images: [AgentImage] {
        messages.flatMap(\.toolDetails.images).uniquedByID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                headerButton
                Spacer(minLength: 8)
                // The process is collapsed by default; pictures the tools returned stay visible beside it; expanded, each tool group shows its own.
                if !isExpanded && !images.isEmpty { AgentImageStrip(images: images) }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentTranscriptItem.processContents(messages).filter { $0.matches(searchText) }) { item in
                        switch item {
                        case .message(let message):
                            AgentMarkdownMessage(text: message.text.trimmingCharacters(in: .whitespacesAndNewlines), size: 12)
                                .equatable()
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .toolGroup(let tools):
                            AgentToolGroupView(messages: tools, searchText: searchText, onOpenFile: onOpenFile,
                                               initiallyExpanded: true)
                        case .processGroup, .turnSummary:
                            EmptyView()
                        }
                    }
                }
                .padding(.leading, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
