import AppKit
import Foundation
import Testing
import WebKit
@testable import Lithe

@MainActor
struct MarkdownPreviewHTMLTests {
    @Test(arguments: ["light", "dark"])
    func htmlBadgesUseInlineFlowAndPreserveAlignment(appearance: String) async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: root.appendingPathComponent("shared/fixtures/editor/markdown-html-v1.json"))
        )
        let html = try RustCoreBridge().markdownRender(fixture.source).get().html
        let workspace = try HTMLPreviewFixture(files: [
            "badge.svg": "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='20'><rect width='80' height='20' fill='green'/></svg>"
        ])
        let coordinator = MarkdownPreviewWebView.Coordinator(scrollPosition: nil)
        let documentURL = workspace.url("README.md")
        coordinator.assetHandler.update(documentURL: documentURL, workspaceURL: workspace.workspace)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.assetHandler, forURLScheme: MarkdownPreviewAssetResolver.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = WebMediaCaptureDenier.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFront(nil)
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            window.contentView = nil
            window.close()
        }

        coordinator.loadTemplate(in: webView)
        let loaded = await waitForChanges(webViewChanges(webView), timeout: .seconds(5)) {
            !webView.isLoading && webView.title == "Markdown Preview"
        }
        try #require(loaded, "The production Markdown preview template did not load")

        let payload = MarkdownPreviewWebView.Payload(
            html: html, documentURL: documentURL, workspaceURL: workspace.workspace, appearance: appearance
        )
        let finished = TestGate()
        var result: Result<Any, Error>?
        webView.callAsyncJavaScript(
            """
            await window.LithePreview.update(payload);
            const content = document.getElementById('content');
            const badges = document.getElementById('badges');
            const images = Array.from(badges.querySelectorAll('img'));
            const rects = images.map(image => image.getBoundingClientRect());
            const paragraph = badges.getBoundingClientRect();
            const image = images[2];
            image.click();
            const zoomOpened = !document.getElementById('image-viewer').hidden;
            document.getElementById('image-close').click();
            const inline = content.querySelector('p[data-sourcepos] img');
            return {
                sameRow: rects.every(rect => Math.abs(rect.top - rects[0].top) < 1),
                centered: Math.abs((rects[0].left + rects[2].right) / 2 - (paragraph.left + paragraph.right) / 2) < 1,
                headerAlignment: getComputedStyle(document.getElementById('aligned-heading')).textAlign,
                paragraphAlignment: getComputedStyle(document.getElementById('aligned-paragraph')).textAlign,
                inlineDisplay: getComputedStyle(inline).display,
                noImageMargin: getComputedStyle(image).margin === '0px',
                explicitBreaks: document.getElementById('explicit-break').querySelectorAll('br').length,
                scopedAsset: image.getAttribute('src').startsWith('lithe-resource://document?'),
                zoomOpened,
                zoomClosed: document.getElementById('image-viewer').hidden
            };
            """,
            arguments: ["payload": payload.javaScriptValue], in: nil, in: .page
        ) {
            result = $0
            finished.open()
        }
        try #require(await finished.waitUntilOpen(timeout: .seconds(5)), "Markdown layout evaluation timed out")
        let completed = try #require(result)
        let values = try #require(try completed.get() as? [String: Any])
        for key in ["sameRow", "centered", "noImageMargin", "scopedAsset", "zoomOpened", "zoomClosed"] {
            #expect(values[key] as? Bool == true, "Expected \(key): \(values)")
        }
        #expect(values["headerAlignment"] as? String == "right")
        #expect(["left", "-webkit-left"].contains(values["paragraphAlignment"] as? String ?? ""))
        #expect(values["inlineDisplay"] as? String == "inline-block")
        #expect(values["explicitBreaks"] as? Int == 1)

        // Resize the actual WebKit viewport: wrapping must remain native, not
        // a forced no-wrap badge row that overflows narrow split previews.
        window.setContentSize(NSSize(width: 240, height: 700))
        let measured = TestGate()
        var wraps = false
        webView.evaluateJavaScript("""
            (() => {
                const images = document.querySelectorAll('#badges img');
                return images[2].getBoundingClientRect().top > images[0].getBoundingClientRect().top &&
                    document.documentElement.scrollWidth <= window.innerWidth;
            })()
            """) { value, _ in
            wraps = value as? Bool == true
            measured.open()
        }
        try #require(await measured.waitUntilOpen(timeout: .seconds(5)), "Narrow layout evaluation timed out")
        #expect(wraps)
    }

    private struct Fixture: Decodable {
        let source: String
    }
}
