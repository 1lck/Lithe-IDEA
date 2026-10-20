import AppKit
import Foundation
import LitheCoreContracts
import WebKit

/// `data-theme` and the `--lithe-*` variables a page styles itself with.
struct MacPluginWebTheme: Equatable {
    let isDark: Bool
    let variables: [String: String]

    init(colorTheme: AppColorTheme, isDark: Bool, codeFontFamily: String, codeFontSize: Double) {
        self.isDark = isDark
        func color(_ token: LitheTheme.ResolvedColorToken) -> String {
            MonacoWorkbenchThemeConfiguration.cssColor(LitheTheme.nsColor(token, theme: colorTheme, isDark: isDark))
        }
        variables = [
            "--lithe-background": color(.editor),
            "--lithe-surface": color(.sidebar),
            "--lithe-header": color(.toolHeader),
            "--lithe-popup-background": color(.popupBackground),
            "--lithe-foreground": color(.primaryText),
            "--lithe-secondary-foreground": color(.secondaryText),
            "--lithe-border": color(.divider),
            "--lithe-accent": color(.accent),
            "--lithe-link": color(.link),
            "--lithe-success": color(.success),
            "--lithe-warning": color(.warning),
            "--lithe-error": color(.error),
            // The bundled UI family is registered in this process only; the
            // web content process falls back to the system font.
            "--lithe-font-family": "\"Inter\", -apple-system, system-ui, sans-serif",
            "--lithe-font-size": "13px",
            "--lithe-code-font-family": MacEditorFontCatalog.editorFontStack(codeFontFamily),
            "--lithe-code-font-size": "\(Int(codeFontSize.rounded()))px"
        ]
    }

    var name: String { isDark ? "dark" : "light" }

    var payload: ToolingJSONValue {
        .object(["theme": .string(name), "variables": .object(variables.mapValues(ToolingJSONValue.string))])
    }
}

/// One plugin page in its own web view: a private data store, the package
/// scheme, and `window.lithe` defined before the page's scripts run.
@MainActor
final class MacPluginWebPage: NSObject, PluginWebPageHandle, WKNavigationDelegate, WKUIDelegate {
    static let messageHandlerName = "lithe"

    let window: PluginWebWindow
    let bridge: PluginWebBridge
    private(set) var isClosed = false
    private var theme: MacPluginWebTheme
    private var view: WKWebView?
    private var reloadCount = 0

    init(window: PluginWebWindow, host: any PluginWebBridgeHost, stateStore: any PluginWebStateStoring, theme: MacPluginWebTheme) {
        self.window = window
        self.theme = theme
        bridge = PluginWebBridge(window: window, host: host, stateStore: stateStore)
        super.init()
        bridge.emit = { [weak self] event, payload in self?.dispatch(event, payload) }
    }

