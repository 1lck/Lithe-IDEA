import AppKit
import Combine
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// The web view behind the HTML preview, driven like a single-tab browser.
///
/// It owns navigation history, downloads, JavaScript dialogs and the Web
/// Inspector. The previewed document is served from the editor buffer through
/// `HTMLPreviewSchemeHandler`; any other http(s) page loads normally.
@MainActor
final class HTMLPreviewBrowserController: NSObject, ObservableObject {
    struct Payload: Equatable {
        let html: String
        let documentURL: URL
        let workspaceURL: URL?
    }

    enum ExternalOpenTarget: Equatable {
        case localFile(URL)
        case remote(URL)
    }

    @Published private(set) var address = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var isDeveloperToolsAvailable = false
    @Published private(set) var isDeveloperToolsVisible = false
    /// The page zoom as a factor (1 = 100%). It stays across navigations, like a
    /// browser tab's zoom, and is reset only by the user.
    @Published private(set) var zoomFactor = HTMLPreviewZoom.defaultLevel

    var canZoomIn: Bool { HTMLPreviewZoom.zoomedIn(from: zoomFactor) != nil }
    var canZoomOut: Bool { HTMLPreviewZoom.zoomedOut(from: zoomFactor) != nil }

    /// A plain container rather than the web view itself: WebKit docks the Web
    /// Inspector by adding a sibling next to the inspected view, so the web
    /// view must not be the root that SwiftUI sizes.
    let containerView = NSView()
    let webView: WKWebView

    private let schemeHandler: HTMLPreviewSchemeHandler
    private let dialogs: any HTMLPreviewDialogPresenting
    private var scope: HTMLPreviewScope?
    private var lastPayload: Payload?
    private var scrollRestoration: (x: Double, y: Double)?
    private var loadCount = 0
    private var cancellables = Set<AnyCancellable>()

    init(dialogs: (any HTMLPreviewDialogPresenting)? = nil) {
        let handler = HTMLPreviewSchemeHandler()
        let configuration = WKWebViewConfiguration()
        // Cookies, storage and caches live only as long as the preview.
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: HTMLPreviewURL.scheme)
        // Pop-ups still work when a click triggers them; scripts cannot open them unprompted.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if configuration.preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
            configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        schemeHandler = handler
        self.dialogs = dialogs ?? HTMLPreviewAppKitDialogs()
        let surface = HTMLPreviewWebViewSurface(frame: .zero, configuration: configuration)
        webView = surface
        super.init()

