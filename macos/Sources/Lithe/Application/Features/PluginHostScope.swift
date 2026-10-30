import Foundation
import LitheCoreContracts
import LitheModuleAPI

// Note: 编辑器打开、HTML 预览、外部浏览器和窗口消息的宿主内部服务见 .agents/notes/implemented/architecture/2026-10-30-plugin-host-open-preview-services.md

/// Who asks. The host never guesses this from the focused window: every
/// service call names its plugin, window and workspace explicitly.
struct PluginHostCaller: Equatable, Sendable {
    let pluginID: String
    let pluginName: String
}

/// The window and workspace opening one call is bound to. A call whose
/// window closed, or whose workspace was replaced since the plugin received
/// these values, fails instead of acting on whatever is open now.
struct PluginHostCallContext: Equatable, Sendable {
    let caller: PluginHostCaller
    /// The project session (window) the plugin was activated for.
    let windowID: UUID
    let workspaceURL: URL
    let workspaceGeneration: Int

    init(caller: PluginHostCaller, windowID: UUID, workspaceURL: URL, workspaceGeneration: Int) {
        self.caller = caller
        self.windowID = windowID
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.workspaceGeneration = workspaceGeneration
    }
}

/// A folder a plugin may name resources under.
struct PluginHostRoot: Equatable, Sendable {
    let id: String
    let url: URL
}

/// A resource as plugins name it: a root ID plus a "/"-separated path
/// relative to that root. Never an absolute path or a `file:` URL.
struct PluginHostResource: Equatable, Sendable {
    /// The workspace folder of a window; the only root of a local window.
    static let workspaceRootID = "workspace"

    let rootID: String
    let relativePath: String
}

/// 1-based line and column; the column counts UTF-16 code units like the
/// editor's own positions.
struct PluginHostPosition: Equatable, Sendable {
    let line: Int
    let column: Int
}

struct PluginHostTextRange: Equatable, Sendable {
    let start: PluginHostPosition
    let end: PluginHostPosition
}

/// What the host knows about one window at the moment of a call.
struct PluginHostWindowSnapshot: Equatable, Sendable {
    let windowID: UUID
    let workspaceURL: URL
    let workspaceGeneration: Int
    /// A workspace whose files live on another machine. v1 refuses these.
    let isRemoteWorkspace: Bool
    /// True while this is the window the user is working in. A call never
    /// changes it: no service raises a window or activates the application.
    let isForeground: Bool
    let roots: [PluginHostRoot]
}

/// One document as the window's document owner holds it.
struct PluginHostDocumentState: Equatable, Sendable {
    var documentID: UUID? = nil
    var version: UInt64? = nil
    let url: URL
    /// False when the owner holds no buffer for the file.
    let isOpen: Bool
    /// The buffer differs from the file on disk, or its latest input could
    /// not be confirmed.
    let hasUnsavedChanges: Bool
    /// The file is the foreground tab of the window's editor: the selected tab
    /// of the focused editor group, with no diff, terminal or Agent tab in
    /// front of it. A tab that is open but not in front is a background tab,
    /// and later editor calls (selection, edits) require the foreground, so a
    /// plugin brings the file forward with `editor.open` first. This says
    /// nothing about which window the user is in; see `isForeground`.
    let isActive: Bool
    let isReadOnly: Bool
}

enum PluginHostEditorActivation: Equatable, Sendable {
    /// Bring the file to the front of the window's editor: it becomes the
    /// foreground tab (the way a click on its tab does, also across editor
    /// groups) and `PluginHostDocumentState.isActive` is true afterwards. The
    /// window itself is never raised.
    case select
    /// Keep the file open without changing the active tab or caret.
    case background
}

/// What a window offers a service: state reads and the few edits a service
/// may make. The AppModel of a project session implements it.
@MainActor
protocol PluginHostWindowPort: AnyObject {
    var hostDocumentService: (any EditorDocumentServicing)? { get }
    var hostVisibilityRules: FileVisibilityRules { get }
    func hostSetHTMLPresentation(at url: URL, previewOnly: Bool) throws
    /// nil once the session closed or when no folder is open.
    var hostSnapshot: PluginHostWindowSnapshot? { get }
    /// Reads the document state. With `flushingEditor` the editor first
    /// reports input it has not handed over yet, so the answer is not stale.
    func hostDocumentState(at url: URL, flushingEditor: Bool) async -> PluginHostDocumentState?
    /// Opens `url` from disk only when the owner has no buffer for it. An open
    /// buffer, dirty or not, is kept as it is. nil when the file cannot be opened.
    func hostOpenDocument(at url: URL, activation: PluginHostEditorActivation) async -> PluginHostDocumentState?
    /// Moves the caret of `url`'s editor. The target is applied by the editor
    /// when the file is visible; it never changes which window is key.
    func hostPlaceCaret(in url: URL, at position: PluginHostPosition)
    /// The window's plugin message surface.
    var hostMessages: PluginHostMessageFeatureModel { get }
    /// Tells the user that `pluginName` sent more messages than the host shows.
    func hostNoteMessageLimit(pluginName: String)
}

