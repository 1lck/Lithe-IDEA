import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum MarkdownPreviewResources {
    private static var resourceBundle: Bundle {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        let adjacentURL = Bundle.main.bundleURL
            .appendingPathComponent("Lithe_Lithe.bundle", isDirectory: true)
        if let packagedURL, let bundle = Bundle(url: packagedURL) {
            return bundle
        }
        if let bundle = Bundle(url: adjacentURL) {
            return bundle
        }
        return Bundle.module
    }

    static var directoryURL: URL? {
        resourceBundle.resourceURL?.appendingPathComponent("MarkdownPreview", isDirectory: true)
    }

    static var templateURL: URL? {
        directoryURL?.appendingPathComponent("index.html", isDirectory: false)
    }
}

enum MarkdownPreviewAssetResolver {
    static let scheme = "lithe-resource"

    static func resolve(
        requestURL: URL,
        documentURL: URL,
        workspaceURL: URL
    ) -> URL? {
        guard requestURL.scheme == scheme,
              let scope = requestURL.host,
              scope == "document" || scope == "workspace",
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let requestedPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !requestedPath.isEmpty,
              !requestedPath.hasPrefix("/"),
              !requestedPath.contains("\0") else {
            return nil
        }

        let root = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let base = scope == "workspace"
            ? root
            : documentURL.deletingLastPathComponent().standardizedFileURL
        let candidate = base
            .appendingPathComponent(requestedPath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }
}

final class MarkdownPreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private struct Scope {
        let documentURL: URL
        let workspaceURL: URL
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "lithe.markdown.assets", qos: .userInitiated)
    private var scope: Scope?
    private var taskStates: [ObjectIdentifier: Bool] = [:]

