import LitheAgentConversationModule

/// View-local command interaction shared by Return, Esc, arrow keys and Tab.
/// Completing a command edits the draft; only a send result starts a prompt.
/// Completing a file mention removes the `@query` and reports the file to attach.
struct AgentCommandCompletion {
    enum Key { case submit, escape, up, down, tab }
    enum Result: Equatable { case ignored, handled, send, cancel, attach(AgentCommand) }

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
    /// Files found for `fileMentionQuery`; filled asynchronously. They are offered
    /// only while the draft still ends in that exact query, so a result for an
    /// earlier query can never be selected while the next search is pending.
    private(set) var fileMentions: [AgentCommand] = []
    private(set) var fileMentionQuery: String?

    mutating func setFileMentions(_ mentions: [AgentCommand], for query: String?) {
        fileMentions = mentions
        fileMentionQuery = query
    }

    func suggestions(in commands: [AgentCommand]) -> [AgentCommand]? {
        guard dismissedDraft != draft else { return nil }
        if let commands = AgentCommand.suggestions(for: draft, in: commands) { return commands }
        guard let query = AgentCommand.mentionQuery(in: draft), query == fileMentionQuery,
              !fileMentions.isEmpty else { return nil }
        return fileMentions
    }

    mutating func complete(_ command: AgentCommand) {
        if command.isFileMention, let query = AgentCommand.mentionQuery(in: draft) {
            draft.removeLast(query.count + 1)
            setFileMentions([], for: nil)
        } else {
            draft = command.invocation + " "
        }
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
            // A fully typed command sends; a fully typed file name still attaches.
            guard let suggestions, !suggestions.isEmpty,
                  !suggestions.contains(where: { !$0.isFileMention && $0.invocation == draft }) else { return .send }
            return completeHighlighted(in: suggestions)
        case .up, .down, .tab:
            guard let suggestions, !suggestions.isEmpty else { return .ignored }
            if key == .tab {
                return completeHighlighted(in: suggestions)
            } else {
                let offset = key == .up ? -1 : 1
                highlightedIndex = (min(highlightedIndex, suggestions.count - 1) + offset + suggestions.count) % suggestions.count
            }
            return .handled
        }
    }

    private mutating func completeHighlighted(in suggestions: [AgentCommand]) -> Result {
        let command = suggestions[min(highlightedIndex, suggestions.count - 1)]
        complete(command)
        return command.isFileMention ? .attach(command) : .handled
    }
}