    /// The web view, loaded on first use.
    var webView: WKWebView? {
        if isClosed { return nil }
        if let view { return view }
        guard let entryURL = MacPluginWebContent.url(pluginID: window.pluginID, path: window.entry) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            MacPluginWebSchemeHandler(pluginID: window.pluginID, packageURL: window.packageURL),
            forURLScheme: MacPluginWebContent.scheme
        )
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.addScriptMessageHandler(
            MacPluginWebMessages(self), contentWorld: .page, name: Self.messageHandlerName
        )
        configuration.userContentController.addUserScript(userScript())
        let view = WKWebView(frame: .zero, configuration: configuration)
        // A page without its own background shows the workbench's.
        view.setValue(false, forKey: "drawsBackground")
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        view.allowsMagnification = false
        if #available(macOS 13.3, *) { view.isInspectable = window.isInspectable }
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setAccessibilityIdentifier("plugin-web-" + window.windowID)
        self.view = view
        view.load(URLRequest(url: entryURL))
        return view
    }

    func update(theme: MacPluginWebTheme) {
        guard theme != self.theme, !isClosed else { return }
        self.theme = theme
        guard let view else { return }
        // Later loads of the page start with the new theme as well.
        view.configuration.userContentController.removeAllUserScripts()
        view.configuration.userContentController.addUserScript(userScript())
        dispatch("ui.themeChanged", theme.payload)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        bridge.close()
        guard let view else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.configuration.userContentController.removeAllUserScripts()
        view.removeFromSuperview()
        self.view = nil
    }

    // MARK: Messages

    fileprivate func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard !isClosed, message.webView === view, message.frameInfo.isMainFrame,
              origin.protocol == MacPluginWebContent.scheme, origin.host == window.pluginID, origin.port == 0,
              let body = message.body as? String else {
            reply(nil, "plugin.web.forbidden")
            return
        }
        let bridge = bridge
        Task { @MainActor in
            reply(await bridge.handle(body), nil)
        }
    }

    private func dispatch(_ event: String, _ payload: ToolingJSONValue) {
        guard !isClosed, let view, let data = try? JSONEncoder().encode(payload) else { return }
        view.callAsyncJavaScript(
            "window.__litheBridgeDispatch(event, payload)",
            arguments: ["event": event, "payload": String(decoding: data, as: UTF8.self)],
            in: nil, in: .page, completionHandler: nil
        )
    }

    private func userScript() -> WKUserScript {
        let context: ToolingJSONValue = .object([
            "pluginID": .string(window.pluginID),
            "windowID": .string(window.windowID),
            "platform": .string("macos"),
            "locale": .string(Bundle.main.preferredLocalizations.first ?? "en")
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let contextJSON = (try? encoder.encode(context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let themeJSON = (try? encoder.encode(theme.payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let source = Self.bridgeScript
            .replacingOccurrences(of: "__LITHE_CONTEXT__", with: contextJSON)
            .replacingOccurrences(of: "__LITHE_THEME__", with: themeJSON)
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// Bridge version 1. The handler reference is taken before any page
    /// script runs, and `window.lithe` cannot be replaced or extended.
    private static let bridgeScript = #"""
    (() => {
      'use strict';
      const handler = window.webkit.messageHandlers.lithe;
      const post = handler.postMessage.bind(handler);
      const parse = JSON.parse, stringify = JSON.stringify, freeze = Object.freeze;
      const initial = __LITHE_CONTEXT__;
      let theme = __LITHE_THEME__;
      const listeners = new Map();
      const failure = (code, message, pluginErrorCode) =>
        freeze(typeof pluginErrorCode === 'string' ? { code, message, pluginErrorCode } : { code, message });
      const applyTheme = () => {
        const root = document.documentElement;
        if (!root) { document.addEventListener('readystatechange', applyTheme, { once: true }); return; }
        root.setAttribute('data-theme', theme.theme);
        for (const [name, value] of Object.entries(theme.variables)) root.style.setProperty(name, value);
      };
      const notify = (event, payload) => {
        for (const listener of [...(listeners.get(event) || [])]) {
          try { listener(parse(stringify(payload))); } catch (error) { setTimeout(() => { throw error; }); }
        }
      };
      const lithe = freeze({
        version: 1,
        context: freeze({
          pluginID: initial.pluginID, windowID: initial.windowID, platform: initial.platform, locale: initial.locale,
          get theme() { return theme.theme; }
        }),
        request(method, params) {
          let message;
          try {
            message = stringify({ method: String(method), params: params === undefined ? null : params });
          } catch (error) {
            return Promise.reject(failure('plugin.web.invalidRequest', 'The parameters are not JSON.'));
          }
          return post(message).then((reply) => {
            const result = parse(reply);
            if (result.error) throw failure(result.error.code, result.error.message, result.error.pluginErrorCode);
            return result.ok;
          }, (error) => { throw failure('plugin.web.forbidden', String(error && error.message || error)); });
        },
        on(event, listener) {
          if (typeof listener !== 'function') throw new TypeError('listener must be a function');
          const name = String(event);
          if (!listeners.has(name)) listeners.set(name, new Set());
          listeners.get(name).add(listener);
          return () => { listeners.get(name)?.delete(listener); };
        }
      });
      Object.defineProperty(window, 'lithe', { value: lithe, enumerable: true });
      Object.defineProperty(window, '__litheBridgeDispatch', {
        value: (event, payload) => {
          const value = parse(payload);
          if (event === 'ui.themeChanged') {
            theme = value;
            applyTheme();
            notify(event, { theme: value.theme });
          } else {
            notify(event, value);
          }
        }
      });
      applyTheme();
    })();
    """#

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let isOwnPage = !isClosed && url?.scheme == MacPluginWebContent.scheme && url?.host == window.pluginID
            && url?.port == nil && url?.user == nil && url?.password == nil
        decisionHandler(isOwnPage && navigationAction.targetFrame?.isMainFrame == true
            && !navigationAction.shouldPerformDownload ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // A file WebKit cannot show would become a download. Recheck the
        // response origin too, so future redirect handling cannot widen it.
        let url = navigationResponse.response.url
        let isOwnPage = !isClosed && url?.scheme == MacPluginWebContent.scheme && url?.host == window.pluginID
            && url?.port == nil && url?.user == nil && url?.password == nil
        decisionHandler(isOwnPage && navigationResponse.canShowMIMEType && navigationResponse.isForMainFrame ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A page restores itself from its stored state; stop after repeated crashes.
        guard !isClosed, reloadCount < 3 else { return }
        reloadCount += 1
        webView.reload()
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

/// Weak, so the content controller does not keep a closed page alive.
private final class MacPluginWebMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: MacPluginWebPage?
    init(_ page: MacPluginWebPage) { self.page = page }

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let page else { replyHandler(nil, "plugin.web.forbidden"); return }
        page.receive(message, reply: replyHandler)
    }
}
