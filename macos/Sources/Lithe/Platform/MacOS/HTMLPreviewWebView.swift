import AppKit
import SwiftUI
import WebKit

/// Hosts a static HTML document in an isolated, non-persistent WebKit page.
struct HTMLPreviewWebView: NSViewRepresentable {
    struct Payload: Equatable {
        let html: String
        let documentURL: URL
    }

    let payload: Payload

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.update(payload, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(payload, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastPayload: Payload?

        func update(_ payload: Payload, in webView: WKWebView) {
            guard payload != lastPayload else { return }
            lastPayload = payload
            webView.loadHTMLString(
                payload.html,
                baseURL: payload.documentURL.deletingLastPathComponent()
            )
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

            if url.isFileURL || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