extension PluginHostWindowPort {
    var hostDocumentService: (any EditorDocumentServicing)? { nil }
    var hostVisibilityRules: FileVisibilityRules { .default }
    func hostSetHTMLPresentation(at url: URL, previewOnly: Bool) throws { throw PluginHostError.unsupportedOption }
}

/// Finds a window by the ID a plugin was given for it.
@MainActor
protocol PluginHostWindowDirectory: AnyObject {
    func hostWindow(id: UUID) -> (any PluginHostWindowPort)?
}

/// Resolves windows only through live contexts; never consults global focus.
@MainActor
final class PluginContextWindowDirectory: PluginHostWindowDirectory {
    let contexts: PluginWorkspaceContexts
    init(contexts: PluginWorkspaceContexts) { self.contexts = contexts }
    func hostWindow(id: UUID) -> (any PluginHostWindowPort)? {
        for context in contexts.contexts {
            if let port = contexts.owner(of: context) as? any PluginHostWindowPort,
               port.hostSnapshot?.windowID == id { return port }
        }
        return nil
    }
}

/// A call accepted by the gate: the window and the snapshot it was
/// checked against.
@MainActor
struct PluginHostScope {
    let port: any PluginHostWindowPort
    let snapshot: PluginHostWindowSnapshot
}

/// A host-side refusal with a stable code. The Core function bridge maps
/// `code` onto the contract's error codes; the message is for the log and
/// the plugin author, in the interface language.
enum PluginHostError: Error, Equatable, LocalizedError {
    case invalidResourcePath
    case unknownRoot
    case outsideWorkspace
    case resourceNotFound
    case notRegularFile
    case windowUnavailable
    case workspaceChanged
    case remoteWorkspaceUnsupported
    case invalidPosition
    case unsupportedOption
    case documentNotOpen
    case openFailed
    case notHTMLDocument
    case unsupportedURL
    case unsavedChanges
    case browserUnavailable
    case invalidMessage
    case rateLimited
    case messageQueueFull

    var code: String {
        switch self {
        case .invalidResourcePath: "host.resource.invalidPath"
        case .unknownRoot: "host.resource.unknownRoot"
        case .outsideWorkspace: "host.resource.outsideWorkspace"
        case .resourceNotFound: "host.resource.notFound"
        case .notRegularFile: "host.resource.notRegularFile"
        case .windowUnavailable: "host.window.unavailable"
        case .workspaceChanged: "host.window.workspaceChanged"
        case .remoteWorkspaceUnsupported: "host.window.remoteUnsupported"
        case .invalidPosition: "host.editor.invalidPosition"
        case .unsupportedOption: "host.option.unsupported"
        case .documentNotOpen: "host.editor.documentNotOpen"
        case .openFailed: "host.editor.openFailed"
        case .notHTMLDocument: "host.preview.notHTML"
        case .unsupportedURL: "host.browser.unsupportedURL"
        case .unsavedChanges: "host.browser.unsavedChanges"
        case .browserUnavailable: "host.browser.unavailable"
        case .invalidMessage: "host.message.invalid"
        case .rateLimited: "host.message.rateLimited"
        case .messageQueueFull: "host.message.queueFull"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResourcePath:
            L10n.string("The resource path must be relative, use \"/\" separators, and not contain \".\" or \"..\".")
        case .unknownRoot:
            L10n.string("The resource names a root this window does not offer.")
        case .outsideWorkspace:
            L10n.string("The resource is outside the workspace.")
        case .resourceNotFound:
            L10n.string("The resource does not exist.")
        case .notRegularFile:
            L10n.string("The resource is not a regular file.")
        case .windowUnavailable:
            L10n.string("The window is closed or has no workspace open.")
        case .workspaceChanged:
            L10n.string("The window now shows a different workspace than the one this call was made for.")
        case .remoteWorkspaceUnsupported:
            L10n.string("Remote workspaces are not supported by this operation yet.")
        case .invalidPosition:
            L10n.string("Lines and columns start at 1, and a range must not end before it starts.")
        case .unsupportedOption:
            L10n.string("The host does not support the requested option yet.")
        case .documentNotOpen:
            L10n.string("The file is not open in this window.")
        case .openFailed:
            L10n.string("The file could not be opened as a text document.")
        case .notHTMLDocument:
            L10n.string("Only .html and .htm files can be shown in a browser.")
        case .unsupportedURL:
            L10n.string("Only http and https addresses with a host name can be opened.")
        case .unsavedChanges:
            L10n.string("The file has unsaved changes. Save it first, because the browser shows the saved file.")
        case .browserUnavailable:
            L10n.string("No web browser could be opened.")
        case .invalidMessage:
            L10n.string("The message text or its buttons are empty, too long, or too many.")
        case .rateLimited:
            L10n.string("This plugin sent messages too quickly.")
        case .messageQueueFull:
            L10n.string("This plugin already has too many messages waiting.")
        }
    }
}

