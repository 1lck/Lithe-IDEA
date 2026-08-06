import Foundation

struct MarkdownRenderedContent: Sendable, Equatable {
    let html: String
}

/// Platform-neutral application boundary for the shared Markdown dialect.
/// Rust owns parsing and sanitization; platform views only display the result.
protocol MarkdownRendering: Sendable {
    func render(_ source: String) async throws -> MarkdownRenderedContent
}
