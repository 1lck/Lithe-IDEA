import LitheModuleAPI
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

    private struct ScrollbarFrame {
        let info: WKFrameInfo
        /// Names the document that reported, to tell it from a later one in the same frame.
        let token: String
    }

    var canZoomIn: Bool { HTMLPreviewZoom.zoomedIn(from: zoomFactor) != nil }
    var canZoomOut: Bool { HTMLPreviewZoom.zoomedOut(from: zoomFactor) != nil }

    /// A plain container rather than the web view itself: WebKit docks the Web
    /// Inspector by adding a sibling next to the inspected view, so the web
    /// view must not be the root that SwiftUI sizes.
    let containerView = NSView()
    let webView: WKWebView
    /// Find in page, opened with ⌘F while the page has focus.
    let find: HTMLPreviewFindModel
    /// The camera and microphone the page is capturing from.
    let capture: HTMLPreviewCaptureModel
    /// Shared with the delegate extensions that live in their own files.
    let dialogs: any HTMLPreviewDialogPresenting
    /// The app's Info.plist entries, read when a page asks for the camera or microphone.
    let mediaUsageDescriptions: () -> [String: Any]?

    private let schemeHandler: HTMLPreviewSchemeHandler
    private var scope: HTMLPreviewScope?
    private var lastPayload: Payload?
    private var scrollRestoration: (x: Double, y: Double)?
    private var loadCount = 0
    private var processTerminations = 0
    /// Frames inside the page whose scroll bars follow the zoom.
    private var scrollbarFrames: [ScrollbarFrame] = []
    private static let maximumTrackedFrames = 128
    private static let maximumProcessRecoveries = 2
    private var cancellables = Set<AnyCancellable>()

    /// `configure` adjusts the web view's configuration last; tests use it to give the
    /// page mock cameras and microphones, which the app never does.
    init(
        dialogs: (any HTMLPreviewDialogPresenting)? = nil,
        mediaUsageDescriptions: @escaping () -> [String: Any]? = { Bundle.main.infoDictionary },
        configure: (WKWebViewConfiguration) -> Void = { _ in }
    ) {
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
        // The camera and microphone are asked for in the preview's own dialog and
        // shown in its address bar; screen sharing has neither, so pages are not offered it.
        if configuration.preferences.responds(to: NSSelectorFromString("_setScreenCaptureEnabled:")) {
            configuration.preferences.setValue(false, forKey: "screenCaptureEnabled")
        }
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences
        configure(configuration)

        schemeHandler = handler
        self.dialogs = dialogs ?? HTMLPreviewAppKitDialogs()
        self.mediaUsageDescriptions = mediaUsageDescriptions
        let surface = HTMLPreviewWebViewSurface(frame: .zero, configuration: configuration)
        webView = surface
        find = HTMLPreviewFindModel(webView: surface)
        capture = HTMLPreviewCaptureModel(webView: surface)
        super.init()

        surface.onZoomCommand = { [weak self] command in
            switch command {
            case .zoomIn: self?.zoomIn()
            case .zoomOut: self?.zoomOut()
            case .reset: self?.resetZoom()
            }
        }
        surface.onFindCommand = { [weak self] command in self?.find.handle(command) }
        surface.onPrintCommand = { [weak self] command in self?.handlePrintCommand(command) }
        surface.onContextMenu = { [weak self] menu, event in self?.customizeContextMenu(menu, for: event) }
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
        webView.configuration.userContentController.add(
            HTMLPreviewScrollbarFrameReceiver(self),
            contentWorld: HTMLPreviewScrollbars.contentWorld,
            name: HTMLPreviewScrollbars.frameReportName
        )
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
            if webView.isLoading {
                // `reload` acts on the page already on screen, which can be the
                // previous document while this one is still loading; start the
                // load again instead. Not `load(_:)`: a reload in flight keeps
                // the scroll position it installed.
                webView.load(URLRequest(url: documentPage))
            } else {
                reloadKeepingScrollPosition(fromOrigin: false)
            }
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
            loadError = L10n.string("This address cannot be opened here.")
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
        // on screen, its frames and the pages loaded next all need the new size.
        installUserScripts()
        let update = HTMLPreviewScrollbars.updateScript(zoom: factor)
        webView.evaluateJavaScript(update, in: nil, in: HTMLPreviewScrollbars.contentWorld, completionHandler: nil)
        for frame in scrollbarFrames {
            webView.evaluateJavaScript(update, in: frame.info, in: HTMLPreviewScrollbars.contentWorld) { [weak self] result in
                // A frame that is gone, or shows another document now (which
                // reported itself), is forgotten.
                if case let .success(token) = result, token as? String == frame.token { return }
                self?.scrollbarFrames.removeAll { $0.info === frame.info }
            }
        }
    }

    func trackScrollbarFrame(_ info: WKFrameInfo, token: String) {
        guard !info.isMainFrame else { return }
        scrollbarFrames.append(ScrollbarFrame(info: info, token: token))
        if scrollbarFrames.count > Self.maximumTrackedFrames { scrollbarFrames.removeFirst() }
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
    func sourceLabel(for url: URL?) -> String {
        guard let url else { return L10n.string("This page") }
        if HTMLPreviewURL.isInternal(url) {
            return scope.flatMap { HTMLPreviewURL.fileURL(for: url, in: $0) }?.lastPathComponent
                ?? L10n.string("This page")
        }
        return url.host ?? url.absoluteString
    }

    func report(_ error: Error) {
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
                    try HTMLPreviewFileSaver.save(file, bufferText: bufferText, to: destination)
                } catch {
                    DispatchQueue.main.async { self?.loadError = error.localizedDescription }
                }
            }
        }
    }

    /// Repeats a navigation that was cancelled to add the slash a web server's
    /// redirect would have added. A frame inside the page is pointed at the new
    /// address by a script, the only way to navigate it without its own web view.
    private func follow(_ url: URL, in frame: WKFrameInfo?) {
        guard let frame, !frame.isMainFrame else { return load(url) }
        webView.evaluateJavaScript(
            "location.replace(\(HTMLPreviewScript.literal(url.absoluteString)));",
            in: frame,
            in: HTMLPreviewScrollbars.contentWorld,
            completionHandler: nil
        )
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
        if !navigationAction.shouldPerformDownload, let scope,
           let redirected = HTMLPreviewURL.folderRedirect(for: url, in: scope) {
            decisionHandler(.cancel)
            follow(redirected, in: navigationAction.targetFrame)
            return
        }
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
        let canShow = navigationResponse.canShowMIMEType && !isAttachment
        guard navigationResponse.isForMainFrame else {
            return decisionHandler(canShow ? .allow : .cancel)
        }
        if canShow { return decisionHandler(.allow) }
        // A link to a file the web view cannot display (an archive, a binary) is
        // a download; for the custom scheme WebKit cannot start one, so the
        // file is copied instead of the link silently doing nothing.
        if let url = navigationResponse.response.url, HTMLPreviewURL.isInternal(url) {
            decisionHandler(.cancel)
            saveInternalResource(url)
        } else {
            decisionHandler(.download)
        }
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The frames of the previous document are gone with it.
        scrollbarFrames.removeAll()
        find.pageDidChange()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        removeScrollRestoration()
        refreshDeveloperToolsState()
        processTerminations = 0
    }

    /// WebKit runs the page in its own process, which the system may end under
    /// memory pressure. The preview would stay blank until the next edit, so the
    /// page is loaded again, unless it keeps taking the process down with it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        processTerminations += 1
        guard processTerminations <= Self.maximumProcessRecoveries else { return }
        webView.reload()
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
