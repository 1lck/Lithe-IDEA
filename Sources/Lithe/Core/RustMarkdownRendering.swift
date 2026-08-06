import Foundation

struct RustMarkdownRendering: MarkdownRendering {
    let core: RustCoreBridge

    func render(_ source: String) async throws -> MarkdownRenderedContent {
        let core = core
        return try await Task.detached(priority: .userInitiated) {
            let payload = try core.markdownRender(source).get()
            return MarkdownRenderedContent(html: payload.html)
        }.value
    }
}
