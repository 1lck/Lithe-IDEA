import AppKit
import Combine
import SwiftUI
import WebKit
import LitheCoreContracts
import LitheDebugModule
import LitheGitModule

/// Local editor assets included by ordinary preview and release packaging.
enum MonacoWorkbenchResources {
    static let directory: URL? = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("MonacoEditor"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else { return nil }
        return root
    }()
}

struct MonacoPreviewConfiguration: Equatable {
    let line: Int
    let query: String
    let matchCase: Bool
    let wholeWord: Bool
    let regex: Bool
}

struct MonacoWorkbenchEditor: View {
    @EnvironmentObject private var model: AppModel
    let document: EditorDocument
    var secondaryDocument: EditorDocument? = nil
    var preview: MonacoPreviewConfiguration? = nil
    var markdownScrollPosition: Binding<MarkdownScrollPosition>? = nil

    var body: some View {
        MonacoWorkbenchContent(document: document, secondaryDocument: secondaryDocument, preview: preview, markdownScrollPosition: markdownScrollPosition, model: model)
    }
}

private struct MonacoWorkbenchContent: View {
    @ObservedObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var diagnostics: EditorDiagnosticsStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session: MonacoWorkbenchSession
    let document: EditorDocument
    let secondaryDocument: EditorDocument?
    let preview: MonacoPreviewConfiguration?
    let markdownScrollPosition: Binding<MarkdownScrollPosition>?

    init(document: EditorDocument, secondaryDocument: EditorDocument?, preview: MonacoPreviewConfiguration?, markdownScrollPosition: Binding<MarkdownScrollPosition>?, model: AppModel) {
        self.document = document
        self.secondaryDocument = secondaryDocument
        self.preview = preview
        self.markdownScrollPosition = markdownScrollPosition
        self.model = model
        _session = StateObject(wrappedValue: MonacoWorkbenchSession.forModel(model.id))
    }

