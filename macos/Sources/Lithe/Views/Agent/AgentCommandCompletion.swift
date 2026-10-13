import LitheAgentConversationModule

/// View-local command interaction shared by Return, Esc, arrow keys and Tab.
/// Completing a command edits the draft; only a send result starts a prompt.
struct AgentCommandCompletion {
    enum Key { case submit, escape, up, down, tab }
    enum Result { case ignored, handled, send, cancel }

    var draft = "" {
        didSet {
            if draft != oldValue {
                highlightedIndex = 0
                dismissedDraft = nil
            }
        }
    }
    private(set) var highlightedIndex = 0
    private var dismissedDraft: String?

    func suggestions(in commands: [AgentCommand]) -> [AgentCommand]? {
        dismissedDraft == draft ? nil : AgentCommand.suggestions(for: draft, in: commands)
    }

    mutating func complete(_ command: AgentCommand) {
        draft = command.invocation + " "
        dismissedDraft = nil
    }

    mutating func handle(_ key: Key, commands: [AgentCommand], isResponding: Bool) -> Result {
        let suggestions = suggestions(in: commands)
        switch key {
        case .escape:
            if suggestions != nil {
                dismissedDraft = draft
                return .handled
            }
            return isResponding ? .cancel : .ignored
        case .submit:
            guard let suggestions, !suggestions.isEmpty,
                  !suggestions.contains(where: { $0.invocation == draft }) else { return .send }
            complete(suggestions[min(highlightedIndex, suggestions.count - 1)])
            return .handled
        case .up, .down, .tab:
            guard let suggestions, !suggestions.isEmpty else { return .ignored }
            if key == .tab {
                complete(suggestions[min(highlightedIndex, suggestions.count - 1)])
            } else {
                let offset = key == .up ? -1 : 1
                highlightedIndex = (min(highlightedIndex, suggestions.count - 1) + offset + suggestions.count) % suggestions.count
            }
            return .handled
        }
    }
}
