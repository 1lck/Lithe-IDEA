import Combine
import Foundation
@testable import Lithe

/// Files of a pretend workspace: which paths exist and where links lead.
/// Nothing touches the disk, so the resolver tests are deterministic.
final class PluginHostFileTable {
    var files: [String: FileMetadata] = [:]
    var links: [String: String] = [:]

    func addFile(_ path: String) {
        files[path] = FileMetadata(byteCount: 1, modificationDate: nil, isRegularFile: true, isDirectory: false)
    }

    func addDirectory(_ path: String) {
        files[path] = FileMetadata(byteCount: nil, modificationDate: nil, isRegularFile: false, isDirectory: true)
    }

    func resolver() -> PluginHostResourceResolver {
        PluginHostResourceResolver(
            canonicalize: { [self] url in
                let path = url.standardizedFileURL.path
                return URL(fileURLWithPath: links[path] ?? path)
            },
            metadata: { [self] url in files[url.path] }
        )
    }
}

/// A window as the services see it, modelling the document owner's rules:
/// an open buffer is never reloaded, only one tab is in front, and a file
/// that is not open is loaded from disk exactly once.
@MainActor
final class FakePluginHostWindow: PluginHostWindowPort {
    struct OpenCall: Equatable {
        let path: String
        let activation: PluginHostEditorActivation
    }

    struct CaretPlacement: Equatable {
        let path: String
        let position: PluginHostPosition
    }

    var snapshot: PluginHostWindowSnapshot?
    /// Open buffers by file path; true when the buffer holds unsaved edits.
    var openBuffers: [String: Bool] = [:]
    /// The file whose tab is in front, or nil when another kind of tab is.
    var foregroundPath: String?
    /// Files whose latest editor input is only reported when a flush is asked for.
    var pendingEditorInput: Set<String> = []
    var unopenablePaths: Set<String> = []
    /// Runs while a file is loading, to model the window changing under the call.
    var whileLoading: (@MainActor () -> Void)?
    /// Runs while the editor is asked to report its input.
    var whileFlushing: (@MainActor () -> Void)?
    private(set) var diskLoads: [String] = []
    private(set) var openCalls: [OpenCall] = []
    private(set) var flushedPaths: [String] = []
    private(set) var caretPlacements: [CaretPlacement] = []
    private(set) var limitNotices: [String] = []
    let messages = PluginHostMessageFeatureModel()

    init(snapshot: PluginHostWindowSnapshot?) {
        self.snapshot = snapshot
    }

    var hostSnapshot: PluginHostWindowSnapshot? { snapshot }
    var hostMessages: PluginHostMessageFeatureModel { messages }

    func hostDocumentState(at url: URL, flushingEditor: Bool) async -> PluginHostDocumentState? {
        guard snapshot != nil else { return nil }
        let path = url.standardizedFileURL.path
        guard var isDirty = openBuffers[path] else { return state(path) }
        if flushingEditor {
            flushedPaths.append(path)
            whileFlushing?()
            if pendingEditorInput.contains(path) { isDirty = true }
        }
        return PluginHostDocumentState(
            url: URL(fileURLWithPath: path), isOpen: true, hasUnsavedChanges: isDirty,
            isActive: foregroundPath == path, isReadOnly: false
        )
    }

    func hostOpenDocument(at url: URL, activation: PluginHostEditorActivation) async -> PluginHostDocumentState? {
        let path = url.standardizedFileURL.path
        openCalls.append(OpenCall(path: path, activation: activation))
        guard !unopenablePaths.contains(path) else { return nil }
        if openBuffers[path] == nil {
            openBuffers[path] = false
            diskLoads.append(path)
        }
        if activation == .select { foregroundPath = path }
        whileLoading?()
        return state(path)
    }

    func hostPlaceCaret(in url: URL, at position: PluginHostPosition) {
        caretPlacements.append(CaretPlacement(path: url.standardizedFileURL.path, position: position))
    }

    func hostNoteMessageLimit(pluginName: String) {
        limitNotices.append(pluginName)
    }

    private func state(_ path: String) -> PluginHostDocumentState {
        let isOpen = openBuffers[path] != nil
        return PluginHostDocumentState(
            url: URL(fileURLWithPath: path), isOpen: isOpen, hasUnsavedChanges: openBuffers[path] ?? false,
            isActive: isOpen && foregroundPath == path, isReadOnly: false
        )
    }
}

@MainActor
final class FakePluginHostDirectory: PluginHostWindowDirectory {
    var windows: [UUID: FakePluginHostWindow] = [:]

    func hostWindow(id: UUID) -> (any PluginHostWindowPort)? { windows[id] }
}

@MainActor
final class RecordingExternalOpener: PluginHostExternalOpening {
    private(set) var webURLs: [URL] = []
    private(set) var htmlFiles: [URL] = []
    var failure: (any Error)?

    func openWebURL(_ url: URL) async throws {
        if let failure { throw failure }
        webURLs.append(url)
    }

