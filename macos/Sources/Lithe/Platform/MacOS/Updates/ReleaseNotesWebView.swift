import AppKit
import SwiftUI
import WebKit

/// Displays Rust-sanitized release notes without granting the update sheet file or script access.
struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    let isDark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = LitheTheme.nsColor(.popupBackground, isDark: isDark)
        context.coordinator.update(document, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.underPageBackgroundColor = LitheTheme.nsColor(.popupBackground, isDark: isDark)
        context.coordinator.update(document, in: webView)
    }

    private var document: String {
        let background = cssColor(.popupBackground)
        let text = cssColor(.primaryText)
        let link = cssColor(.link)
        let muted = cssColor(.secondaryText)
        let border = cssColor(.divider)
        let colorScheme = isDark ? "dark" : "light"

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="\(colorScheme)">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
          <style>
            html { color-scheme: \(colorScheme); background: \(background); }
            body { margin: 0; background: \(background); color: \(text); font: 12.5px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
            h1, h2, h3, h4, h5, h6 { margin: 1.05em 0 0.4em; line-height: 1.3; font-weight: 650; }
            h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
            h1 { font-size: 18px; } h2 { font-size: 16px; } h3 { font-size: 14px; }
            h4, h5, h6 { font-size: 12.5px; }
            p { margin: 0 0 0.7em; }
            ul, ol { margin: 0 0 0.8em; padding-left: 1.6em; }
            li { margin: 0.2em 0; }
            li > p { margin: 0.2em 0; }
            a { color: \(link); text-decoration: underline; }
            a:hover { text-decoration-thickness: 2px; }
            blockquote { margin: 0.8em 0; padding-left: 0.8em; border-left: 2px solid \(border); color: \(muted); }
            code, pre { font-family: ui-monospace, SFMono-Regular, monospace; }
            pre { overflow-x: auto; padding: 8px; border: 1px solid \(border); border-radius: 4px; }
            img { max-width: 100%; height: auto; }
            table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; }
            th, td { border: 1px solid \(border); padding: 4px 7px; }
          </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    private func cssColor(_ token: LitheTheme.ResolvedColorToken) -> String {
        let color = LitheTheme.nsColor(token, isDark: isDark)
        return String(
            format: "rgb(%d %d %d / %.3f)",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Double(color.alphaComponent)
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastDocument: String?

        func update(_ document: String, in webView: WKWebView) {
            guard document != lastDocument else { return }
            lastDocument = document
            webView.loadHTMLString(document, baseURL: nil)
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
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
