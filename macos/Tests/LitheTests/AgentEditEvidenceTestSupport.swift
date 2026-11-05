import Foundation

/// Builds a tool update the way Agent Host presents it: the raw ACP diff plus
/// the Host's normalized `_meta.lithe.diffs` evidence. Swift never derives
/// evidence from raw content, so tests must supply the Host annotation.
enum AgentEditEvidenceTestSupport {
    static func diffContent(path: String, old: String?, new: String, operation: String? = nil,
                            stats: (added: Int, removed: Int)? = nil) -> [String: Any] {
        ["content": [["type": "diff", "path": path, "oldText": old as Any, "newText": new]],
         "_meta": ["lithe": ["diffs": [evidence(path: path, old: old, new: new, operation: operation, stats: stats)]]]]
    }

    static func evidence(path: String, old: String?, new: String, operation: String? = nil,
                         stats: (added: Int, removed: Int)? = nil, truncated: Bool = false) -> [String: Any] {
        ["path": path, "oldText": old ?? NSNull(), "newText": new, "operation": operation ?? NSNull(),
         "additions": stats?.added ?? NSNull(), "deletions": stats?.removed ?? NSNull(), "truncated": truncated,
         "revertible": !truncated && (old != nil || operation == "add")]
    }

    static func repositoryRoot(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Expands the shared fixture's `{repeat, count, suffix?}` text generators.
    static func expand(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            if let unit = object["repeat"] as? String, let count = object["count"] as? Int {
                return String(repeating: unit, count: count) + (object["suffix"] as? String ?? "")
            }
            return object.mapValues(expand)
        }
        if let array = value as? [Any] { return array.map(expand) }
        return value
    }
}
