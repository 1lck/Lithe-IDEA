import SwiftUI
import LitheAgentConversationModule

/// Reserves a writing line before allocating space to command suggestions.
struct AgentComposerDraftArea<Editor: View>: View {
    let commands: [AgentCommand]?
    let highlightedIndex: Int
    let onSelect: (AgentCommand) -> Void
    @ViewBuilder let editor: () -> Editor

    private let minimumEditorHeight: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            let listHeight = max(0, geometry.size.height - minimumEditorHeight)
            let showsInline = listHeight >= AgentCommandSuggestionList.minimumHeight
            VStack(spacing: 0) {
                if let commands, showsInline {
                    suggestions(commands, maximumHeight: min(AgentCommandSuggestionList.defaultMaximumHeight, listHeight - 2))
                }
                editor()
                    .frame(minHeight: minimumEditorHeight, maxHeight: .infinity, alignment: .topLeading)
            }
            .anchorPreference(key: AgentFloatingCommandsKey.self, value: .bounds) { bounds in
                guard let commands, !showsInline else { return nil }
                return AgentFloatingCommands(bounds: bounds,
                    list: suggestions(commands, maximumHeight: AgentCommandSuggestionList.defaultMaximumHeight))
            }
        }
        .zIndex(1)
    }

    private func suggestions(_ commands: [AgentCommand], maximumHeight: CGFloat) -> AgentCommandSuggestionList {
        AgentCommandSuggestionList(
            commands: commands,
            highlightedIndex: min(highlightedIndex, max(0, commands.count - 1)),
            onSelect: onSelect,
            maximumHeight: maximumHeight
        )
    }
}

private struct AgentFloatingCommands {
    let bounds: Anchor<CGRect>
    let list: AgentCommandSuggestionList
}

private struct AgentFloatingCommandsKey: PreferenceKey {
    static var defaultValue: AgentFloatingCommands?

    static func reduce(value: inout AgentFloatingCommands?, nextValue: () -> AgentFloatingCommands?) {
        value = nextValue() ?? value
    }
}

/// Render outside the split pane's hit bounds so floated rows remain clickable.
private struct AgentCommandSuggestionScope: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(AgentFloatingCommandsKey.self) { suggestion in
                GeometryReader { geometry in
                    if let suggestion {
                        let frame = geometry[suggestion.bounds]
                        let list = AgentCommandSuggestionList(
                            commands: suggestion.list.commands,
                            highlightedIndex: suggestion.list.highlightedIndex,
                            onSelect: suggestion.list.onSelect,
                            maximumHeight: min(AgentCommandSuggestionList.defaultMaximumHeight, max(0, frame.minY - 2))
                        )
                        list.frame(width: frame.width)
                            .position(x: frame.midX, y: frame.minY - list.height / 2)
                    }
                }
            }
            .transformPreference(AgentFloatingCommandsKey.self) { $0 = nil }
    }
}

extension View {
    func agentCommandSuggestionScope() -> some View {
        modifier(AgentCommandSuggestionScope())
    }
}
