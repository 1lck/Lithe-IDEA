import WebKit
@testable import Lithe
import Testing

@MainActor
struct LinuxDoAnonymousWebSessionTests {
    @Test
    func shortPanelAbsenceKeepsTheCurrentWebView() async throws {
        let session = LinuxDoAnonymousWebSession(idleLifetimeNanoseconds: 50_000_000)
        let webView = WKWebView()
        session.webView = webView

        session.releaseAfterInactivity()
        session.resume()
        try await Task.sleep(nanoseconds: 80_000_000)

        #expect(session.webView === webView)
    }

    @Test
    func inactiveSessionReleasesItsWebView() async throws {
        let session = LinuxDoAnonymousWebSession(idleLifetimeNanoseconds: 20_000_000)
        session.webView = WKWebView()

        session.releaseAfterInactivity()
        let deadline = ContinuousClock.now + .seconds(1)
        while session.webView != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(session.webView == nil)
    }
}