        surface.onZoomCommand = { [weak self] command in
            switch command {
            case .zoomIn: self?.zoomIn()
            case .zoomOut: self?.zoomOut()
            case .reset: self?.resetZoom()
            }
        }
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.postsFrameChangedNotifications = true
        webView.frame = containerView.bounds
        webView.autoresizingMask = [.width, .height]
        containerView.addSubview(webView)
        isDeveloperToolsAvailable = inspector != nil
        installUserScripts()
        observeWebView()
    }

    // MARK: - Content

    /// Shows the document, or refreshes it after the buffer changed.
    func update(_ payload: Payload) {
        guard payload != lastPayload else { return }
        let isFirstPayload = lastPayload == nil
        lastPayload = payload

        let newScope = HTMLPreviewScope(documentURL: payload.documentURL, workspaceURL: payload.workspaceURL)
        let scopeChanged = newScope != scope
        scope = newScope
        schemeHandler.update(scope: newScope, html: payload.html)

        guard let documentPage = HTMLPreviewURL.url(forFile: newScope.documentURL, in: newScope) else { return }
        if isFirstPayload || scopeChanged {
            load(documentPage)
        } else if isShowingDocument(in: newScope) {
            // A page the user navigated to is left alone and picks up the new
            // text when they come back.
            reloadKeepingScrollPosition(fromOrigin: false)
        }
    }

    private func isShowingDocument(in scope: HTMLPreviewScope) -> Bool {
        guard let url = webView.url, let file = HTMLPreviewURL.fileURL(for: url, in: scope) else { return false }
        return file == scope.documentURL
    }

    // MARK: - Browser actions

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stopLoading() { webView.stopLoading() }

    func reload(fromOrigin: Bool = false) {
        clearLoadError()
        reloadKeepingScrollPosition(fromOrigin: fromOrigin)
    }

    /// WebKit restores the scroll position of a reload from its history item,
    /// which it refreshes lazily: scrolling and then editing within about a
    /// second reloads at the top. The position is read from the live page and
    /// put back when the new document is ready, before the first paint.
    private func reloadKeepingScrollPosition(fromOrigin: Bool) {
        let reload = { [weak self] in
            guard let self else { return }
            if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
        }
        // While a load is running the page is not at the position to keep, and
        // the script installed by the earlier reload already holds it.
        guard !webView.isLoading, webView.url != nil else { return reload() }
        let requestedAt = loadCount
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] result, _ in
            // An address typed meanwhile has replaced the page this reload was for.
            guard let self, loadCount == requestedAt else { return }
            if let values = result as? [Double], values.count == 2, values.allSatisfy(\.isFinite) {
                installScrollRestoration(x: values[0], y: values[1])
            }
            reload()
        }
    }

    private func installScrollRestoration(x: Double, y: Double) {
        scrollRestoration = (x, y)
        installUserScripts()
    }

    private func removeScrollRestoration() {
        guard scrollRestoration != nil else { return }
        scrollRestoration = nil
        installUserScripts()
    }

    /// WKUserContentController can only remove every script at once, so the
    /// preview's whole set is rebuilt from its state: the scroll bar style, and
    /// while a reload is pending, the scripts that put the scroll position back.
    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(HTMLPreviewScrollbars.userScript(zoom: zoomFactor))
        guard let (x, y) = scrollRestoration else { return }
        // WebKit would otherwise restore its own, possibly stale, position after
        // the load finishes and override this one.
        controller.addUserScript(WKUserScript(
            source: "history.scrollRestoration = 'manual';",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: "window.scrollTo(\(x), \(y));",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
    }

    /// Loads the text typed into the address bar. Returns false when it cannot be interpreted.
    @discardableResult
    func navigate(toAddress text: String) -> Bool {
        guard let scope, let url = HTMLPreviewAddress.resolve(text, in: scope) else {
            loadError = String(localized: "This address cannot be opened here.")
            return false
        }
        load(url)
        return true
    }

    /// What "open in the system browser" should open for the page being shown.
    var externalOpenTarget: ExternalOpenTarget? {
        guard let url = webView.url else { return nil }
        if HTMLPreviewURL.isInternal(url) {
            guard let scope, let file = HTMLPreviewURL.fileURL(for: url, in: scope),
                  ["html", "htm"].contains(file.pathExtension.lowercased()) else { return nil }
            return .localFile(file)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return .remote(url)
    }

    func openInSystemBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: - Zoom

    func zoomIn() {
        if let factor = HTMLPreviewZoom.zoomedIn(from: zoomFactor) { setZoom(factor) }
    }

    func zoomOut() {
        if let factor = HTMLPreviewZoom.zoomedOut(from: zoomFactor) { setZoom(factor) }
    }

    /// Back to 100%, also undoing a pinch, which scales the page separately from the zoom.
    func resetZoom() {
        setZoom(HTMLPreviewZoom.defaultLevel)
        if webView.magnification != 1 {
            webView.setMagnification(1, centeredAt: CGPoint(x: webView.bounds.midX, y: webView.bounds.midY))
        }
    }

    private func setZoom(_ factor: Double) {
        webView.pageZoom = factor
        guard factor != zoomFactor else { return }
        zoomFactor = factor
        // Scroll bars are sized in CSS pixels, which the zoom scales; the page
        // on screen and the ones loaded next both need the new size.
        installUserScripts()
        webView.evaluateJavaScript(
            HTMLPreviewScrollbars.source(zoom: factor),
            in: nil,
            in: HTMLPreviewScrollbars.contentWorld,
            completionHandler: nil
        )
    }

    private func load(_ url: URL) {
        clearLoadError()
        removeScrollRestoration()
        loadCount += 1
        webView.load(URLRequest(url: url))
    }

    /// Assigns only when something changes: this runs from SwiftUI's
    /// `updateNSView`, where publishing an unchanged value still warns.
    private func clearLoadError() {
        if loadError != nil { loadError = nil }
    }

    // MARK: - Developer tools

    /// WebKit exposes the inspector only through `_WKInspector`, an SPI; every
    /// call is guarded by `responds(to:)` so a future macOS disables the button
    /// instead of crashing.
    private var inspector: NSObject? {
        guard webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")),
              inspector.responds(to: NSSelectorFromString("close")) else { return nil }
        return inspector
    }

    func toggleDeveloperTools() {
        guard let inspector else { return }
        let action = isInspectorVisible(inspector) ? "close" : "show"
        _ = inspector.perform(NSSelectorFromString(action))
        refreshDeveloperToolsState()
    }

    private func isInspectorVisible(_ inspector: NSObject) -> Bool {
        guard inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return (inspector.value(forKey: "isVisible") as? Bool) ?? false
    }

    private func refreshDeveloperToolsState() {
        let visible = inspector.map(isInspectorVisible) ?? false
        if visible != isDeveloperToolsVisible { isDeveloperToolsVisible = visible }
    }

    // MARK: - Observation

    private func observeWebView() {
        webView.publisher(for: \.canGoBack).removeDuplicates()
            .receive(on: DispatchQueue.main).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).removeDuplicates()
            .receive(on: DispatchQueue.main).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).removeDuplicates()
            .receive(on: DispatchQueue.main).assign(to: &$isLoading)
        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self else { return }
                address = HTMLPreviewAddress.display(for: url, in: scope)
            }
            .store(in: &cancellables)
        // Docking or closing the inspector resizes the inspected view, which is
        // also how a close button inside the inspector becomes visible here.
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: webView)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDeveloperToolsState() }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    /// How a dialog names the page that raised it.
    private func sourceLabel(for url: URL?) -> String {
        guard let url else { return String(localized: "This page") }
        if HTMLPreviewURL.isInternal(url) {
            return scope.flatMap { HTMLPreviewURL.fileURL(for: url, in: $0) }?.lastPathComponent
                ?? String(localized: "This page")
        }
        return url.host ?? url.absoluteString
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancelled loads and policy-interrupted frames are not failures the user caused.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        loadError = error.localizedDescription
    }

    /// WebKit cannot download from a custom scheme, so the file is copied directly.
    private func saveInternalResource(_ url: URL) {
        guard let scope, let file = HTMLPreviewURL.fileURL(for: url, in: scope),
              !HTMLPreviewAccessPolicy.isDenied(file, in: scope) else { return }
        let bufferText = file == scope.documentURL ? lastPayload?.html : nil
        dialogs.chooseDownloadDestination(suggestedFilename: file.lastPathComponent, in: webView.window) { [weak self] destination in
            guard let destination else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    if let bufferText {
                        try Data(bufferText.utf8).write(to: destination, options: .atomic)
                    } else {
                        try FileManager.default.copyItem(at: file, to: destination)
                    }
                } catch {
                    DispatchQueue.main.async { self?.loadError = error.localizedDescription }
                }
            }
        }
    }

    private func apply(_ decision: HTMLPreviewNavigationDecision) {
        switch decision {
        case let .loadInPlace(url): load(url)
        case let .openExternally(url): NSWorkspace.shared.open(url)
        case .allow, .cancel, .download: break
        }
    }
}