    var body: some View {
        Group {
            if MonacoWorkbenchResources.directory != nil {
                MonacoWorkbenchSurface(session: session, document: document, secondaryDocument: secondaryDocument, preview: preview, markdownScrollPosition: markdownScrollPosition, model: model,
                    fontSize: settings.editorFontSize, dark: colorScheme == .dark, wrap: settings.editorSoftWrapEnabled,
                    markers: diagnostics.diagnostics(for: document.url),
                    secondaryMarkers: secondaryDocument.map { diagnostics.diagnostics(for: $0.url) } ?? [])
            } else {
                Text("Editor resources are missing. Rebuild or reinstall Lithe.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

    }
}

private struct MonacoWorkbenchSurface: NSViewRepresentable {
    let session: MonacoWorkbenchSession
    let document: EditorDocument
    let secondaryDocument: EditorDocument?
    let preview: MonacoPreviewConfiguration?
    let markdownScrollPosition: Binding<MarkdownScrollPosition>?
    let model: AppModel
    let fontSize: Double
    let dark: Bool
    let wrap: Bool
    let markers: [EditorDiagnostic]
    let secondaryMarkers: [EditorDiagnostic]

    final class Coordinator {
        let ownerID = UUID()
        let session: MonacoWorkbenchSession
        init(session: MonacoWorkbenchSession) { self.session = session }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> NSView { session.makeContainer(ownerID: context.coordinator.ownerID, isPreview: preview != nil) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.session.detachView(ownerID: coordinator.ownerID)
    }
    func updateNSView(_ view: NSView, context: Context) {
        session.update(ownerID: context.coordinator.ownerID, document: document, secondaryDocument: secondaryDocument, preview: preview, markdownScrollPosition: markdownScrollPosition, model: model, fontSize: fontSize, dark: dark, wrap: wrap, markers: markers, secondaryMarkers: secondaryMarkers)
    }
}

final class MonacoWorkbenchAssets: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url, url.scheme == "lithe-editor", url.host == "app" else { throw CocoaError(.fileReadNoPermission) }
            let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file)
            let types = ["html": "text/html", "js": "application/javascript", "css": "text/css", "ttf": "font/ttf"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": types[file.pathExtension] ?? "application/octet-stream"])!)
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Weak handler breaks WKUserContentController's otherwise strong ownership cycle.
private final class MonacoWorkbenchMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: MonacoWorkbenchSession?
    init(_ session: MonacoWorkbenchSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let session else { replyHandler(nil, "Editor closed"); return }
        session.receive(message, reply: replyHandler)
    }
}

@MainActor
private final class MonacoWorkbenchSession: NSObject, ObservableObject, WKNavigationDelegate {
    private struct SessionReference { weak var value: MonacoWorkbenchSession? }
    private static var sessions: [UUID: SessionReference] = [:]
    static func forModel(_ id: UUID) -> MonacoWorkbenchSession {
        sessions = sessions.filter { $0.value.value != nil }
        if let existing = sessions[id]?.value { return existing }
        let session = MonacoWorkbenchSession()
        sessions[id] = SessionReference(value: session)
        return session
    }
    private struct Mount {
        weak var container: NSView?
        let isPreview: Bool
        var update: (() -> Void)?
    }
    private var mounts: [UUID: Mount] = [:]
    private var mountOrder: [UUID] = []
    private var lastPreview: MonacoPreviewConfiguration?
    private var previewDocumentID: String?
    private var currentMountIsPreview = false
    private var needsMainRestore = false
    private var viewOwnerID: UUID?
    private var loadingInterval: LitheSignpost.State?
    private struct DocumentReference { weak var value: EditorDocument? }
    private var webView: WKWebView?
    private weak var model: AppModel?
    private var documentReferences: [String: DocumentReference] = [:]
    private var documents: [String: EditorDocument] { documentReferences.compactMapValues(\.value) }
    private var revisions: [String: Int] = [:]
    private var unconfirmedModels: Set<String> = []
    private var completionLists: [String: (context: MonacoDocumentContext, revision: Int?, key: String, items: [LanguageServerCompletionItem])] = [:]
    private var codeActionLists: [String: (context: MonacoDocumentContext, workspace: MonacoWorkspaceContext, revision: Int?, key: String, items: [LanguageServerCodeAction])] = [:]
    private var javaNavigationLists: [String: (context: MonacoDocumentContext, revision: Int, url: URL, markers: [JavaImplementationMarker])] = [:]
    private var javaNavigationRequests: [String: UUID] = [:]
    private var codeActionCommands: [String: (context: MonacoDocumentContext, key: String, root: URL?, command: LanguageServerCommand)] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var readOnlySubscriptions: [String: AnyCancellable] = [:]
    private var findSubscriptions: [AnyCancellable] = []
    private var lastFindPayload: Data?
    private var findToken = ""
    private var applyingEdit = false
    private var ready = false
    private var activeIDs: [String: String] = [:]
    private var documentLocations: [String: UInt64] = [:]
    private var documentReadOnlyStates: [String: Bool] = [:]
    private var hasSecondaryView = false
    private var latestUpdate: (() -> Void)?
    private var pending: [UUID: (Result<Any?, Error>) -> Void] = [:]
    private var failed = false
    private var navigationID: UUID?
    private var lastSemanticState = ""
    private var lastConfiguration = ""
    private var lastLiveIDs: Set<String> = []
    private var debugSubscription: AnyCancellable?
    private var codeVisionSubscription: AnyCancellable?
    private var lastCodeVisionEnabled: Bool?
    private var debugFeatureIdentity: ObjectIdentifier?
    private var lastDebugStates: [String: Data] = [:]
    private var gitSubscription: AnyCancellable?
    private var gitFeatureIdentity: ObjectIdentifier?
    private var gitLoads: [String: Task<Void, Never>] = [:]
    private var blameLoads: [String: Task<Void, Never>] = [:]
    private var blameVisibilitySubscription: AnyCancellable?
    private var lastGitStates: [String: Data] = [:]
    private var lastMarkers: [String: [EditorDiagnostic]] = [:]
    private var synchronizingIDs: Set<String> = []
    private var markdownScrollBinding: Binding<MarkdownScrollPosition>?
    private var markdownScrollID: String?
    private var markdownScrollRevision: UInt64?


    private func makeView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let root = MonacoWorkbenchResources.directory {
            configuration.setURLSchemeHandler(MonacoWorkbenchAssets(root: root), forURLScheme: "lithe-editor")
        }
        configuration.userContentController.addScriptMessageHandler(MonacoWorkbenchMessages(self), contentWorld: .page, name: "litheEditor")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
        loadingInterval = LitheSignpost.begin("monaco.webview.load")
        view.load(URLRequest(url: URL(string: "lithe-editor://app/index.html")!))
        return view
    }

    func makeContainer(ownerID: UUID, isPreview: Bool) -> NSView {
        let container = NSView()
        mounts[ownerID] = Mount(container: container, isPreview: isPreview)
        mountOrder.append(ownerID)
        selectMount()
        return container
    }

    private func selectMount() {
        mountOrder.removeAll { mounts[$0]?.container == nil }
        let selected = mountOrder.last { mounts[$0]?.isPreview == true } ?? mountOrder.last
        guard let selected, let container = mounts[selected]?.container else {
            viewOwnerID = nil; latestUpdate = nil
            markdownScrollBinding = nil; markdownScrollID = nil; markdownScrollRevision = nil
            webView?.removeFromSuperview()
            return
        }
        if viewOwnerID != selected {
            let isPreview = mounts[selected]?.isPreview == true
            if isPreview && !currentMountIsPreview && ready { call("window.lithe.suspendMain()") }
            if !isPreview && currentMountIsPreview { needsMainRestore = true }
            currentMountIsPreview = isPreview
            viewOwnerID = selected
            let view = makeView()
            view.removeFromSuperview()
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            lastPreview = nil; previewDocumentID = nil
            // Force activation so the returning main surface restores its view state.
            activeIDs.removeAll()
        }
        latestUpdate = mounts[selected]?.update
        if ready { latestUpdate?() }
    }

    func detachView(ownerID: UUID) {
        mounts[ownerID] = nil
        mountOrder.removeAll { $0 == ownerID }
        selectMount()
    }

    func update(ownerID: UUID, document: EditorDocument, secondaryDocument: EditorDocument?, preview: MonacoPreviewConfiguration?, markdownScrollPosition: Binding<MarkdownScrollPosition>?, model: AppModel, fontSize: Double, dark: Bool, wrap: Bool, markers: [EditorDiagnostic], secondaryMarkers: [EditorDiagnostic]) {
        guard mounts[ownerID] != nil else { return }
        self.model = model
        observeFind(model: model)
        mounts[ownerID]?.update = { [weak self, weak document, weak secondaryDocument, weak model] in
            guard let self, let document, let model else { return }
            self.present(document: document, model: model, fontSize: fontSize, dark: dark, wrap: wrap, markers: markers)
            self.presentMarkdownScroll(document: document, binding: markdownScrollPosition)
            if let secondaryDocument {
                self.hasSecondaryView = true
                self.present(document: secondaryDocument, model: model, fontSize: fontSize, dark: dark, wrap: wrap, markers: secondaryMarkers, surface: "secondary")
            } else if self.hasSecondaryView {
                self.hasSecondaryView = false
                self.activeIDs.removeValue(forKey: "secondary")
                self.call("window.lithe.hideSecondary()")
            }
            if preview == nil, self.needsMainRestore {
                self.needsMainRestore = false
                self.call("window.lithe.restoreMain()")
            }
            self.synchronizeFind()
            if let preview, self.lastPreview != preview || self.previewDocumentID != document.id.uuidString {
                self.lastPreview = preview
                self.previewDocumentID = document.id.uuidString
                self.call("window.lithe.find(payload)", arguments: ["payload": ["id": document.id.uuidString,
                    "query": preview.query, "matchCase": preview.matchCase, "wholeWord": preview.wholeWord, "regex": preview.regex]])
                self.call("window.lithe.navigate(payload)", arguments: ["payload": ["id": document.id.uuidString,
                    "line": max(0, preview.line - 1), "column": 0]])
            }
        }
        if viewOwnerID == ownerID {
            latestUpdate = mounts[ownerID]?.update
            if ready { latestUpdate?() }
        }
    }

    private func observeFind(model: AppModel) {
        guard findSubscriptions.isEmpty else { return }
        // Chrome deliberately does not republish AppModel on every query keystroke.
        Publishers.CombineLatest3(model.editorChrome.$isFindBarVisible,
            model.editorChrome.$findBarQuery, model.editorChrome.$findOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronizeFind() }
            .store(in: &findSubscriptions)
        for (name, command) in [(Notification.Name.litheFindNavigate, "navigate"),
                                (.litheFindReplaceNext, "replace"), (.litheFindReplaceAll, "replaceAll")] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self, weak model] notification in
                    guard let self, let model, notification.object as? AppModel === model else { return }
                    let action = command == "navigate"
                        ? ((notification.userInfo?[FindNotificationKeys.direction] as? Int ?? 1) < 0 ? "previous" : "next") : command
                    self.synchronizeFind(command: action)
                }.store(in: &findSubscriptions)
        }
        NotificationCenter.default.publisher(for: .litheFindDismiss)
            .sink { [weak self, weak model] notification in
                guard let self, let model, notification.object as? AppModel === model,
                      self.ready, !self.currentMountIsPreview, self.webView?.window?.isKeyWindow == true,
                      let document = model.focusedEditorDocument ?? model.activeDocument,
                      self.activeIDs.values.contains(document.id.uuidString) else { return }
                self.call("window.lithe.dismissNativeFind(id)", arguments: ["id": document.id.uuidString])
            }.store(in: &findSubscriptions)
    }

    private func synchronizeFind(command: String? = nil) {
        guard ready, let model else { return }
        let document = model.focusedEditorDocument ?? model.activeDocument
        let id = document?.id.uuidString ?? ""
        let visible = model.isFindBarVisible && !currentMountIsPreview && activeIDs.values.contains(id)
        let options = model.findOptions
        var payload: [String: Any] = ["id": id, "visible": visible, "query": model.findBarQuery,
            "matchCase": options.matchCase, "wholeWord": options.wholeWords, "regex": options.regularExpression]
        guard let signature = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        guard signature != lastFindPayload || command != nil else { return }
        if signature != lastFindPayload {
            lastFindPayload = signature
            findToken = UUID().uuidString
            model.updateFindState(currentIndex: 0, count: 0)
        }
        payload["token"] = findToken
        if let command { payload["command"] = command; payload["replacement"] = model.findReplaceText }
        call("window.lithe.nativeFind(payload)", arguments: ["payload": payload])
    }

    private func register(_ document: EditorDocument) {
        let id = document.id.uuidString
        guard documents[id] == nil else { return }
        documentReferences[id] = DocumentReference(value: document)
        revisions[id] = 0
        unconfirmedModels.insert(id)
        // The document retains its editor while it remains open, even if SwiftUI
        // temporarily removes this surface. The reverse document reference is weak.
        document.synchronizeEditor = { [self] completion in
            self.synchronize(id: id, completion: completion)
        }
        document.holdEditorForClose = { [self, weak document] completion in
            guard let document else { completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return }
            let token = UUID().uuidString
            var arguments: [String: Any] = ["id": id, "token": token]
            if unconfirmedModels.contains(id) {
                arguments["payload"] = ["id": id, "text": document.text, "revision": revisions[id] ?? 0,
                                        "filename": document.url.lastPathComponent, "locationRevision": document.locationRevision,
                                        "readonly": document.isReadOnly]
            } else { arguments["payload"] = NSNull() }
            call("window.lithe.holdForClose(id, token, payload)", arguments: arguments) { [weak self, weak document] result in
                guard let self else { completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return }
                var released = false
                let release: EditorDocument.EditorRelease = { [self] in
                    guard !released else { return }
                    released = true
                    self.call("window.lithe.releaseClose(token)", arguments: ["token": token])
                }
                guard case .success(let value) = result, let document,
                      let snapshot = value as? [String: Any], !self.failed,
                      snapshot["text"] as? String == document.text,
                      snapshot["revision"] as? Int == self.revisions[id] else {
                    release()
                    completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return
                }
                completion(.success(release))
            }
        }
        subscriptions[id] = document.textDidChange.sink { [weak self, weak document] in
            guard let self, let document, self.currentDocument(id) === document, !self.applyingEdit else { return }
            let previous = self.revisions[id] ?? 0
            self.revisions[id] = previous + 1
            self.call("window.lithe.replace(payload)", arguments: ["payload": ["id": id, "text": document.text, "previousRevision": previous, "revision": previous + 1]])
        }
        readOnlySubscriptions[id] = document.$isReadOnly.dropFirst().sink { [weak self, weak document] _ in
            guard let self, let document, self.currentDocument(id) === document else { return }
            self.documentReadOnlyStates[id] = document.isReadOnly
            self.call("window.lithe.updateDocument(payload)", arguments: ["payload": [
                "id": id, "filename": document.url.lastPathComponent,
                "locationRevision": document.locationRevision, "readonly": document.isReadOnly
            ]])
        }
    }

    private func workspaceEditPayload(_ edit: LanguageServerWorkspaceEdit, model: AppModel) async throws -> [[String: Any]] {
        guard let root = model.workspaceURL?.standardizedFileURL else {
            throw EditorDocument.DocumentError.editorNotSynchronized
        }
        let workspace = MonacoWorkspaceContext(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL)
        let urls = edit.changes.keys.sorted { $0.absoluteString < $1.absoluteString }
        // Validate the entire target set before opening any file.
        for url in urls {
            let path = url.standardizedFileURL.path
            guard url.isFileURL, path.hasPrefix(root.path + "/") else {
                throw LanguageWorkspaceEditService.EditError.outsideWorkspace
            }
        }
        var targets: [(EditorDocument, MonacoDocumentContext, [LanguageServerTextEdit])] = []
        for url in urls {
            await model.documentFeature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: false)
            guard workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL),
                  let document = model.openDocuments.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }),
                  !document.isReadOnly else { throw EditorDocument.DocumentError.editorNotSynchronized }
            register(document)
            let context = MonacoDocumentContext(document: document, revision: revisions[document.id.uuidString] ?? 0,
                workspaceURL: model.workspaceURL)
            targets.append((document, context, edit.changes[url] ?? []))
        }
        return try targets.map { document, context, edits in
            guard isCurrent(context), workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL),
                  model.openDocuments.contains(where: { $0 === document }) else {
                throw EditorDocument.DocumentError.editorNotSynchronized
            }
            _ = try LanguageServerTextEditApplicator.apply(edits, to: document.text)
            return ["id": document.id.uuidString, "text": document.text,
                    "revision": revisions[document.id.uuidString] ?? 0,
                    "filename": document.url.lastPathComponent, "locationRevision": document.locationRevision, "readonly": false,
                    "edits": edits.map { edit in
                        ["range": ["startLineNumber": edit.range.start.line + 1,
                                   "startColumn": edit.range.start.utf16Column + 1,
                                   "endLineNumber": edit.range.end.line + 1,
                                   "endColumn": edit.range.end.utf16Column + 1], "text": edit.newText] as [String: Any]
                    }] as [String: Any]
        }
    }

    private func observeDebugState(model: AppModel) {
        let identity = model.genericDebugFeatureIfActive.map(ObjectIdentifier.init)
        guard debugFeatureIdentity != identity else { return }
        debugFeatureIdentity = identity
        debugSubscription = nil
        if let feature = model.genericDebugFeatureIfActive {
            // Only editor-facing changes trigger bridge updates; console output
            // and expansion of child variables do not refresh source decorations.
            debugSubscription = Publishers.CombineLatest3(feature.$breakpoints, feature.$selectedFrame, feature.$areBreakpointsMuted)
                .combineLatest(feature.$state)
                .combineLatest(feature.$variables, feature.$automaticVariables)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak model] _ in
                    guard let self, let model else { return }
                    self.refreshDebugState(model: model)
                }
        }
        refreshDebugState(model: model)
    }

    private func observeCodeVision(model: AppModel) {
        if codeVisionSubscription == nil {
            codeVisionSubscription = model.javaFeature.$javaCodeVisionHints
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.call("window.lithe.codeVisionRefresh()") }
        }
        if lastCodeVisionEnabled != model.settings.showCodeVision {
            lastCodeVisionEnabled = model.settings.showCodeVision
            call("window.lithe.codeVisionRefresh()")
        }
    }

    private func refreshGitState(model: AppModel, loadMissing: Bool = true) {
        if blameVisibilitySubscription == nil {
            blameVisibilitySubscription = model.$blameVisibleURL.receive(on: DispatchQueue.main)
                .sink { [weak self, weak model] _ in
                    guard let self, let model else { return }
                    self.refreshGitState(model: model)
                }
        }
        let feature = model.gitFeatureIfActive
        let identity = feature.map(ObjectIdentifier.init)
        if identity != gitFeatureIdentity {
            gitFeatureIdentity = identity
            gitSubscription = nil
            if let feature {
                gitSubscription = feature.$gitLineChangeMarkers.combineLatest(feature.$gitBlameLines).receive(on: DispatchQueue.main)
                .sink { [weak self, weak model] _ in
                    guard let self, let model else { return }
                    self.refreshGitState(model: model)
                }
            }
        }
        for (id, document) in documents {
            let url = document.url.standardizedFileURL
            let blameVisible = model.blameVisibleURL?.standardizedFileURL == url
            if loadMissing, blameVisible, let feature, model.gitBlameLines[url] == nil, blameLoads[id] == nil {
                blameLoads[id] = Task { @MainActor [weak self, weak model] in
                    _ = await feature.loadBlame(for: url)
                    guard let self, !Task.isCancelled else { return }
                    self.blameLoads[id] = nil
                    if let model { self.refreshGitState(model: model, loadMissing: false) }
                }
            }
            let markers = model.gitLineChangeMarkers(for: url)
            if loadMissing, feature != nil, markers == nil, gitLoads[id] == nil {
                gitLoads[id] = Task { @MainActor [weak self, weak model] in
                    await model?.loadGitLineChanges(for: url)
                    guard let self, !Task.isCancelled else { return }
                    self.gitLoads[id] = nil
                    if let model { self.refreshGitState(model: model, loadMissing: false) }
                }
            }
            let change = model.gitChange(for: url)
            let working = change?.hasWorkingTreeChange == true
            let payload: [String: Any] = ["revision": revisions[id] ?? 0,
                "blameVisible": blameVisible, "blame": blameVisible ? (model.gitBlameLines[url] ?? []).map { line in
                    ["line": line.line + 1, "commit": line.commitHash, "author": line.authorName, "date": line.date] as [String: Any]
                } : [], "markers": (markers ?? []).map { marker in
                ["id": marker.id, "line": marker.line + 1, "kind": marker.kind.rawValue,
                 "stage": working, "unstage": change?.isStaged == true && !working, "discard": working] as [String: Any]
            }]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  lastGitStates[id] != data else { continue }
            lastGitStates[id] = data
            call("window.lithe.gitState(id, payload)", arguments: ["id": id, "payload": payload])
        }
    }

    private func refreshDebugState(model: AppModel) {
        let feature = model.genericDebugFeatureIfActive
        if let feature, feature.state == .paused, feature.providerID == "java",
           let frame = feature.selectedFrame, let url = frame.sourceURL?.standardizedFileURL,
           let document = documents.values.first(where: { $0.url.standardizedFileURL == url }) {
            // The debug feature deduplicates this frame/expression set and rejects
            // responses after its inspection generation or selected frame changes.
            feature.requestAutomaticVariables(DebugAutomaticExpressionProjection.javaExpressions(
                forLine: max(0, frame.line - 1), in: document.text as NSString
            ))
        }
        for (id, document) in documents {
            guard !unconfirmedModels.contains(id) else { continue }
            let url = document.url.standardizedFileURL
            let grouped = Dictionary(grouping: (feature?.breakpoints ?? []).filter { $0.fileURL.standardizedFileURL == url }, by: \.line)
            let points: [[String: Any]] = grouped.keys.sorted().map { line in
                let values = grouped[line] ?? []
                var point: [String: Any] = ["line": line, "enabled": values.contains { $0.enabled },
                                          "verified": values.contains { $0.verified }, "logpoint": values.contains { $0.isLogpoint }]
                point["conditional"] = values.contains { $0.condition?.isEmpty == false || $0.hitCondition?.isEmpty == false }
                if let message = values.compactMap(\.message).first { point["message"] = message }
                return point
            }
            var state: [String: Any] = ["breakpoints": points, "muted": feature?.areBreakpointsMuted ?? false]
            state["revision"] = revisions[id] ?? 0
            state["paused"] = feature?.state == .paused
            state["canRunToCursor"] = feature?.state == .paused && feature?.capabilities.supportsGotoTargetsRequest == true
            if feature?.state == .paused, let frame = feature?.selectedFrame, frame.sourceURL?.standardizedFileURL == url {
                state["executionLine"] = frame.line
                state["variables"] = feature?.presentedVariables.map { ["name": $0.name, "value": $0.value] } ?? []
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                guard lastDebugStates[id] != data else { continue }
                lastDebugStates[id] = data
                call("window.lithe.debugState(id, state)", arguments: ["id": id, "state": state])
            } catch { fail(error.localizedDescription) }
        }
    }

    private func present(document: EditorDocument, model: AppModel, fontSize: Double, dark: Bool, wrap: Bool, markers: [EditorDiagnostic], surface: String = "primary") {
        guard viewOwnerID != nil else { return }
        let id = document.id.uuidString
        let liveIDs = Set(model.documentFeature.editorDocuments.map { $0.id.uuidString })
        for oldID in Array(documentReferences.keys) where !liveIDs.contains(oldID) {
            documentLocations[oldID] = nil
            documentReadOnlyStates[oldID] = nil
            documents[oldID]?.synchronizeEditor = nil
            documents[oldID]?.holdEditorForClose = nil
            completionLists[oldID] = nil
            codeActionLists[oldID] = nil
            codeActionCommands[oldID] = nil
            unconfirmedModels.remove(oldID)
            lastDebugStates[oldID] = nil
            javaNavigationLists[oldID] = nil
            javaNavigationRequests[oldID] = nil
            lastGitStates[oldID] = nil
            gitLoads.removeValue(forKey: oldID)?.cancel()
            blameLoads.removeValue(forKey: oldID)?.cancel()
            documentReferences[oldID] = nil; subscriptions[oldID] = nil; readOnlySubscriptions[oldID] = nil
            revisions[oldID] = nil; lastMarkers[oldID] = nil
        }
        let needsModel = documents[id] == nil || unconfirmedModels.contains(id)
        if needsModel { register(document) }
        let locationChanged = documentLocations[id] != document.locationRevision
        let readOnlyChanged = documentReadOnlyStates[id] != document.isReadOnly
        documentLocations[id] = document.locationRevision
        documentReadOnlyStates[id] = document.isReadOnly
        if activeIDs[surface] == id, locationChanged || readOnlyChanged {
            call("window.lithe.updateDocument(payload)", arguments: ["payload": ["id": id,
                "filename": document.url.lastPathComponent, "locationRevision": document.locationRevision,
                "readonly": document.isReadOnly]])
        }
        if activeIDs[surface] != id {
            activeIDs[surface] = id
            let interval = LitheSignpost.begin("monaco.document.activate")
            var payload: [String: Any] = ["id": id,
                "revision": revisions[id] ?? 0, "filename": document.url.lastPathComponent,
                "locationRevision": document.locationRevision, "readonly": document.isReadOnly, "focus": surface == "primary",
                "measure": LithePerformanceBaseline.isEnabled]
            // A retained Monaco model already owns its current text and undo
            // history. Tab activation only needs its identity and view state.
            if needsModel { payload["text"] = document.text }
            call(surface == "primary" ? "window.lithe.activate(payload)" : "window.lithe.showSecondary(payload)", arguments: ["payload": payload]) { [weak self] result in
                LitheSignpost.end("monaco.document.activate", interval)
                if case .failure(let error) = result { self?.fail(error.localizedDescription) }
                else {
                    self?.unconfirmedModels.remove(id)
                    self?.refreshDebugState(model: model)
                }
            }
        }
        if lastLiveIDs != liveIDs {
            lastLiveIDs = liveIDs
            call("window.lithe.retain(ids)", arguments: ["ids": Array(liveIDs).sorted()])
        }
        observeDebugState(model: model)
        observeCodeVision(model: model)
        refreshGitState(model: model)
        refreshDebugState(model: model)
        let semanticState = model.semanticHighlightingSessionState
        if lastSemanticState != semanticState {
            lastSemanticState = semanticState
            call("window.lithe.semanticRefresh()")
        }
        let configurationKey = "\(fontSize):\(dark):\(wrap)"
        if lastConfiguration != configurationKey {
            lastConfiguration = configurationKey
            call("window.lithe.configure(payload)", arguments: ["payload": ["fontSize": fontSize, "fontFamily": LitheTheme.editorFont(size: fontSize).familyName ?? "monospace", "dark": dark, "wrap": wrap]])
        }
        if lastMarkers[id] != markers {
            lastMarkers[id] = markers
            let values: [[String: Any]] = markers.map { marker in
                ["startLineNumber": marker.line + 1, "startColumn": marker.utf16Column + 1,
                 "endLineNumber": marker.endLine + 1, "endColumn": marker.endUTF16Column + 1,
                 "message": marker.message, "severity": [1: 8, 2: 4, 3: 2, 4: 1][marker.severity.rawValue] ?? 2]
            }
            call("window.lithe.markers(id, markers)", arguments: ["id": id, "markers": values])
        }
        if let target = model.editorNavigationTarget, target.url.standardizedFileURL == document.url.standardizedFileURL,
           navigationID != target.id {
            navigationID = target.id
            call("window.lithe.navigate(payload)", arguments: ["payload": ["id": id, "line": target.line, "column": target.utf16Column]])
        }
    }

    func call(_ script: String, arguments: [String: Any] = [:], completion: ((Result<Any?, Error>) -> Void)? = nil) {
        guard let webView else { completion?(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return }
        let operation = UUID()
        pending[operation] = completion ?? { [weak self] result in
            if case .failure(let error) = result { self?.fail(error.localizedDescription) }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.pending.removeValue(forKey: operation)?(.failure(EditorDocument.DocumentError.editorNotSynchronized))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        webView.callAsyncJavaScript("return await \(script)", arguments: arguments, in: nil, in: .page) { [weak self] result in
            timeout.cancel()
            self?.pending.removeValue(forKey: operation)?(result.map { Optional($0) })
        }
    }

    private func synchronize(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard synchronizingIDs.insert(id).inserted else {
            completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return
        }
        let operationID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        let nativeRevision = revisions[id] ?? -1
        let nativeLength = documents[id]?.text.utf16.count ?? -1
        NSLog("[monaco.sync] phase=freeze-request operationID=\(operationID) documentID=\(id) revision=\(nativeRevision) utf16Length=\(nativeLength)")
        call("window.lithe.freeze(id, operationID)", arguments: ["id": id, "operationID": operationID]) { [weak self] result in
            guard let self else { completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return }
            let synchronized: Result<Void, Error>
            switch result {
            case .success(let value):
                let snapshot = value as? [String: Any]
                let snapshotText = snapshot?["text"] as? String
                let snapshotRevision = snapshot?["revision"] as? Int
                let snapshotOperation = snapshot?["operationID"] as? String
                let barrierDrained = snapshot?["barrierDrained"] as? Bool ?? false
                let browserRevision = snapshot?["currentRevision"] as? Int ?? -1
                let pendingEdits = snapshot?["pendingEdits"] as? Int ?? -1
                let modelVersion = snapshot?["modelVersion"] as? Int ?? -1
                let inputPasses = snapshot?["inputPasses"] as? Int ?? -1
                let currentRevision = self.revisions[id] ?? -1
                let currentLength = self.documents[id]?.text.utf16.count ?? -1
                let exactSnapshot = snapshotRevision == currentRevision && snapshotText == self.documents[id]?.text
                // Input remains writable during synchronization. A native
                // revision ahead of the returned snapshot means a later edit
                // already crossed the ordered bridge; saving the native model
                // is therefore safe and must not discard that newer edit.
                let nativeAdvanced = (snapshotRevision ?? Int.max) < currentRevision
                let matches = !self.failed && snapshotOperation == operationID && barrierDrained &&
                    (exactSnapshot || nativeAdvanced)
                let durationMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                NSLog("[monaco.sync] phase=freeze-result operationID=\(operationID) documentID=\(id) status=\(matches ? "matched" : "mismatch") durationMs=\(String(format: "%.1f", durationMs)) snapshotRevision=\(snapshotRevision ?? -1) browserRevision=\(browserRevision) nativeRevision=\(currentRevision) modelVersion=\(modelVersion) barrierDrained=\(barrierDrained) pendingEdits=\(pendingEdits) inputPasses=\(inputPasses) snapshotUTF16Length=\(snapshotText?.utf16.count ?? -1) nativeUTF16Length=\(currentLength)")
                if matches { synchronized = .success(()) }
                else {
                    synchronized = .failure(EditorDocument.DocumentError.editorNotSynchronized)
                }
            case .failure(let error):
                let nsError = error as NSError
                let durationMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                NSLog("[monaco.sync] phase=freeze-result operationID=\(operationID) documentID=\(id) status=failed durationMs=\(String(format: "%.1f", durationMs)) domain=\(nsError.domain) code=\(nsError.code)")
                synchronized = .failure(error)
            }
            self.call("window.lithe.unlock(id, operationID)", arguments: ["id": id, "operationID": operationID]) { [weak self] unlockResult in
                guard let self else { completion(.failure(EditorDocument.DocumentError.editorNotSynchronized)); return }
                self.synchronizingIDs.remove(id)
                if case .failure(let error) = unlockResult {
                    let nsError = error as NSError
                    NSLog("[monaco.sync] phase=unlock operationID=\(operationID) documentID=\(id) status=failed domain=\(nsError.domain) code=\(nsError.code)")
                    completion(.failure(error))
                } else {
                    NSLog("[monaco.sync] phase=unlock operationID=\(operationID) documentID=\(id) status=success")
                    completion(synchronized)
                }
            }
        }
    }


    private func presentMarkdownScroll(document: EditorDocument, binding: Binding<MarkdownScrollPosition>?) {
        let id = binding == nil ? nil : document.id.uuidString
        let changed = id != markdownScrollID
        markdownScrollBinding = binding
        markdownScrollID = id
        if changed { markdownScrollRevision = nil }
        guard let id, let position = binding?.wrappedValue else {
            if changed { call("window.lithe.markdownScroll(null)") }
            return
        }
        guard changed || markdownScrollRevision != position.revision else { return }
        markdownScrollRevision = position.revision
        var payload: [String: Any] = ["id": id]
        if position.source == .preview { payload["ratio"] = position.ratio }
        call("window.lithe.markdownScroll(payload)", arguments: ["payload": payload])
    }

    private func currentDocument(_ id: String) -> EditorDocument? {
        guard let document = documents[id],
              model?.documentFeature.editorDocuments.contains(where: { $0 === document }) == true else { return nil }
        return document
    }

    private func isCurrent(_ context: MonacoDocumentContext, allowTextChanges: Bool = false) -> Bool {
        guard !failed, let model, let document = currentDocument(context.documentID.uuidString) else { return false }
        let documents = model.documentFeature.editorDocuments
        if allowTextChanges {
            return context.matchesIdentity(document: document, documents: documents, workspaceURL: model.workspaceURL)
        }
        return context.matches(document: document, revision: revisions[context.documentID.uuidString],
            documents: documents, workspaceURL: model.workspaceURL)
    }

    func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "lithe-editor",
              message.frameInfo.securityOrigin.host == "app", let body = message.body as? [String: Any],
              let type = body["type"] as? String else { reply(nil, "Untrusted editor message"); return }
        if type == "ready" {
            if let interval = loadingInterval {
                LitheSignpost.end("monaco.webview.load", interval)
                loadingInterval = nil
            }
            ready = true; latestUpdate?(); reply(["ok": true], nil); return
        }
        if type == "performance" {
            if LithePerformanceBaseline.isEnabled,
               let metrics = body["metrics"] as? [String: Any],
               JSONSerialization.isValidJSONObject(metrics),
               let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data("LITHE_MONACO_OPEN \(json)\n".utf8))
            }
            reply(["ok": true], nil); return
        }
        if type == "failure" { fail(body["message"] as? String ?? "Editor failed"); reply(["ok": true], nil); return }
        // Import completion may arrive after its document has closed. The
        // notification still explains where the already saved asset went.
        if type == "editorNotification" {
            if let message = body["message"] as? String { model?.showNotification(message) }
            reply(["ok": true], nil); return
        }
        guard let id = body["id"] as? String, let document = currentDocument(id), let revision = revisions[id] else {
            reply(nil, "Document closed"); return
        }
        let context = MonacoDocumentContext(document: document, revision: revision, workspaceURL: model?.workspaceURL)
        // Text edits still belong to the same buffer after a move, and saves must
        // drain them. Position-based tooling must use the current file identity.
        if type != "edit", type != "save", let locationRevision = body["locationRevision"] as? UInt64,
           locationRevision != document.locationRevision {
            reply(["cancelled": true], nil); return
        }
        switch type {
        case "markdownScroll":
            guard markdownScrollID == id, let binding = markdownScrollBinding,
                  let ratio = body["ratio"] as? Double, ratio.isFinite else { reply(["cancelled": true], nil); return }
            var position = binding.wrappedValue
            if position.update(ratio: ratio, source: .editor) {
                markdownScrollRevision = position.revision
                binding.wrappedValue = position
            }
            reply(["ok": true], nil)
        case "javaNavigation":
            guard let model, !failed, document.url.pathExtension.lowercased() == "java",
                  let revision = body["revision"] as? Int, revision == revisions[id] else {
                reply(["markers": []], nil); return
            }
            let url = document.url
            let requestID = UUID()
            javaNavigationRequests[id] = requestID
            Task { @MainActor [weak self, weak document, weak model] in
                guard let self, let document, let model, self.isCurrent(context) else { reply(["cancelled": true], nil); return }
                let markers = await model.javaNavigationMarkers(for: document)
                guard self.isCurrent(context), self.revisions[id] == revision, document.url == url,
                      self.javaNavigationRequests[id] == requestID else {
                    reply(["cancelled": true], nil); return
                }
                self.javaNavigationLists[id] = (context, revision, url, markers)
                reply(["markers": markers.map { ["id": $0.id, "line": $0.line + 1, "direction": $0.direction.rawValue, "relation": $0.relation.rawValue] as [String: Any] }], nil)
            }
        case "javaNavigationAction":
            guard let model, !failed, let revision = body["revision"] as? Int, revision == revisions[id],
                  let list = javaNavigationLists[id], isCurrent(list.context), list.revision == revision, list.url == document.url,
                  document.url.pathExtension.lowercased() == "java",
                  let markerID = body["marker"] as? String,
                  let marker = list.markers.first(where: { $0.id == markerID }) else {
                reply(["cancelled": true], nil); return
            }
            model.editorDidFocus(document)
            model.resolveJavaNavigation(marker, in: document.url)
            reply(["ok": true], nil)
        case "blameCommit":
            guard let model, !failed, body["revision"] as? Int == revisions[id],
                  model.blameVisibleURL?.standardizedFileURL == document.url.standardizedFileURL,
                  let line = body["line"] as? Int, let commit = body["commit"] as? String,
                  model.gitBlameLines[document.url.standardizedFileURL]?.contains(where: { $0.line + 1 == line && $0.commitHash == commit }) == true else {
                reply(["cancelled": true], nil); return
            }
            Task { @MainActor in
                guard self.isCurrent(context) else { reply(["cancelled": true], nil); return }
                await model.showGitCommit(commit)
                reply(["ok": true], nil)
            }
        case "gitLineAction":
            guard let model, !failed, body["revision"] as? Int == revisions[id],
                  let markerID = body["marker"] as? String,
                  let marker = model.gitLineChangeMarkers(for: document.url)?.first(where: { $0.id == markerID }),
                  let action = body["action"] as? String else { reply(["cancelled": true], nil); return }
            let change = model.gitChange(for: document.url)
            let working = change?.hasWorkingTreeChange == true
            guard action == "show" || (!document.isReadOnly &&
                ((action == "stage" || action == "discard") && working || action == "unstage" && change?.isStaged == true && !working)) else {
                reply(["cancelled": true], nil); return
            }
            let url = document.url
            Task { @MainActor in
                guard self.isCurrent(context) else { reply(["cancelled": true], nil); return }
                switch action {
                case "show": await model.showGitLineChange(marker, for: url)
                case "stage": await model.stageGitLineChange(marker, for: url)
                case "unstage": await model.unstageGitLineChange(marker, for: url)
                case "discard": await model.requestDiscardGitLineChange(marker, for: url)
                default: break
                }
                reply(["ok": true], nil)
            }
        case "codeVision":
            guard let model, body["revision"] as? Int == revisions[id], model.settings.showCodeVision else {
                reply(["hints": []], nil); return
            }
            let hints = model.javaCodeVisionHints[document.url.standardizedFileURL] ?? []
            reply(["hints": hints.map { hint in
                ["id": hint.id, "line": hint.line + 1, "usageCount": hint.usageCount,
                 "implementationCount": hint.implementationCount, "authorName": hint.authorName ?? ""] as [String: Any]
            }], nil)
        case "codeVisionAction":
            guard let model, body["revision"] as? Int == revisions[id], model.settings.showCodeVision,
                  let hintID = body["hint"] as? String,
                  let hint = model.javaCodeVisionHints[document.url.standardizedFileURL]?.first(where: { $0.id == hintID }) else {
                reply(["cancelled": true], nil); return
            }
            model.editorDidFocus(document)
            switch body["action"] as? String {
            case "usages": model.findUsages(for: hint, in: document.url)
            case "implementations": model.findJavaImplementations(line: hint.line, utf16Column: hint.utf16Column, in: document.url)
            case "author": model.showBlame(for: document.url)
            default: reply(nil, "Unknown CodeVision action"); return
            }
            reply(["ok": true], nil)
        case "prepareImagePaste":
            guard !failed, !document.isReadOnly, body["revision"] as? Int == revisions[id] else {
                reply(["cancelled": true], nil); return
            }
            do {
                guard ["md", "markdown"].contains(document.url.pathExtension.lowercased()) else {
                    throw MarkdownImageImportError.notMarkdownDocument
                }
                guard model?.workspaceURL != nil else { throw MarkdownImageImportError.unavailableWorkspace }
                guard let mimeType = body["mimeType"] as? String,
                      let count = body["byteCount"] as? Int, count > 0 else { throw MarkdownImageImportError.emptyImage }
                _ = try MonacoImagePastePayload.format(mimeType: mimeType)
                guard count <= MarkdownImageSource.maximumByteCount else { throw MarkdownImageImportError.imageTooLarge }
                reply(["maximumByteCount": MarkdownImageSource.maximumByteCount], nil)
            } catch { reply(nil, error.localizedDescription) }
        case "pasteImage":
            guard let model, !failed, !document.isReadOnly,
                  let revision = body["revision"] as? Int, revision == revisions[id],
                  let offset = body["offset"] as? Int, let length = body["length"] as? Int,
                  let base64 = body["base64"] as? String, let mimeType = body["mimeType"] as? String else {
                reply(["cancelled": true], nil); return
            }
            let source: MarkdownImageSource
            do {
                source = try MonacoImagePastePayload.source(base64: base64, mimeType: mimeType, filename: body["filename"] as? String)
            } catch { reply(nil, error.localizedDescription); return }
            // Selection offsets belong to Monaco's LF model, not the source's
            // potentially mixed CR/LF/CRLF coordinates. Only spacing is computed
            // here; Monaco owns the eventual edit and its undo transaction.
            let normalized = document.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let count = (normalized as NSString).length
            guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
                reply(nil, "Invalid image insertion range"); return
            }
            let originalURL = document.url
            Task { @MainActor [weak self, weak document, weak model] in
                guard let self, let document, let model, self.isCurrent(context) else { reply(["cancelled": true], nil); return }
                do {
                    let result = try await model.importMarkdownImage(source, for: document)
                    guard self.isCurrent(context), self.revisions[id] == revision,
                          document.url == originalURL, !document.isReadOnly, !self.failed else {
                        model.showNotification("Saved image to \(result.relativePath); insertion cancelled because the document changed")
                        reply(["cancelled": true], nil); return
                    }
                    let text = MarkdownImageInsertion.blockText(reference: result.markdownReference,
                        in: normalized, replacing: NSRange(location: offset, length: length))
                    model.showNotification("Saved image to \(result.relativePath)")
                    reply(["text": text], nil)
                } catch {
                    model.showNotification("Could not paste image: \(error.localizedDescription)")
                    reply(["cancelled": true], nil)
                }
            }
        case "edit":
            guard !document.isReadOnly, !failed, body["baseRevision"] as? Int == revisions[id],
                  let changes = body["changes"] as? [[String: Any]] else { reply(nil, "Stale editor edit"); return }
            var bound = (document.text as NSString).length
            let ordered = changes.sorted { ($0["offset"] as? Int ?? -1) > ($1["offset"] as? Int ?? -1) }
            if synchronizingIDs.contains(id) {
                let insertedLength = ordered.reduce(0) { $0 + (($1["text"] as? String)?.utf16.count ?? 0) }
                let replacedLength = ordered.reduce(0) { $0 + ($1["length"] as? Int ?? 0) }
                NSLog("[monaco.sync] phase=edit-during-freeze documentID=\(id) baseRevision=\(body["baseRevision"] as? Int ?? -1) nativeRevision=\(revisions[id] ?? -1) changeCount=\(ordered.count) insertedUTF16Length=\(insertedLength) replacedUTF16Length=\(replacedLength)")
            }
            for change in ordered {
                guard let offset = change["offset"] as? Int, let length = change["length"] as? Int,
                      change["text"] is String, offset >= 0, length >= 0, offset <= bound, length <= bound - offset else {
                    reply(nil, "Invalid UTF-16 edit batch"); return
                }
                bound = offset
            }
            applyingEdit = true
            for change in ordered {
                let range = NSRange(location: change["offset"] as! Int, length: change["length"] as! Int)
                let replacement = change["text"] as! String
                let previous = document.text
                document.applyLiveEditorEdit(replacedRange: range, replacement: replacement)
                model?.applyDebugSourceEdit(fileURL: document.url, previousSource: previous, replacedRange: range, replacement: replacement)
            }
            applyingEdit = false
            revisions[id, default: 0] += 1
            model?.documentFeature.promotePreviewDocument(document)
            model?.documentDidChange(document)
            if let model { refreshDebugState(model: model) }
            reply(["revision": revisions[id] ?? 0], nil)
        case "save":
            model?.saveEditorDocument(document); reply(["ok": true], nil)
        case "findState":
            if let model, body["token"] as? String == findToken, model.isFindBarVisible,
               !currentMountIsPreview, (model.focusedEditorDocument ?? model.activeDocument)?.id.uuidString == id,
               let index = body["index"] as? Int, let count = body["count"] as? Int,
               count >= 0, (count == 0 ? index == 0 : (0..<count).contains(index)) {
                model.updateFindState(currentIndex: index, count: count)
            }
            reply(["ok": true], nil)
        case "focus", "cursor":
            model?.editorDidFocus(document)
            synchronizeFind()
            if let line = body["line"] as? Int, let column = body["column"] as? Int {
                model?.editorCaret = EditorCaret(url: document.url, line: line, utf16Column: column)
            }
            reply(["ok": true], nil)
        case "toggleBreakpoint", "editBreakpoint", "runToCursor":
            guard body["revision"] as? Int == revisions[id], let line = body["line"] as? Int,
                  line >= 1, !document.isReadOnly else { reply(["cancelled": true], nil); return }
            if type == "toggleBreakpoint" { model?.toggleDebugBreakpoint(fileURL: document.url, line: line) }
            else if type == "runToCursor" {
                guard let column = body["column"] as? Int, column >= 1 else { reply(["cancelled": true], nil); return }
                model?.runToCursor(fileURL: document.url, line: line, column: column)
            }
            else { model?.editDebugBreakpoint(fileURL: document.url, line: line) }
            reply(["ok": true], nil)
        case "inlayHints":
            guard let model, body["revision"] as? Int == revisions[id],
                  let line = body["line"] as? Int, let column = body["column"] as? Int,
                  let endLine = body["endLine"] as? Int, let endColumn = body["endColumn"] as? Int else {
                reply(["cancelled": true], nil); return
            }
            let revision = revisions[id]
            let range = LanguageServerRange(start: .init(line: line, utf16Column: column),
                                            end: .init(line: endLine, utf16Column: endColumn))
            model.requestLanguageInlayHints(for: document, range: range) { [weak self] result in
                guard let self, self.isCurrent(context), self.revisions[id] == revision else {
                    reply(["cancelled": true], nil); return
                }
                switch result {
                case .failure(let error): reply(nil, error.localizedDescription)
                case .success(let hints):
                    reply(["hints": hints.map { hint in
                        var value: [String: Any] = ["position": ["lineNumber": hint.position.line + 1, "column": hint.position.utf16Column + 1],
                            "label": hint.label, "paddingLeft": hint.paddingLeft, "paddingRight": hint.paddingRight,
                            "textEdits": hint.textEdits.map { edit in
                                ["range": ["startLineNumber": edit.range.start.line + 1, "startColumn": edit.range.start.utf16Column + 1,
                                           "endLineNumber": edit.range.end.line + 1, "endColumn": edit.range.end.utf16Column + 1],
                                 "text": edit.newText] as [String: Any]
                            }]
                        if let kind = hint.kind { value["kind"] = kind }
                        if let tooltip = hint.tooltip { value["tooltip"] = tooltip }
                        return value
                    }], nil)
                }
            }
        case "semantic":
            guard let model, body["revision"] as? Int == revisions[id] else { reply(["cancelled": true], nil); return }
            let revision = revisions[id]
            model.requestSemanticTokens(for: document) { [weak self] result in
                guard let self, self.revisions[id] == revision, self.isCurrent(context) else { reply(["cancelled": true], nil); return }
                switch result {
                case .success(let tokens):
                    do {
                        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tokens))
                        if LithePerformanceBaseline.isEnabled {
                            FileHandle.standardError.write(Data("LITHE_MONACO_SEMANTIC tokens=\(tokens.tokens.count) revision=\(revision ?? -1)\n".utf8))
                        }
                        reply(value, nil)
                    } catch { reply(nil, error.localizedDescription) }
                case .failure(let error):
                    if error is CancellationError { reply(["cancelled": true], nil) }
                    else { reply(nil, error.localizedDescription) }
                }
            }
        case "format":
            guard let model, body["revision"] as? Int == revisions[id] else {
                reply(["cancelled": true], nil); return
            }
            let revision = revisions[id]
            model.requestLanguageFormattingEdits(for: document) { [weak self] result in
                guard let self, self.revisions[id] == revision, self.isCurrent(context) else {
                    reply(["cancelled": true], nil); return
                }
                switch result {
                case .success(let edits):
                    reply(["edits": edits.map { edit in
                        ["range": ["startLineNumber": edit.range.start.line + 1,
                                   "startColumn": edit.range.start.utf16Column + 1,
                                   "endLineNumber": edit.range.end.line + 1,
                                   "endColumn": edit.range.end.utf16Column + 1],
                         "text": edit.newText] as [String: Any]
                    }], nil)
                case .failure(let error): reply(nil, error.localizedDescription)
                }
            }
        case "codeActions":
            guard let model, body["revision"] as? Int == revisions[id],
                  let line = body["line"] as? Int, let column = body["column"] as? Int,
                  let endLine = body["endLine"] as? Int, let endColumn = body["endColumn"] as? Int else {
                reply(["cancelled": true], nil); return
            }
            let revision = revisions[id], key = UUID().uuidString
            let root = model.workspaceURL
            let workspace = MonacoWorkspaceContext(documents: model.documentFeature.editorDocuments, workspaceURL: root)
            codeActionLists[id] = (context, workspace, revision, key, [])
            let range = LanguageServerRange(start: .init(line: line, utf16Column: column),
                                            end: .init(line: endLine, utf16Column: endColumn))
            model.requestLanguageCodeActions(for: document, line: line, utf16Column: column, range: range) { [weak self, weak model] actions in
                guard let self, let model, self.isCurrent(context), self.revisions[id] == revision,
                      self.codeActionLists[id]?.key == key, workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL) else { reply(["cancelled": true], nil); return }
                self.codeActionLists[id] = (context, workspace, revision, key, actions)
                reply(["list": key, "actions": actions.enumerated().map { index, action in
                    var value: [String: Any] = ["index": index, "title": action.title, "isPreferred": action.isPreferred]
                    if let kind = action.kind { value["kind"] = kind }
                    return value
                }], nil)
            }
        case "resolveCodeAction":
            guard let model, let list = codeActionLists[id], isCurrent(list.context),
                  list.workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL), list.revision == revisions[id],
                  body["revision"] as? Int == revisions[id], body["list"] as? String == list.key,
                  let index = body["index"] as? Int, list.items.indices.contains(index) else { reply(["cancelled": true], nil); return }
            let root = model.workspaceURL
            model.requestResolvedLanguageCodeAction(list.items[index], for: document) { [weak self, weak model] result in
                guard let self, let model, self.isCurrent(context), self.revisions[id] == list.revision,
                      self.codeActionLists[id]?.key == list.key,
                      list.workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL) else { reply(["cancelled": true], nil); return }
                switch result {
                case .failure(let error): reply(nil, error.localizedDescription)
                case .success(let action):
                    Task { @MainActor in
                        do {
                            let changes = try await self.workspaceEditPayload(action.edit ?? LanguageServerWorkspaceEdit(), model: model)
                            guard self.isCurrent(context), self.revisions[id] == list.revision,
                                  self.codeActionLists[id]?.key == list.key,
                                  list.workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL) else { reply(["cancelled": true], nil); return }
                            var response: [String: Any] = ["changes": changes]
                            if let command = action.command {
                                let key = UUID().uuidString
                                self.codeActionCommands[id] = (context, key, root, command)
                                response["command"] = key
                            }
                            reply(response, nil)
                        } catch { reply(nil, error.localizedDescription) }
                    }
                }
            }
        case "executeCodeAction":
            guard let model, let command = codeActionCommands[id], isCurrent(command.context, allowTextChanges: true), command.root == model.workspaceURL,
                  body["command"] as? String == command.key, body["revision"] as? Int == revisions[id] else {
                reply(["cancelled": true], nil); return
            }
            // Consume the opaque token before dispatch so retries cannot execute it twice.
            codeActionCommands[id] = nil
            model.executeLanguageCodeActionCommand(command.command, for: document) { result in
                switch result {
                case .success: reply(["ok": true], nil)
                case .failure(let error): reply(nil, error.localizedDescription)
                }
            }
        case "rename":
            guard let model, body["revision"] as? Int == revisions[id],
                  let line = body["line"] as? Int, let column = body["column"] as? Int,
                  let newName = body["newName"] as? String else { reply(["cancelled": true], nil); return }
            let revision = revisions[id]
            let root = model.workspaceURL
            let workspace = MonacoWorkspaceContext(documents: model.documentFeature.editorDocuments, workspaceURL: root)
            model.requestLanguageRenameEdits(for: document, line: line, utf16Column: column, newName: newName) { [weak self, weak model] result in
                guard let self, let model, self.isCurrent(context),
                      self.revisions[id] == revision, workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL) else { reply(["cancelled": true], nil); return }
                switch result {
                case .failure(let error): reply(nil, error.localizedDescription)
                case .success(let edit):
                    Task { @MainActor in
                        do {
                            let changes = try await self.workspaceEditPayload(edit, model: model)
                            guard self.isCurrent(context), self.revisions[id] == revision,
                                  workspace.matches(documents: model.documentFeature.editorDocuments, workspaceURL: model.workspaceURL) else { reply(["cancelled": true], nil); return }
                            reply(["changes": changes], nil)
                        } catch { reply(nil, error.localizedDescription) }
                    }
                }
            }
        case "resolveCompletion":
            guard let model, let list = completionLists[id], isCurrent(list.context), list.revision == revisions[id],
                  body["revision"] as? Int == revisions[id], body["completionList"] as? String == list.key,
                  let index = body["completionIndex"] as? Int, list.items.indices.contains(index) else {
                reply(["cancelled": true], nil); return
            }
            model.requestResolvedLanguageCompletion(list.items[index], for: document) { [weak self] result in
                guard let self, self.isCurrent(context), self.revisions[id] == list.revision,
                      self.completionLists[id]?.key == list.key else { reply(["cancelled": true], nil); return }
                switch result {
                case .success(let item): reply(["item": Self.completionPayload(item)], nil)
                case .failure(let error): reply(nil, error.localizedDescription)
                }
            }
        case "debugHover":
            guard let model, body["revision"] as? Int == revisions[id],
                  let expression = body["expression"] as? String,
                  expression.range(of: #"^[$_\p{L}][$_\p{L}\p{N}]*$"#, options: .regularExpression) != nil else {
                reply(["contents": ""], nil); return
            }
            let revision = revisions[id]
            model.requestDebugHover(expression: expression) { [weak self] value in
                guard let self, self.revisions[id] == revision, self.isCurrent(context) else {
                    reply(["contents": ""], nil); return
                }
                reply(["contents": value ?? ""], nil)
            }
        case "hover", "completion":
            guard let model, body["revision"] as? Int == revisions[id],
                  let line = body["line"] as? Int, let column = body["column"] as? Int else { reply(nil, "Stale language request"); return }
            let revision = revisions[id]
            if type == "hover" {
                model.requestLanguageHover(for: document, line: line, utf16Column: column) { [weak self] hover in
                    guard let self, self.revisions[id] == revision, self.isCurrent(context) else { reply(["contents": ""], nil); return }
                    reply(["contents": hover?.contents ?? ""], nil)
                }
            } else {
                let key = UUID().uuidString
                completionLists[id] = (context, revision, key, [])
                model.requestLanguageCompletions(for: document, line: line, utf16Column: column) { [weak self] items in
                    guard let self, self.revisions[id] == revision, self.isCurrent(context),
                          self.completionLists[id]?.key == key else { reply(["items": []], nil); return }
                    self.completionLists[id] = (context, revision, key, items)
                    let values = items.enumerated().map { index, item in
                        var value = Self.completionPayload(item)
                        value["completionList"] = key
                        value["completionIndex"] = index
                        return value
                    }
                    reply(["items": values], nil)
                }
            }
        case "definition":
            guard let model, !failed, body["revision"] as? Int == revisions[id],
                  let line = body["line"] as? Int, let column = body["column"] as? Int else {
                reply(["cancelled": true], nil); return
            }
            model.editorDidFocus(document)
            model.navigateToSymbol(line: line, utf16Column: column, in: document.url)
            reply(["ok": true], nil)
        default: reply(nil, "Unknown editor message")
        }
    }

    private static func completionPayload(_ item: LanguageServerCompletionItem) -> [String: Any] {
        func range(_ value: LanguageServerRange) -> [String: Int] {
            ["startLineNumber": value.start.line + 1, "startColumn": value.start.utf16Column + 1,
             "endLineNumber": value.end.line + 1, "endColumn": value.end.utf16Column + 1]
        }
        var value: [String: Any] = ["label": item.label, "insertText": item.textEdit?.newText ?? item.insertText,
            "detail": item.detail ?? "", "documentation": item.documentation ?? "", "insertTextFormat": item.insertTextFormat]
        if let kind = item.kind { value["kind"] = kind }
        if let sortText = item.sortText { value["sortText"] = sortText }
        if let filterText = item.filterText { value["filterText"] = filterText }
        if let edit = item.textEdit { value["range"] = range(edit.range) }
        value["additionalTextEdits"] = item.additionalTextEdits.map { ["range": range($0.range), "text": $0.newText] as [String: Any] }
        return value
    }

    private func fail(_ message: String) {
        failed = true
        model?.showNotification("Editor: \(message)")
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "lithe-editor://app/index.html" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Web content process terminated; synchronized edits remain in Lithe") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }

    isolated deinit {
        gitLoads.values.forEach { $0.cancel() }
        blameLoads.values.forEach { $0.cancel() }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "litheEditor", contentWorld: .page)
        // A surviving document remains guarded if teardown happened before a successful drain.
        // The stale weak synchronization callback fails instead of silently saving old content.
        pending.values.forEach { $0(.failure(EditorDocument.DocumentError.editorNotSynchronized)) }
    }
}