    func update(documentURL: URL, workspaceURL: URL?) {
        lock.withLock {
            scope = workspaceURL.map {
                Scope(documentURL: documentURL.standardizedFileURL, workspaceURL: $0.standardizedFileURL)
            }
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        let requestURL = urlSchemeTask.request.url
        let currentScope = lock.withLock { () -> Scope? in
            taskStates[taskID] = true
            return scope
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard let requestURL, let currentScope,
                  let fileURL = MarkdownPreviewAssetResolver.resolve(
                    requestURL: requestURL,
                    documentURL: currentScope.documentURL,
                    workspaceURL: currentScope.workspaceURL
                  ) else {
                self.finish(urlSchemeTask, id: taskID, error: Self.error(.fileReadNoPermission))
                return
            }

            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentTypeKey
                ])
                guard values.isRegularFile == true,
                      let contentType = values.contentType,
                      Self.isSupportedMedia(contentType),
                      (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
                    throw Self.error(.fileReadUnsupportedScheme)
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let response = URLResponse(
                    url: requestURL,
                    mimeType: contentType.preferredMIMEType ?? "application/octet-stream",
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                self.finish(urlSchemeTask, id: taskID, response: response, data: data)
            } catch {
                self.finish(urlSchemeTask, id: taskID, error: error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        lock.withLock {
            let taskID = ObjectIdentifier(urlSchemeTask)
            if taskStates[taskID] != nil {
                taskStates[taskID] = false
            }
        }
    }

    private func finish(
        _ task: any WKURLSchemeTask,
        id: ObjectIdentifier,
        response: URLResponse,
        data: Data
    ) {
        let shouldDeliver = lock.withLock {
            taskStates.removeValue(forKey: id) == true
        }
        guard shouldDeliver else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func finish(_ task: any WKURLSchemeTask, id: ObjectIdentifier, error: Error) {
        let shouldDeliver = lock.withLock {
            taskStates.removeValue(forKey: id) == true
        }
        guard shouldDeliver else { return }
        task.didFailWithError(error)
    }

    private static func isSupportedMedia(_ type: UTType) -> Bool {
        type.conforms(to: .image)
            || type.conforms(to: .audio)
            || type.conforms(to: .movie)
            || type.conforms(to: .audiovisualContent)
    }

    private static func error(_ code: CocoaError.Code) -> CocoaError {
        CocoaError(code, userInfo: [NSLocalizedDescriptionKey: "The Markdown asset is unavailable"])
    }
}

struct MarkdownPreviewWebView: NSViewRepresentable {
    struct Payload: Equatable {
        let html: String
        let documentURL: URL
        let workspaceURL: URL?
        let appearance: String

        var javaScriptValue: [String: Any] {
            [
                "html": html,
                "documentURL": documentURL.absoluteString,
                "workspaceURL": workspaceURL?.absoluteString ?? "",
                "appearance": appearance
            ]
        }
    }

    let payload: Payload
    var scrollPosition: Binding<MarkdownScrollPosition>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollPosition: scrollPosition)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            context.coordinator.assetHandler,
            forURLScheme: MarkdownPreviewAssetResolver.scheme
        )
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.scrollMessageName
        )
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadTemplate(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.assetHandler.update(
            documentURL: payload.documentURL,
            workspaceURL: payload.workspaceURL
        )
        context.coordinator.scrollPosition = scrollPosition
        context.coordinator.update(payload, in: webView)
        context.coordinator.updateScrollPosition(in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let scrollMessageName = "markdownScrollSync"

        let assetHandler = MarkdownPreviewAssetSchemeHandler()
        var scrollPosition: Binding<MarkdownScrollPosition>?
        private var isReady = false
        private var pendingPayload: Payload?
        private var lastPayload: Payload?
        private var pendingScrollPosition: MarkdownScrollPosition?
        private var lastObservedScrollRevision: UInt64?

        init(scrollPosition: Binding<MarkdownScrollPosition>?) {
            self.scrollPosition = scrollPosition
        }

        func loadTemplate(in webView: WKWebView) {
            guard let templateURL = MarkdownPreviewResources.templateURL,
                  let directoryURL = MarkdownPreviewResources.directoryURL else {
                webView.loadHTMLString(
                    "<p style='font:13px -apple-system;color:#888'>Markdown preview resources are missing.</p>",
                    baseURL: nil
                )
                return
            }
            webView.loadFileURL(templateURL, allowingReadAccessTo: directoryURL)
        }

        func update(_ payload: Payload, in webView: WKWebView) {
            guard payload != lastPayload else { return }
            lastPayload = payload
            guard isReady else {
                pendingPayload = payload
                return
            }
            apply(payload, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let payload = pendingPayload ?? lastPayload {
                pendingPayload = nil
                apply(payload, in: webView)
            }
            if let pendingScrollPosition {
                self.pendingScrollPosition = nil
                apply(pendingScrollPosition, in: webView)
            }
        }

        func updateScrollPosition(in webView: WKWebView) {
            guard let position = scrollPosition?.wrappedValue,
                  position.revision != lastObservedScrollRevision else { return }
            lastObservedScrollRevision = position.revision
            guard position.source == .editor else { return }
            guard isReady else {
                pendingScrollPosition = position
                return
            }
            apply(position, in: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.scrollMessageName,
                  let number = message.body as? NSNumber,
                  var position = scrollPosition?.wrappedValue,
                  position.update(ratio: number.doubleValue, source: .preview) else { return }
            lastObservedScrollRevision = position.revision
            scrollPosition?.wrappedValue = position
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                if url.isFileURL,
                   url.fragment != nil,
                   let currentURL = webView.url,
                   currentURL.isFileURL,
                   url.standardizedFileURL.path == currentURL.standardizedFileURL.path {
                    decisionHandler(.allow)
                    return
                }
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL,
               let directory = MarkdownPreviewResources.directoryURL?.standardizedFileURL.path,
               url.standardizedFileURL.path.hasPrefix(directory + "/") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        private func apply(_ payload: Payload, in webView: WKWebView) {
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "return window.LithePreview.update(payload)",
                    arguments: ["payload": payload.javaScriptValue],
                    in: nil,
                    contentWorld: .page
                )
            }
        }

        private func apply(_ position: MarkdownScrollPosition, in webView: WKWebView) {
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "return window.LithePreview.setScrollRatio(ratio)",
                    arguments: ["ratio": position.ratio],
                    in: nil,
                    contentWorld: .page
                )
            }
        }
    }
}
