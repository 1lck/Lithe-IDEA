import Foundation

/// Agent-owned choices, never a hardcoded product model or permission catalog.
public struct AgentSessionConfigOption: Identifiable, Equatable, Sendable {
    public struct Choice: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var group: String?
    }

    public var id: String
    public var name: String
    public var category: String?
    public var currentValue: String
    public var choices: [Choice]

    public var currentLabel: String { choices.first { $0.id == currentValue }?.name ?? currentValue }

    static func parse(_ value: Any?) -> [Self] {
        (value as? [[String: Any]] ?? []).compactMap { option in
            guard option["type"] as? String == "select",
                  let id = option["id"] as? String,
                  let name = option["name"] as? String,
                  let current = option["currentValue"] as? String else { return nil }
            let choices = (option["options"] as? [[String: Any]] ?? []).flatMap { entry -> [Choice] in
                let group = entry["name"] as? String
                let items = entry["options"] as? [[String: Any]] ?? [entry]
                return items.compactMap {
                    guard let value = $0["value"] as? String, let name = $0["name"] as? String else { return nil }
                    return Choice(id: value, name: name, group: entry["options"] == nil ? nil : group)
                }
            }
            return Self(id: id, name: name, category: option["category"] as? String,
                        currentValue: current, choices: choices)
        }
    }
}

/// Bounded presentation of ACP tool evidence. Partial updates replace only present fields.
public struct AgentToolDetails: Equatable, Sendable {
    public struct Location: Equatable, Sendable {
        public var path: String
        public var line: Int?

        public func fileURL(in workspace: URL) -> URL? {
            let root = workspace.standardizedFileURL
            let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            guard url.pathComponents.starts(with: root.pathComponents),
                  url.pathComponents.count > root.pathComponents.count else { return nil }
            return url
        }
    }
    public struct Content: Equatable, Sendable {
        public var title: String
        public var text: String
    }

    public var kind: String?
    public var input: String?
    public var output: String?
    public var locations: [Location] = []
    public var content: [Content] = []
    public var isEmpty: Bool { input == nil && output == nil && locations.isEmpty && content.isEmpty }
    static let textLimit = 32_768

    mutating func merge(_ update: [String: Any]) {
        if let kind = update["kind"] as? String { self.kind = kind }
        if let input = update["rawInput"] { self.input = Self.display(input) }
        if let output = update["rawOutput"] { self.output = Self.display(output) }
        if let locations = update["locations"] as? [[String: Any]] {
            self.locations = locations.prefix(100).compactMap {
                guard let path = $0["path"] as? String else { return nil }
                return Location(path: path, line: ($0["line"] as? Int).flatMap { $0 > 0 ? $0 : nil })
            }
        }
        if let content = update["content"] as? [[String: Any]] {
            self.content = content.prefix(100).compactMap { item in
                switch item["type"] as? String {
                case "content":
                    guard let block = item["content"] as? [String: Any] else { return nil }
                    if let text = block["text"] as? String {
                        return Content(title: "Output", text: Self.bounded(text))
                    }
                    return Content(title: "Content", text: block["type"] as? String ?? "Unsupported content")
                case "diff":
                    let old = item["oldText"] as? String ?? ""
                    let new = item["newText"] as? String ?? ""
                    return Content(title: item["path"] as? String ?? "Diff",
                                   text: Self.bounded("---\n" + old + "\n+++\n" + new))
                case "terminal":
                    return Content(title: "Terminal", text: item["terminalId"] as? String ?? "")
                default: return nil
                }
            }
        }
    }

    private static func display(_ value: Any) -> String? {
        if value is NSNull { return nil }
        if let text = value as? String { return bounded(text) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return bounded(String(describing: value))
        }
        return bounded(String(decoding: data, as: UTF8.self))
    }

    private static func bounded(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "\n[...]" : text
    }
}
