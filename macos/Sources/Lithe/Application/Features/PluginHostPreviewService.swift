import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

enum PluginHostPreviewPresentation: Equatable, Sendable {
    /// The editor and the preview side by side, the HTML default.
    case editorAndPreview
    /// The preview alone. The editor area keeps this choice per tab as view
    /// state, so a service cannot set it yet; asking for it is refused.
    case previewOnly
}

struct PluginHostPreviewOpenRequest: Equatable, Sendable {
    let context: PluginHostCallContext
    let resource: PluginHostResource
    var presentation: PluginHostPreviewPresentation = .editorAndPreview
    /// A caret to place in the editor next to the preview.
    var range: PluginHostTextRange?

    init(
        context: PluginHostCallContext, resource: PluginHostResource,
        presentation: PluginHostPreviewPresentation = .editorAndPreview, range: PluginHostTextRange? = nil
    ) {
        self.context = context
        self.resource = resource
        self.presentation = presentation
        self.range = range
    }
}

struct PluginHostPreviewOpenResult: Equatable, Sendable {
    let editor: PluginHostEditorOpenResult
    /// The embedded preview renders the editor's live buffer, so it shows
    /// unsaved edits. This is always true for the embedded preview and is
    /// reported so a caller can contrast it with the system browser.
    let usesLiveBuffer: Bool
    let presentation: PluginHostPreviewPresentation
}

/// `preview.openHTML`: shows an HTML file in the embedded preview of the
/// window's editor.
///
/// The preview is a pane of the file's own editor tab, fed with the buffer
/// the user is editing. Its web view has no plugin bridge (see the Agent
/// Note), so project HTML cannot call back into the host.
@MainActor
final class PluginHostPreviewService {
    static let htmlExtensions: Set<String> = ["html", "htm"]

    private let editor: PluginHostEditorService

    init(editor: PluginHostEditorService) {
        self.editor = editor
    }

    func openHTML(_ request: PluginHostPreviewOpenRequest) async throws -> PluginHostPreviewOpenResult {
        guard request.presentation == .editorAndPreview else { throw PluginHostError.unsupportedOption }
        guard Self.isHTML(request.resource.relativePath) else { throw PluginHostError.notHTMLDocument }
        let result = try await editor.open(PluginHostEditorOpenRequest(
            context: request.context, resource: request.resource, range: request.range,
            activation: .select, tab: .regular
        ))
        return PluginHostPreviewOpenResult(
            editor: result, usesLiveBuffer: true, presentation: .editorAndPreview
        )
    }

    static func isHTML(_ relativePath: String) -> Bool {
        htmlExtensions.contains((relativePath as NSString).pathExtension.lowercased())
    }
}
