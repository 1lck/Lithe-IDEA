import Foundation

/// Rust Core checks what a plugin content provider answers (plan API-12), so
/// every host opens the same text under the same limit.
public protocol PluginContentDecoding: Sendable {
    /// The document text of the answer. Throws when Core refuses the answer:
    /// a shape other than a string or `{content}`, or more than 1 MiB.
    func decodeContent(_ answer: ToolingJSONValue) throws -> String
}
