import WebKit
@testable import Lithe
import Testing

@MainActor
struct LinuxDoAnonymousWebSessionTests {
    @Test
    func shortPanelAbsenceKeepsTheCurrentWebView() async {
        let session = LinuxDoAnonymousWebSession(idleLifetimeNanoseconds: 50_000_000)
        let webView = WKWebView()
        session.webView = webView

        let releaseTask = session.releaseAfterInactivity()
        session.resume()
        await releaseTask.value

        #expect(session.webView === webView)
    }

    @Test
    func inactiveSessionReleasesItsWebView() async {
        let session = LinuxDoAnonymousWebSession(idleLifetimeNanoseconds: 20_000_000)
        session.webView = WKWebView()

        let releaseTask = session.releaseAfterInactivity()
        await releaseTask.value

        #expect(session.webView == nil)
    }
}