// MARK: - Navigation

extension HTMLPreviewBrowserController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        let target: HTMLPreviewNavigationRequest.Target
        if let frame = navigationAction.targetFrame {
            target = frame.isMainFrame ? .mainFrame : .subframe
        } else {
            target = .newWindow
        }
        let decision = HTMLPreviewNavigationPolicy.decide(HTMLPreviewNavigationRequest(
            url: url,
            type: navigationAction.navigationType,
            target: target,
            shouldDownload: navigationAction.shouldPerformDownload
        ))
        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .download where HTMLPreviewURL.isInternal(url):
            decisionHandler(.cancel)
            saveInternalResource(url)
        case .download:
            decisionHandler(.download)
        case .cancel, .loadInPlace, .openExternally:
            decisionHandler(.cancel)
            apply(decision)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let isAttachment = disposition.hasPrefix("attachment")
        guard navigationResponse.isForMainFrame else {
            return decisionHandler(navigationResponse.canShowMIMEType && !isAttachment ? .allow : .cancel)
        }
        decisionHandler(navigationResponse.canShowMIMEType && !isAttachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        clearLoadError()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        removeScrollRestoration()
        refreshDeveloperToolsState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        removeScrollRestoration()
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        removeScrollRestoration()
        report(error)
    }
}

// MARK: - Downloads

extension HTMLPreviewBrowserController: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        dialogs.chooseDownloadDestination(suggestedFilename: suggestedFilename, in: webView.window) { destination in
            // A destination that already exists must be replaced explicitly; WebKit refuses to overwrite.
            if let destination, FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            completionHandler(destination)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        report(error)
    }
}

// MARK: - Page dialogs, pop-ups and file inputs

extension HTMLPreviewBrowserController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        dialogs.presentAlert(
            message: message,
            source: sourceLabel(for: frame.request.url),
            in: webView.window,
            completion: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        dialogs.presentConfirm(
            message: message,
            source: sourceLabel(for: frame.request.url),
            in: webView.window,
            completion: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        dialogs.presentPrompt(
            message: prompt,
            defaultText: defaultText,
            source: sourceLabel(for: frame.request.url),
            in: webView.window,
            completion: completionHandler
        )
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        dialogs.chooseFiles(
            allowsMultiple: parameters.allowsMultipleSelection,
            allowsDirectories: parameters.allowsDirectories,
            in: webView.window,
            completion: completionHandler
        )
    }

    /// `window.open` and `target="_blank"`. The preview is one tab, so the
    /// request is answered by this view's own navigation instead of a new web view.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            apply(HTMLPreviewNavigationPolicy.decide(HTMLPreviewNavigationRequest(
                url: url,
                type: navigationAction.navigationType,
                target: .newWindow,
                shouldDownload: false
            )))
        }
        return nil
    }
}
