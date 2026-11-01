import Foundation
import WebKit

/// Runs the offline upstream engine outside the document preview's WebView.
/// Note: .agents/notes/implemented/feature/2026-11-01-macos-offline-plantuml.md
@MainActor
final class MarkdownPlantUMLRenderer: NSObject, WKNavigationDelegate {
    static let messageName = "markdownPlantUML"
    static let maximumSourceBytes = 256 * 1024
    static let maximumSVGBytes = 4 * 1024 * 1024
    static let timeout: TimeInterval = 8

    private struct Request {
        let id: UUID
        let source: String
        let dark: Bool
        let webView: WKWebView
        let deadline: DispatchWorkItem
        let reply: (Any?, String?) -> Void
    }

    private var request: Request?

    func render(source: String, dark: Bool, reply: @escaping (Any?, String?) -> Void) {
        cancel()
        guard source.utf8.count <= Self.maximumSourceBytes else {
            reply(nil, "diagramSourceTooLarge")
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // The nonpersistent renderer has its own JavaScript context and no
        // document bridge. Its native deadline owns disposal.
        configuration.setURLSchemeHandler(MarkdownPlantUMLResources(), forURLScheme: MarkdownPlantUMLResources.scheme)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = WebMediaCaptureDenier.shared
        let id = UUID()
        let deadline = DispatchWorkItem { [weak self] in self?.finish(id, error: "diagramTimedOut") }
        request = Request(id: id, source: source, dark: dark, webView: webView, deadline: deadline, reply: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: deadline)
        webView.load(URLRequest(url: MarkdownPlantUMLResources.pageURL))
    }

    func cancel() {
        guard let request else { return }
        finish(request.id, error: "diagramCancelled")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let request, request.webView === webView else { return }
        let id = request.id
        webView.callAsyncJavaScript(
            "return window.LithePlantUML.render(source, dark)",
            arguments: ["source": request.source, "dark": request.dark], in: nil, in: .page
        ) { [weak self] result in
            guard let self, self.request?.id == id else { return }
            guard case let .success(value) = result,
                  let svg = value as? String,
                  svg.utf8.count <= Self.maximumSVGBytes,
                  svg.contains("<svg") else {
                self.finish(id, error: "diagramRenderFailed")
                return
            }
            // SVG is returned only as a passive image, never inserted into the
            // document DOM. SVG images cannot execute scripts or navigate.
            self.finish(id, image: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failed(webView)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url == MarkdownPlantUMLResources.pageURL ? .allow : .cancel)
    }

    private func failed(_ webView: WKWebView) {
        guard let request, request.webView === webView else { return }
        finish(request.id, error: "diagramRenderFailed")
    }

    private func finish(_ id: UUID, image: String? = nil, error: String? = nil) {
        guard let current = request, current.id == id else { return }
        request = nil
        current.deadline.cancel()
        current.webView.stopLoading()
        current.webView.navigationDelegate = nil
        current.webView.uiDelegate = nil
        current.reply(image, error)
    }
}

/// Exposes only fixed, bundled renderer inputs; no user paths or URL queries.
private final class MarkdownPlantUMLResources: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "lithe-plantuml"
    static let pageURL = URL(string: "lithe-plantuml://renderer/plantuml.html")!
    private static let files = [
        "/plantuml.html": "text/html",
        "/plantuml-renderer.js": "text/javascript",
        "/vendor/plantuml/plantuml.js": "text/javascript"
    ]
    private let tasks = LocalFileSchemeTasks()
    private let queue = DispatchQueue(label: "lithe.markdown.plantuml.resources", qos: .userInitiated)

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = tasks.register(task)
        let url = task.request.url
        let directory = MarkdownPreviewResources.directoryURL
        queue.async { [self] in
            do {
                guard let url, url.scheme == Self.scheme, url.host == "renderer",
                      url.query == nil, url.fragment == nil,
                      let mime = Self.files[url.path], let directory else {
                    throw URLError(.noPermissionsToReadFile)
                }
                let data = try Data(contentsOf: directory.appendingPathComponent(String(url.path.dropFirst())))
                let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
                DispatchQueue.main.async { [self] in
                    guard tasks.claim(id) else { return }
                    task.didReceive(response)
                    task.didReceive(data)
                    task.didFinish()
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    guard tasks.claim(id) else { return }
                    task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        tasks.stop(task)
    }
}