    func openLocalHTMLFile(_ url: URL) async throws {
        if let failure { throw failure }
        htmlFiles.append(url)
    }
}

/// The time the rate limiter sees; tests move it instead of waiting.
@MainActor
final class PluginHostTestClock {
    var now: TimeInterval = 1_000
}

/// One local window with a workspace, and every service wired to it.
///
/// Call `tearDown()` in a `defer`: it ends the window's messages, and it keeps
/// the fixture alive until the test finishes, because the services only hold
/// the directory weakly.
@MainActor
final class PluginHostFixture {
    static let workspaceURL = URL(fileURLWithPath: "/fixture/workspace", isDirectory: true)
    static let defaultGeneration = 7

    let windowID: UUID
    let directory = FakePluginHostDirectory()
    let table = PluginHostFileTable()
    let window: FakePluginHostWindow
    let opener = RecordingExternalOpener()
    let clock = PluginHostTestClock()
    let caller = PluginHostCaller(pluginID: "com.example.html-tools", pluginName: "HTML Tools")
    let editor: PluginHostEditorService
    let preview: PluginHostPreviewService
    let browser: PluginHostBrowserService

    init() {
        let id = UUID()
        windowID = id
        window = FakePluginHostWindow(snapshot: Self.snapshot(windowID: id))
        directory.windows[id] = window
        editor = PluginHostEditorService(directory: directory, resolver: table.resolver())
        preview = PluginHostPreviewService(editor: editor)
        browser = PluginHostBrowserService(directory: directory, resolver: table.resolver(), opener: opener)
    }

    func tearDown() {
        // The hooks may capture the fixture or the directory; drop them so nothing is kept alive.
        window.whileLoading = nil
        window.whileFlushing = nil
        for fakeWindow in directory.windows.values { fakeWindow.messages.dismissAll(.cancelled) }
        directory.windows.removeAll()
    }

    static func snapshot(
        windowID: UUID, isForeground: Bool = true, isRemote: Bool = false,
        generation: Int = PluginHostFixture.defaultGeneration
    ) -> PluginHostWindowSnapshot {
        PluginHostWindowSnapshot(
            windowID: windowID, workspaceURL: workspaceURL, workspaceGeneration: generation,
            isRemoteWorkspace: isRemote, isForeground: isForeground,
            roots: [PluginHostRoot(id: PluginHostResource.workspaceRootID, url: workspaceURL)]
        )
    }

    /// Replaces the window's snapshot, as a user switching windows or workspaces would.
    func updateSnapshot(isForeground: Bool = true, isRemote: Bool = false, generation: Int = PluginHostFixture.defaultGeneration) {
        window.snapshot = Self.snapshot(
            windowID: windowID, isForeground: isForeground, isRemote: isRemote, generation: generation
        )
    }

    /// A second window, in the directory, for tests that must not leak into another window.
    func addWindow(isForeground: Bool) -> (id: UUID, window: FakePluginHostWindow) {
        let id = UUID()
        let other = FakePluginHostWindow(snapshot: Self.snapshot(windowID: id, isForeground: isForeground))
        directory.windows[id] = other
        return (id, other)
    }

    func path(_ relative: String) -> String { "/fixture/workspace/" + relative }
    func url(_ relative: String) -> URL { URL(fileURLWithPath: path(relative)) }

    /// A regular file of the workspace.
    func addFile(_ relative: String) { table.addFile(path(relative)) }

    func resource(_ relative: String, root: String = PluginHostResource.workspaceRootID) -> PluginHostResource {
        PluginHostResource(rootID: root, relativePath: relative)
    }

    func context(
        windowID: UUID? = nil, generation: Int = PluginHostFixture.defaultGeneration, caller: PluginHostCaller? = nil
    ) -> PluginHostCallContext {
        PluginHostCallContext(
            caller: caller ?? self.caller, windowID: windowID ?? self.windowID,
            workspaceURL: Self.workspaceURL, workspaceGeneration: generation
        )
    }

    func openRequest(
        _ relative: String, range: PluginHostTextRange? = nil,
        activation: PluginHostEditorActivation = .select, tab: PluginHostEditorTab = .regular
    ) -> PluginHostEditorOpenRequest {
        PluginHostEditorOpenRequest(
            context: context(), resource: resource(relative), range: range, activation: activation, tab: tab
        )
    }

    func messageService(limits: PluginHostMessageLimits = PluginHostMessageLimits()) -> PluginHostMessageService {
        let clock = clock
        return PluginHostMessageService(directory: directory, limits: limits, now: { clock.now })
    }
}

/// Waits until `isSatisfied` holds, re-checking after each change of the
/// message surface, and gives up at the deadline instead of hanging.
@MainActor
func waitForPluginHostMessages(
    _ messages: PluginHostMessageFeatureModel,
    timeout: DispatchTimeInterval = .seconds(5),
    until isSatisfied: @escaping @MainActor () -> Bool
) async -> Bool {
    await waitForChanges([messages.objectWillChange.eraseToAnyPublisher()], timeout: timeout, until: isSatisfied)
}
