import AppKit
import SwiftUI
import WebKit
import LitheGitModule

/// Read-only patch presentation. Git actions retain the host's hunk identity;
/// display line numbers are never used to construct a patch.
struct MonacoDiffEditor: View {
    let rows: [DiffRow]
    let fileExtension: String
    var highlightsWords = true
    var collapsesUnchangedRegions = true
    var showsDiffMap = true
    var sideBySide = true
    var selectedRowIDs: Set<DiffRowID> = []
    var searchRowIDs: Set<DiffRowID> = []
    var currentRowID: DiffRowID?
    var revealRowID: DiffRowID?
    var actions: [MonacoDiffAction] = []
    var onAction: (String, String) -> Void = { _, _ in }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var session = MonacoDiffSession()

    var body: some View {
        Group {
            if MonacoWorkbenchResources.directory == nil {
                Text("Editor resources are missing. Rebuild or reinstall Lithe.")
            } else if let error = session.error {
                Text(error).foregroundStyle(.secondary)
            } else {
                MonacoDiffSurface(session: session, input: self,
                    fontSize: settings.editorFontSize, dark: colorScheme == .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MonacoDiffAction: Equatable {
    let id: String
    let title: String
}

/// Store only presentation data, never the View's StateObject storage.
private struct MonacoDiffInput {
    let rows: [DiffRow]
    let fileExtension: String
    let highlightsWords: Bool
    let collapsesUnchangedRegions: Bool
    let showsDiffMap: Bool
    let sideBySide: Bool
    let selectedRowIDs: Set<DiffRowID>
    let searchRowIDs: Set<DiffRowID>
    let currentRowID: DiffRowID?
    let revealRowID: DiffRowID?
    let actions: [MonacoDiffAction]
    let onAction: (String, String) -> Void
    init(_ view: MonacoDiffEditor) {
        rows = view.rows; fileExtension = view.fileExtension
        highlightsWords = view.highlightsWords; collapsesUnchangedRegions = view.collapsesUnchangedRegions
        showsDiffMap = view.showsDiffMap; sideBySide = view.sideBySide
        selectedRowIDs = view.selectedRowIDs; searchRowIDs = view.searchRowIDs
        currentRowID = view.currentRowID; revealRowID = view.revealRowID
        actions = view.actions; onAction = view.onAction
    }
}

private struct MonacoDiffSurface: NSViewRepresentable {
    let session: MonacoDiffSession
    let input: MonacoDiffEditor
    let fontSize: Double
    let dark: Bool
    func makeNSView(context: Context) -> WKWebView { session.makeView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        session.update(input, fontSize: fontSize, dark: dark)
    }
    func makeCoordinator() -> MonacoDiffSession { session }
    static func dismantleNSView(_ view: WKWebView, coordinator: MonacoDiffSession) { coordinator.close() }
}

private final class MonacoDiffMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: MonacoDiffSession?
    init(_ session: MonacoDiffSession) { self.session = session }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.scheme == "lithe-editor",
              message.frameInfo.request.url?.host == "app",
              let session, let body = message.body as? [String: Any] else {
            replyHandler(nil, "Invalid diff message"); return
        }
        switch body["type"] as? String {
        case "ready": session.ready = true; session.flush(); replyHandler(["ok": true], nil)
        case "diffAction":
            guard let hunk = body["hunkID"] as? String, let action = body["action"] as? String else {
                replyHandler(nil, "Invalid diff action"); return
            }
            session.perform(hunk: hunk, action: action)
            replyHandler(["ok": true], nil)
        case "error": session.fail(body["message"] as? String ?? "Diff editor failed"); replyHandler(["ok": true], nil)
        default: replyHandler(nil, "Unsupported diff message")
        }
    }
}

@MainActor
private final class MonacoDiffSession: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var error: String?
    var ready = false
    private var view: WKWebView?
    private var input: MonacoDiffInput?
    private var fontSize = 13.0
    private var dark = false
    private var renderedRows: [DiffRow]?
    private var renderedOptions: NSDictionary?
    private var renderedSelection: NSDictionary?
    private var loadingDeadline: Task<Void, Never>?
    private var rendering = false
    private var revision = 0

    func makeView() -> WKWebView {
        if let view { return view }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let root = MonacoWorkbenchResources.directory {
            configuration.setURLSchemeHandler(MonacoWorkbenchAssets(root: root), forURLScheme: "lithe-editor")
        }
        configuration.userContentController.addScriptMessageHandler(MonacoDiffMessages(self), contentWorld: .page, name: "litheEditor")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view = webView
        webView.load(URLRequest(url: URL(string: "lithe-editor://app/index.html")!))
        loadingDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !self.ready else { return }
            self.fail("Diff editor could not start. Reopen the comparison to retry.")
        }
        return webView
    }

    func update(_ input: MonacoDiffEditor, fontSize: Double, dark: Bool) {
        self.input = MonacoDiffInput(input); self.fontSize = fontSize; self.dark = dark
        revision += 1
        flush()
    }

    // Serialize updates and coalesce refreshes while tokenizers load. Selection
    // and appearance updates do not resend all patch text across the WebView.
    func flush() {
        guard ready, !rendering, error == nil, let input, let view else { return }
        loadingDeadline?.cancel(); loadingDeadline = nil
        let options: [String: Any] = ["filename": "review.\(input.fileExtension)", "language": "plaintext",
            "sideBySide": input.sideBySide, "collapse": input.collapsesUnchangedRegions,
            "overview": input.showsDiffMap, "highlightWords": input.highlightsWords,
            "actions": input.actions.map { ["id": $0.id, "title": $0.title] }]
        let selection: [String: Any] = [
            "selectedIDs": input.rows.filter { input.selectedRowIDs.contains($0.id) }.map { key($0.id) },
            "searchIDs": input.rows.filter { input.searchRowIDs.contains($0.id) }.map { key($0.id) },
            "currentID": input.currentRowID.map(key) as Any? ?? NSNull(),
            "revealID": input.revealRowID.map(key) as Any? ?? NSNull()]
        let changed = renderedRows != input.rows || renderedOptions != options as NSDictionary
        var payload = options
        if changed {
            payload["rows"] = input.rows.map { row -> [String: Any] in
                ["id": key(row.id), "oldLine": row.oldLine as Any? ?? NSNull(),
                 "newLine": row.newLine as Any? ?? NSNull(), "left": row.left as Any? ?? NSNull(),
                 "right": row.rightText as Any? ?? NSNull(), "kind": String(describing: row.kind),
                 "hunkID": row.hunkID as Any? ?? NSNull()]
            }
        }
        let appearance: [String: Any] = ["fontSize": fontSize, "dark": dark, "wrap": false,
            "fontFamily": LitheTheme.editorFont(size: fontSize).familyName ?? "monospace"]
        let select = changed || renderedSelection != selection as NSDictionary
        rendering = true
        let sentRevision = revision
        weak var sentView = view
        view.callAsyncJavaScript("""
            window.lithe.configure(appearance);
            if (changed) await window.lithe.showDiff(payload);
            window.lithe.configureDiff({fontSize: appearance.fontSize, fontFamily: appearance.fontFamily});
            if (select) window.lithe.selectDiff(selection);
            """, arguments: ["appearance": appearance, "changed": changed, "payload": payload,
                             "select": select, "selection": selection], in: nil, in: .page) { [weak self] result in
            guard let self, self.view != nil, self.view === sentView else { return }
            self.rendering = false
            switch result {
            case .success:
                self.renderedRows = input.rows; self.renderedOptions = options as NSDictionary
                self.renderedSelection = selection as NSDictionary
                if self.revision != sentRevision { self.flush() }
            case .failure(let error): self.fail(error.localizedDescription)
            }
        }
    }

    private func key(_ id: DiffRowID) -> String {
        // Base64 excludes the separator; a missing hunk differs from an empty one.
        let hunk = id.hunkID.map { Data($0.utf8).base64EncodedString() } ?? "-"
        return "\(hunk):\(id.oldLine.map(String.init) ?? "-"):\(id.newLine.map(String.init) ?? "-"):\(id.sequence)"
    }
    func perform(hunk: String, action: String) {
        guard !rendering, let input, renderedRows == input.rows, input.actions.contains(where: { $0.id == action }),
              input.rows.contains(where: { $0.hunkID == hunk && $0.kind == .information }) else { return }
        input.onAction(hunk, action)
    }
    func fail(_ message: String) { error = message; loadingDeadline?.cancel() }
    func close() {
        loadingDeadline?.cancel(); loadingDeadline = nil
        view?.stopLoading(); view?.navigationDelegate = nil
        view?.configuration.userContentController.removeScriptMessageHandler(forName: "litheEditor", contentWorld: .page)
        view = nil; input = nil; ready = false; rendering = false
        renderedRows = nil; renderedOptions = nil; renderedSelection = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "lithe-editor://app/index.html" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("Diff editor stopped. Reopen the comparison to retry.") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    isolated deinit { loadingDeadline?.cancel() }
}
