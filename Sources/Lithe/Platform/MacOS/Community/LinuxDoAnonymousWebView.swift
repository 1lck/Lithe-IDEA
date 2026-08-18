import AppKit
import SwiftUI
import WebKit

enum LinuxDoWebNavigationAction: Equatable {
    case none
    case home(UUID)
    case back(UUID)
    case forward(UUID)
    case reload(UUID)
}

/// Retains one guest browsing surface across short panel presentations and
/// releases it after a bounded idle period. Site cookies live in WebKit's data
/// store and outlast this in-memory view cache.
@MainActor
final class LinuxDoAnonymousWebSession: ObservableObject {
    var webView: WKWebView?
    private var releaseTask: Task<Void, Never>?
    private let idleLifetimeNanoseconds: UInt64

    init(idleLifetimeNanoseconds: UInt64 = 10 * 60 * 1_000_000_000) {
        self.idleLifetimeNanoseconds = idleLifetimeNanoseconds
    }

    func resume() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    @discardableResult
    func releaseAfterInactivity() -> Task<Void, Never> {
        releaseTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: idleLifetimeNanoseconds)
            guard !Task.isCancelled else { return }
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView = nil
            releaseTask = nil
        }
        releaseTask = task
        return task
    }

    deinit {
        releaseTask?.cancel()
    }

}

/// Hosts the public LINUX DO website in a read-only WebKit session.
/// Authentication and write-oriented routes are intentionally blocked. WebKit
/// storage remains available so Cloudflare can retain its device-verification
/// cookie instead of challenging every panel presentation.
struct LinuxDoAnonymousWebView: NSViewRepresentable {
    let session: LinuxDoAnonymousWebSession
    @Binding var title: String
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let navigationAction: LinuxDoWebNavigationAction

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = session.webView {
            webView.navigationDelegate = context.coordinator
            webView.uiDelegate = context.coordinator
            context.coordinator.webView = webView
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.compactReadOnlyStyle,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        context.coordinator.webView = webView
        session.webView = webView
        webView.load(URLRequest(url: Self.latestURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.perform(navigationAction, in: webView)
    }

    static let latestURL = URL(string: "https://linux.do/latest")!

    private static let compactReadOnlyStyle = #"""
        (() => {
          const style = document.createElement('style');
          style.id = 'lithe-linux-do-read-only';
          style.textContent = `
            .d-header,
            .sidebar-wrapper,
            .header-sidebar-toggle,
            .topic-list .posters,
            .topic-list .posts,
            .topic-list .views,
            .topic-list .activity,
            .topic-list .num,
            .topic-list .bulk-select,
            .topic-list-header,
            .topic-navigation,
            .topic-map,
            .timeline-container,
            .post-menu-area,
            .create-topic,
            .reply-to-post,
            .topic-footer-main-buttons,
            .login-button,
            .sign-up-button,
            .chat-drawer-container,
            .powered-by-discourse { display: none !important; }

            html, body { background: #17181c !important; }
            #main-outlet-wrapper { grid-template-columns: minmax(0, 1fr) !important; }
            #main-outlet {
              width: auto !important;
              max-width: none !important;
              margin: 0 !important;
              padding: 10px 12px 24px !important;
            }
            .topic-list { font-size: 13px !important; }
            .topic-list .main-link { padding: 10px 4px !important; }
            .topic-list .link-top-line { line-height: 1.35 !important; }
            .topic-list .topic-excerpt { font-size: 12px !important; line-height: 1.45 !important; }
            .topic-post { margin: 0 0 10px !important; }
            .topic-body { width: auto !important; float: none !important; }
            .cooked { font-size: 14px !important; line-height: 1.62 !important; }
            img, video { max-width: 100% !important; height: auto !important; }
          `;
          document.getElementById(style.id)?.remove();
          document.head.appendChild(style);
        })();
        """#

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LinuxDoAnonymousWebView
        weak var webView: WKWebView?
        private var handledAction: LinuxDoWebNavigationAction = .none

        init(parent: LinuxDoAnonymousWebView) {
            self.parent = parent
        }

        func perform(_ action: LinuxDoWebNavigationAction, in webView: WKWebView) {
            guard action != handledAction else { return }
            handledAction = action
            switch action {
            case .none:
                break
            case .home:
                webView.load(URLRequest(url: LinuxDoAnonymousWebView.latestURL))
            case .back:
                if webView.canGoBack { webView.goBack() }
            case .forward:
                if webView.canGoForward { webView.goForward() }
            case .reload:
                webView.reload()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.errorMessage = nil
            publishNavigationState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "LINUX DO"
            publishNavigationState(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            publishFailure(error, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            publishFailure(error, in: webView)
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
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            guard url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "linux.do" else {
                if navigationAction.navigationType == .linkActivated {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            if Self.isAuthenticationOrWriteRoute(url.path) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url,
               url.host?.lowercased() == "linux.do",
               !Self.isAuthenticationOrWriteRoute(url.path) {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func publishFailure(_ error: any Error, in webView: WKWebView) {
            parent.isLoading = false
            if (error as NSError).code != NSURLErrorCancelled {
                parent.errorMessage = error.localizedDescription
            }
            publishNavigationState(webView)
        }

        private func publishNavigationState(_ webView: WKWebView) {
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
        }

        private static func isAuthenticationOrWriteRoute(_ path: String) -> Bool {
            let normalized = path.lowercased()
            return normalized == "/login"
                || normalized == "/signup"
                || normalized.hasPrefix("/session")
                || normalized.hasPrefix("/user-api-key")
                || normalized.hasPrefix("/new-topic")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
