import Foundation

/// The agent's current execution plan. ACP sends the complete plan on every
/// `plan` update, so a new value replaces the previous one.
public struct AgentPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public enum Status: String, Equatable, Sendable {
            case pending
            case inProgress = "in_progress"
            case completed
        }

        public var content: String
        /// Upstream priority label (`high`, `medium`, `low`); kept as reported.
        public var priority: String?
        public var status: Status

        public init(content: String, priority: String? = nil, status: Status) {
            self.content = content
            self.priority = priority
            self.status = status
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public var completedCount: Int { entries.filter { $0.status == .completed }.count }
    public var isComplete: Bool { !entries.isEmpty && completedCount == entries.count }
    /// The entry the agent is working on, or the next pending one.
    public var currentEntry: Entry? {
        entries.first { $0.status == .inProgress } ?? entries.first { $0.status == .pending }
    }

    static let entryLimit = 100

    /// An empty entry list is a valid update that clears the plan.
    static func parse(_ update: [String: Any]) -> Self? {
        guard let entries = update["entries"] as? [[String: Any]] else { return nil }
        return Self(entries: entries.prefix(entryLimit).compactMap { entry in
            guard let content = entry["content"] as? String,
                  let status = (entry["status"] as? String).flatMap(Entry.Status.init(rawValue:)) else { return nil }
            return Entry(content: content, priority: entry["priority"] as? String, status: status)
        })
    }
}

/// A slash command the agent advertised for this session. Selecting one only
/// inserts `/name ` into the prompt; the agent interprets the sent text.
public struct AgentCommand: Identifiable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// Placeholder for the free-form input that follows the command name.
    public var hint: String?

    public var id: String { name }
    /// Codex lists skills as `$name` commands; they are mentioned as `$name`, not `/$name`.
    public var isSkill: Bool { name.hasPrefix("$") }
    /// Text the composer inserts to invoke the command.
    public var invocation: String { isSkill ? name : "/" + name }

    public init(name: String, description: String, hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }

    static let commandLimit = 200

    static func parse(_ update: [String: Any]) -> [Self]? {
        guard let commands = update["availableCommands"] as? [[String: Any]] else { return nil }
        return commands.prefix(commandLimit).compactMap { command in
            guard let name = command["name"] as? String, !name.isEmpty else { return nil }
            let input = command["input"] as? [String: Any]
            return Self(name: name, description: command["description"] as? String ?? "",
                        hint: (input?["hint"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Commands matching the token being typed, or nil when the draft is not a
    /// command prefix. `/` lists every command; `$` lists only skills, and only
    /// when the agent advertises some, so a literal `$` is not intercepted.
    public static func suggestions(for draft: String, in commands: [Self]) -> [Self]? {
        guard let trigger = draft.first, trigger == "/" || trigger == "$" else { return nil }
        let candidates = trigger == "$" ? commands.filter(\.isSkill) : commands
        guard !candidates.isEmpty else { return nil }
        let query = draft.dropFirst().lowercased()
        guard !query.contains(where: \.isWhitespace) else { return nil }
        func key(_ command: Self) -> String {
            (command.isSkill ? String(command.name.dropFirst()) : command.name).lowercased()
        }
        let prefixed = candidates.filter { key($0).hasPrefix(query) }
        let contained = candidates.filter { !key($0).hasPrefix(query) && key($0).contains(query) }
        return prefixed + contained
    }
}
