import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

enum PluginHostEditorTab: Equatable, Sendable {
    /// A normal tab of the window's editor.
    case regular
    /// A replaceable preview tab. The editor has none yet, so asking for it
    /// is refused rather than quietly opened as a regular tab.
    case preview
}

struct PluginHostEditorOpenRequest: Equatable, Sendable {
    let context: PluginHostCallContext
    let resource: PluginHostResource
    /// Where to put the caret. The editor can place a caret but not select a
    /// range yet, so only `range.start` takes effect; the result says so.
    var range: PluginHostTextRange?
    var activation: PluginHostEditorActivation = .select
    var tab: PluginHostEditorTab = .regular

    init(
        context: PluginHostCallContext, resource: PluginHostResource, range: PluginHostTextRange? = nil,
        activation: PluginHostEditorActivation = .select, tab: PluginHostEditorTab = .regular
    ) {
        self.context = context
        self.resource = resource
        self.range = range
        self.activation = activation
        self.tab = tab
    }
}

/// What the editor did with a requested range.
enum PluginHostAppliedSelection: Equatable, Sendable {
    case none
    case caret(PluginHostPosition)
}

struct PluginHostEditorOpenResult: Equatable, Sendable {
    let document: PluginHostDocumentState
    /// The file already had a buffer, whose text the call left as it was.
    let wasAlreadyOpen: Bool
    let appliedSelection: PluginHostAppliedSelection
    /// False when the user is in another window. The call still did its
    /// work in the named window and did not raise it.
    let windowIsForeground: Bool
}

/// `editor.open` and `editor.reveal` for one workspace file.
///
/// It reuses the window's document owner: a file that is already open keeps
/// its buffer, dirty or not, and the service reads no file contents itself.
/// It never raises a window or activates the application, so a call for a
/// background window cannot take the user's focus.
///
/// `.select` is also how a plugin brings a background tab to the front: the
/// editor slice reads selections and applies edits only for the foreground
/// tab, so a plugin calls `editor.open` first and finds `document.isActive`
/// true in the result. `.background` leaves the tabs as they are.
@MainActor
final class PluginHostEditorService {
    private let gate: PluginHostScopeGate
    private let resolver: PluginHostResourceResolver

    init(directory: any PluginHostWindowDirectory, resolver: PluginHostResourceResolver) {
        gate = PluginHostScopeGate(directory: directory)
        self.resolver = resolver
    }

    /// Opens the file in the window, loading it from disk only when the window has no buffer for it.
    func open(_ request: PluginHostEditorOpenRequest) async throws -> PluginHostEditorOpenResult {
        try await perform(request, requiresOpenDocument: false)
    }

    /// Brings an open file to the caret position. Fails with `documentNotOpen` instead of loading it.
    func reveal(_ request: PluginHostEditorOpenRequest) async throws -> PluginHostEditorOpenResult {
        try await perform(request, requiresOpenDocument: true)
    }

    private func perform(
        _ request: PluginHostEditorOpenRequest, requiresOpenDocument: Bool
    ) async throws -> PluginHostEditorOpenResult {
        let scope = try gate.enter(request.context)
        guard request.tab == .regular else { throw PluginHostError.unsupportedOption }
        if let range = request.range { try PluginHostPositionValidation.validate(range) }
        let url = try resolver.resolveFile(request.resource, roots: scope.snapshot.roots)

        let before = await scope.port.hostDocumentState(at: url, flushingEditor: false)
        let wasAlreadyOpen = before?.isOpen == true
        if requiresOpenDocument && !wasAlreadyOpen { throw PluginHostError.documentNotOpen }
        _ = try gate.enter(request.context)

        guard let document = await scope.port.hostOpenDocument(at: url, activation: request.activation) else {
            throw PluginHostError.openFailed
        }
        // The window may have closed or switched workspace while the file loaded.
        let current = try gate.enter(request.context)

        var applied = PluginHostAppliedSelection.none
        if request.activation == .select, let start = request.range?.start {
            current.port.hostPlaceCaret(in: url, at: start)
            applied = .caret(start)
        }
        return PluginHostEditorOpenResult(
            document: document,
            wasAlreadyOpen: wasAlreadyOpen,
            appliedSelection: applied,
            windowIsForeground: current.snapshot.isForeground
        )
    }
}
