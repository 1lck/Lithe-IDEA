import Foundation
import Testing
import WebKit
@testable import Lithe

/// Project HTML shown in the embedded preview must not reach the plugin
/// bridge: the plugin message handler and the plugin page scheme exist only
/// on plugin web pages. Evidence for the Agent Note on plugin host services.
@MainActor
struct HTMLPreviewBridgeIsolationTests {
    /// The handlers a page script could post to, by the names the app uses
    /// for the plugin bridge, the editor and the preview's own scroll bars.
    private static let probe = """
        const handlers = window.webkit && window.webkit.messageHandlers;
        return ['\(MacPluginWebPage.messageHandlerName)', 'litheEditor', '\(HTMLPreviewScrollbars.frameReportName)']
            .map(name => typeof (handlers && handlers[name])).join(',');
        """

    @Test func projectPagesSeeNoPluginBridgeOrEditorHandler() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        harness.show("<title>ready</title><p>project page</p>")
        #expect(await harness.waitForTitle("ready"), "Title was \(harness.webView.title ?? "nil")")

        // The page's own world, where project scripts run, sees no handler at all.
        let pageWorld = try await harness.evaluateAsync(Self.probe)
        #expect(pageWorld as? String == "undefined,undefined,undefined")

        // Control: the probe does see a handler that exists. The preview's own
        // scroll bar reporter lives in the app's world, never in the page's.
        let appWorld = try await harness.webView.callAsyncJavaScript(
            Self.probe, arguments: [:], contentWorld: HTMLPreviewScrollbars.contentWorld
        )
        #expect(appWorld as? String == "undefined,undefined,object")
    }

    @Test func previewConfigurationHasNoPluginPageScheme() throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        let configuration = harness.webView.configuration
        #expect(configuration.urlSchemeHandler(forURLScheme: MacPluginWebContent.scheme) == nil)
        #expect(configuration.urlSchemeHandler(forURLScheme: HTMLPreviewURL.scheme) != nil)
    }
}
