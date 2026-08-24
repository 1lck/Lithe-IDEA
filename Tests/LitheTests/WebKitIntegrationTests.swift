import AppKit
import WebKit
@testable import Lithe
import Testing

@Suite("WebKit lifecycle integration", .serialized)
@MainActor
struct WebKitIntegrationTests {
    @Test
    func linuxDoWebViewSurvivesResumeThenReleasesAfterInactivity() async {
        _ = NSApplication.shared

        let configuration = WKWebViewConfiguration()
        // The session lifecycle does not depend on persistent website data.
        // An ephemeral store avoids sharing cookie and cache state across CI runs.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let delegate = TestWebViewDelegate()
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate

        let session = LinuxDoAnonymousWebSession(
            idleLifetimeNanoseconds: 20_000_000
        )
        session.webView = webView

        defer {
            session.resume()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            session.webView = nil
        }

        let cancelledRelease = session.releaseAfterInactivity()
        session.resume()
        await cancelledRelease.value

        #expect(session.webView === webView)
        #expect(webView.navigationDelegate === delegate)
        #expect(webView.uiDelegate === delegate)

        let completedRelease = session.releaseAfterInactivity()
        await completedRelease.value

        #expect(session.webView == nil)
        #expect(webView.navigationDelegate == nil)
        #expect(webView.uiDelegate == nil)
    }
}

@MainActor
private final class TestWebViewDelegate:
    NSObject,
    @MainActor WKNavigationDelegate,
    @MainActor WKUIDelegate
{}
