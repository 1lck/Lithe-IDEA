import Foundation

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// What the system browser may be asked to open.
enum PluginHostExternalTarget: Equatable, Sendable {
    /// An http or https address, as the plugin wrote it.
    case webURL(String)
    /// An `.html` or `.htm` file of the window's workspace.
    case workspaceFile(PluginHostResource)
}

/// What to do when a local file has edits the browser cannot see.
enum PluginHostUnsavedPolicy: Equatable, Sendable {
    /// Open the saved file and say so in the result.
    case openSavedFile
    /// Refuse with `unsavedChanges`, so the caller can save first.
    case requireSaved
}

struct PluginHostExternalOpenRequest: Equatable, Sendable {
    let context: PluginHostCallContext
    let target: PluginHostExternalTarget
    var unsaved: PluginHostUnsavedPolicy = .openSavedFile

    init(context: PluginHostCallContext, target: PluginHostExternalTarget, unsaved: PluginHostUnsavedPolicy = .openSavedFile) {
        self.context = context
        self.target = target
        self.unsaved = unsaved
    }
}

struct PluginHostExternalOpenResult: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        /// A web page the browser fetches itself.
        case webPage
        /// The file as saved on disk. `hasUnsavedChanges` tells that the
        /// editor holds a newer buffer the browser does not show.
        case savedFile(hasUnsavedChanges: Bool)
    }

    let openedURL: URL
    let content: Content
}

/// Opens things in the system's web browser. The platform adapter owns the
/// actual launch; the service has already checked what may be launched.
@MainActor
protocol PluginHostExternalOpening: AnyObject {
    func openWebURL(_ url: URL) async throws
    func openLocalHTMLFile(_ url: URL) async throws
}

/// `browser.openExternal`.
///
/// Remote addresses are limited to http and https with a host name and no
/// embedded credentials. Local files must be HTML files under the window's
/// workspace and are opened as saved on disk. Nothing is appended to an
/// address or file, and no script is run.
@MainActor
final class PluginHostBrowserService {
    static let maxURLBytes = 4096
    static let allowedSchemes: Set<String> = ["http", "https"]

    private let gate: PluginHostScopeGate
    private let resolver: PluginHostResourceResolver
    private let opener: any PluginHostExternalOpening

    init(
        directory: any PluginHostWindowDirectory, resolver: PluginHostResourceResolver,
        opener: any PluginHostExternalOpening
    ) {
        gate = PluginHostScopeGate(directory: directory)
        self.resolver = resolver
        self.opener = opener
    }

    func openExternal(_ request: PluginHostExternalOpenRequest) async throws -> PluginHostExternalOpenResult {
        let scope = try gate.enter(request.context)
        switch request.target {
        case .webURL(let raw):
            let url = try Self.validatedWebURL(raw)
            try await launch { try await opener.openWebURL(url) }
            return PluginHostExternalOpenResult(openedURL: url, content: .webPage)
        case .workspaceFile(let resource):
            guard PluginHostPreviewService.isHTML(resource.relativePath) else { throw PluginHostError.notHTMLDocument }
            let url = try resolver.resolveFile(resource, roots: scope.snapshot.roots)
            // The editor first reports input it has not handed over, so a
            // file the user is typing in is not mistaken for a saved one.
            let state = await scope.port.hostDocumentState(at: url, flushingEditor: true)
            let hasUnsavedChanges = state?.hasUnsavedChanges ?? false
            if hasUnsavedChanges && request.unsaved == .requireSaved { throw PluginHostError.unsavedChanges }
            _ = try gate.enter(request.context)
            try await launch { try await opener.openLocalHTMLFile(url) }
            return PluginHostExternalOpenResult(openedURL: url, content: .savedFile(hasUnsavedChanges: hasUnsavedChanges))
        }
    }

    private func launch(_ action: () async throws -> Void) async throws {
        do { try await action() } catch is CancellationError { throw CancellationError() } catch {
            throw PluginHostError.browserUnavailable
        }
    }

    /// The address as a URL, or `unsupportedURL`.
    static func validatedWebURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= maxURLBytes,
              !raw.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f || $0.properties.isWhitespace }),
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), allowedSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw PluginHostError.unsupportedURL
        }
        components.scheme = scheme
        guard let url = components.url else { throw PluginHostError.unsupportedURL }
        return url
    }
}