/// Checks that a call still belongs to a live window and the workspace it
/// was made for. Services run it before they act and again after every
/// suspension, so a window that closed in between cannot be acted on.
@MainActor
struct PluginHostScopeGate {
    private weak var directory: (any PluginHostWindowDirectory)?

    init(directory: any PluginHostWindowDirectory) {
        self.directory = directory
    }

    func enter(_ context: PluginHostCallContext) throws -> PluginHostScope {
        guard let port = directory?.hostWindow(id: context.windowID),
              let snapshot = port.hostSnapshot,
              snapshot.windowID == context.windowID else {
            throw PluginHostError.windowUnavailable
        }
        // Remote authority is refused before anything else is compared, so a
        // plugin never learns whether a path exists on the other machine.
        guard !snapshot.isRemoteWorkspace else { throw PluginHostError.remoteWorkspaceUnsupported }
        guard snapshot.workspaceURL == context.workspaceURL,
              snapshot.workspaceGeneration == context.workspaceGeneration else {
            throw PluginHostError.workspaceChanged
        }
        return PluginHostScope(port: port, snapshot: snapshot)
    }
}

/// Turns a root ID and relative path into a file URL inside the root.
///
/// The check is made on the canonical path (symbolic links resolved), so a
/// link inside the workspace that leads out of it is refused. The URL handed
/// back keeps the workspace's own spelling, which is what the document owner
/// keys its buffers by. The window between this check and the later open is
/// not closed here; the Agent Note lists it as a known limit.
struct PluginHostResourceResolver {
    static let maxPathBytes = 4096

    var canonicalize: (URL) -> URL
    var metadata: (URL) -> FileMetadata?

    init(
        canonicalize: @escaping (URL) -> URL = { $0.resolvingSymlinksInPath().standardizedFileURL },
        metadata: @escaping (URL) -> FileMetadata?
    ) {
        self.canonicalize = canonicalize
        self.metadata = metadata
    }

    init(fileStorage: any FileStorage) {
        self.init(metadata: { fileStorage.metadata(for: $0) })
    }

    /// The URL of a regular file under one of `roots`.
    func resolveFile(_ resource: PluginHostResource, roots: [PluginHostRoot]) throws -> URL {
        let components = try Self.components(of: resource.relativePath)
        guard let root = roots.first(where: { $0.id == resource.rootID }) else {
            throw PluginHostError.unknownRoot
        }
        var candidate = root.url.standardizedFileURL
        for component in components { candidate.appendPathComponent(component) }
        let canonicalRoot = canonicalize(root.url).path
        let canonicalCandidate = canonicalize(candidate)
        let rootPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard canonicalCandidate.path.hasPrefix(rootPrefix) else { throw PluginHostError.outsideWorkspace }
        guard let attributes = metadata(canonicalCandidate) else { throw PluginHostError.resourceNotFound }
        guard attributes.isRegularFile else { throw PluginHostError.notRegularFile }
        return candidate
    }

    /// Path pieces of a relative resource path, or `invalidResourcePath`.
    static func components(of relativePath: String) throws -> [String] {
        guard !relativePath.isEmpty, relativePath.utf8.count <= maxPathBytes,
              !relativePath.hasPrefix("/"), !relativePath.hasSuffix("/") else {
            throw PluginHostError.invalidResourcePath
        }
        // Control characters, including NUL, and backslashes never belong in a
        // resource path; accepting them would let two spellings name one file.
        guard !relativePath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f || $0 == "\\" }) else {
            throw PluginHostError.invalidResourcePath
        }
        let pieces = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !pieces.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PluginHostError.invalidResourcePath
        }
        return pieces
    }
}

/// A 1-based position or range checked against the limits editors accept.
enum PluginHostPositionValidation {
    static let maxLine = 10_000_000
    static let maxColumn = 1_000_000

    static func validate(_ position: PluginHostPosition) throws {
        guard (1...maxLine).contains(position.line), (1...maxColumn).contains(position.column) else {
            throw PluginHostError.invalidPosition
        }
    }

    static func validate(_ range: PluginHostTextRange) throws {
        try validate(range.start)
        try validate(range.end)
        let endsBeforeStart = range.end.line < range.start.line
            || (range.end.line == range.start.line && range.end.column < range.start.column)
        guard !endsBeforeStart else { throw PluginHostError.invalidPosition }
    }
}
