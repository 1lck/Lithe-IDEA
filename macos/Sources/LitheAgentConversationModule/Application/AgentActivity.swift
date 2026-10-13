import Foundation

/// A file's reported changes, in tool execution order. Review decisions apply
/// to this exact version, so a later edit of the same path becomes visible again.
public struct AgentFileChange: Identifiable, Equatable, Sendable {
    public let path: String
    public var toolIDs: [String] = []
    public var diffs: [AgentToolDetails.Diff] = []
    public var isPending = false
    public var hasMissingDiff = false
    public var isDeletion = false
    public var id: String { path }
    public var canRevert: Bool {
        !isPending && !hasMissingDiff && !diffs.isEmpty
            && diffs.allSatisfy { !$0.isTruncated && ($0.oldText != nil || $0.operation == "add") }
    }
    /// Stats retain the upstream accounting scope; absent reports stay unknown.
    public var additions: Int? { total(\.additions) }
    public var deletions: Int? { total(\.deletions) }

    private func total(_ field: KeyPath<AgentToolDetails.Diff, Int?>) -> Int? {
        guard !diffs.isEmpty else { return nil }
        var total = 0
        for diff in diffs {
            guard let value = diff[keyPath: field] else { return nil }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

/// Presentation derived from the current ACP transcript, independent of search.
public struct AgentActivity {
    public let tools: [AgentConversationMessage]
    public let running: [AgentConversationMessage]
    public let files: [AgentFileChange]

    public init(messages: [AgentConversationMessage], reviewed: [String: AgentFileChange] = [:]) {
        let allTools = messages.filter { $0.role == .tool }
        tools = allTools
        running = allTools.filter { $0.toolStatus == .pending || $0.toolStatus == .inProgress }
        var files: [AgentFileChange] = []
        var indices: [String: Int] = [:]
        for tool in allTools where tool.toolStatus != .failed && tool.toolStatus != .interrupted {
            let details = tool.toolDetails
            guard !details.diffs.isEmpty || ["edit", "delete", "move"].contains(details.kind) else { continue }
            // Locations can repeat for several hunks. Preserve the agent's order
            // while counting each file once, including location-only evidence.
            var paths: [String] = []
            for path in details.diffs.map(\.path) + details.locations.map(\.path) where !path.isEmpty {
                if !paths.contains(path) { paths.append(path) }
            }
            for path in paths {
                let index: Int
                if let existing = indices[path] { index = existing }
                else {
                    index = files.count
                    indices[path] = index
                    files.append(AgentFileChange(path: path))
                }
                let diffs = details.diffs.filter { $0.path == path }
                files[index].toolIDs.append(tool.id)
                files[index].diffs.append(contentsOf: diffs)
                files[index].isPending = files[index].isPending || tool.toolStatus != .completed
                files[index].hasMissingDiff = files[index].hasMissingDiff || diffs.isEmpty || details.kind == "move"
                files[index].isDeletion = details.kind == "delete" || diffs.last?.operation == "delete"
            }
        }
        self.files = files.compactMap { file in
            guard let saved = reviewed[file.path] else { return file }
            if saved == file { return nil }
            let fileTools = allTools.filter { file.toolIDs.contains($0.id) }
            // An acknowledged prefix becomes the new review baseline. Preserve
            // all evidence when a prior tool was updated instead of appended.
            let prefix = AgentActivity(messages: Array(fileTools.prefix(saved.toolIDs.count))).files.first { $0.path == file.path }
            guard prefix == saved else { return file }
            return AgentActivity(messages: Array(fileTools.dropFirst(saved.toolIDs.count))).files.first { $0.path == file.path }
        }
    }
}
