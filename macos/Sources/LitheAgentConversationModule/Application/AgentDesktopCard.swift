import Foundation

/// A Claude Desktop mechanism the agent host recognised in a tool call and
/// described in `_meta.lithe.claudeDesktop`, so the panel can show it as
/// Desktop does rather than as a raw tool row. Clients that ignore the card
/// still see the readable title the host gave the row.
public enum AgentDesktopCard: Equatable, Sendable {
    public struct Action: Equatable, Sendable {
        public var label: String
        public var message: String
    }

    public enum TaskState: String, Sendable {
        case proposed, withdrawn, started, handedOff
    }

    public enum PullRequestAction: String, Sendable {
        case bound, unbound, monitored, autoMerge
    }

    public enum DirectoryAction: String, Sendable {
        case changed, requested
    }

    /// A chapter marker the agent set to divide a long conversation.
    case chapter(title: String, summary: String?)
    /// Replies Desktop offers as buttons after the agent wraps up a turn.
    case nextStep(actions: [Action])
    /// Work the agent proposed for a separate session, or handed off to one.
    case task(title: String, summary: String?, prompt: String?, state: TaskState)
    case pullRequest(action: PullRequestAction, url: URL, number: Int?, autoFix: Bool?, enabled: Bool?)
    case directory(action: DirectoryAction, path: String)
    /// HTML or SVG the agent drew with Desktop's visualizer.
    case widget(title: String, code: String)

    static let widgetLimit = 262_144

    init?(_ value: Any?) {
        guard let card = value as? [String: Any], let type = card["card"] as? String else { return nil }
        func text(_ key: String) -> String? {
            (card[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch type {
        case "chapter":
            guard let title = text("title") else { return nil }
            self = .chapter(title: title, summary: text("summary"))
        case "nextStep":
            let actions = (card["actions"] as? [[String: Any]] ?? []).prefix(4).compactMap { action -> Action? in
                guard let label = (action["label"] as? String).flatMap({ $0.isEmpty ? nil : $0 }),
                      let message = (action["message"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
                return Action(label: label, message: message)
            }
            guard !actions.isEmpty else { return nil }
            self = .nextStep(actions: actions)
        case "task":
            guard let title = text("title") else { return nil }
            self = .task(title: title, summary: text("summary"), prompt: text("prompt"),
                         state: text("state").flatMap(TaskState.init(rawValue:)) ?? .proposed)
        case "pullRequest":
            // Only web links: the URL becomes a clickable button.
            guard let action = text("action").flatMap(PullRequestAction.init(rawValue:)),
                  let url = text("url").flatMap(URL.init(string:)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self = .pullRequest(action: action, url: url, number: card["number"] as? Int,
                                autoFix: card["autoFix"] as? Bool, enabled: card["enabled"] as? Bool)
        case "directory":
            guard let action = text("action").flatMap(DirectoryAction.init(rawValue:)), let path = text("path") else { return nil }
            self = .directory(action: action, path: path)
        case "widget":
            guard let code = card["code"] as? String, !code.isEmpty, code.count <= Self.widgetLimit else { return nil }
            self = .widget(title: text("title") ?? "", code: code)
        default:
            return nil
        }
    }

    /// Words the transcript search should find this card by.
    public var searchableText: String {
        switch self {
        case .chapter(let title, let summary): [title, summary].compactMap { $0 }.joined(separator: "\n")
        case .nextStep(let actions): actions.map(\.label).joined(separator: "\n")
        case .task(let title, let summary, let prompt, _): [title, summary, prompt].compactMap { $0 }.joined(separator: "\n")
        case .pullRequest(_, let url, _, _, _): url.absoluteString
        case .directory(_, let path): path
        case .widget(let title, _): title
        }
    }
}

public extension AgentConversationMessage {
    /// The Desktop card this tool call shows on the transcript. A call that
    /// failed or was denied never happened in Desktop either, so it stays a tool row.
    var shownDesktopCard: AgentDesktopCard? {
        role == .tool && toolStatus == .completed ? toolDetails.desktopCard : nil
    }
}
