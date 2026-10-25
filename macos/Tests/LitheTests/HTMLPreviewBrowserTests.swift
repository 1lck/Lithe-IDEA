import AppKit
import Combine
import Foundation
import Testing
import WebKit
@testable import Lithe

@MainActor
struct HTMLPreviewBrowserTests {
    @Test func modulePagesFetchAndImportRootRelativeResources() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "<p>disk</p>",
            "assets/main.js": """
                import { name } from './dep.js';
                const info = await (await fetch('/data/info.json')).json();
                document.title = `ready:${name}:${info.id}:${location.protocol}:${window.isSecureContext}`;
                """,
            "assets/dep.js": "export const name = 'dep';",
            "data/info.json": "{\"id\": 7}"
        ])
        defer { harness.tearDown() }

        harness.show("<!doctype html><title>boot</title><script type=\"module\" src=\"/assets/main.js\"></script>")

        #expect(await harness.waitForTitle("ready:dep:7:lithe-html::true"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.controller.address == harness.fixture.url("site/page.html").absoluteString)
    }

    @Test func pagesCannotFetchHiddenFilesOrEscapeTheRoot() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            ".env": "TOKEN=secret"
        ])
        defer { harness.tearDown() }

        harness.show("""
            <script type="module">
            const codes = [];
            for (const path of ['/.env', '/../secret.txt', '/site/page.html']) {
              codes.push((await fetch(path)).status);
            }
            document.title = 'codes:' + codes.join(',');
            </script>
            """)

        #expect(await harness.waitForTitle("codes:403,404,200"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func javaScriptDialogsAreAnsweredByTheDialogPresenter() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.dialogs.confirmAnswer = true
        harness.dialogs.promptAnswer = "Ada"

        harness.show("""
            <script>
            alert('hello');
            const sure = confirm('sure?');
            const name = prompt('name?', 'guest');
            document.title = `done:${sure}:${name}`;
            </script>
            """)

        #expect(await harness.waitForTitle("done:true:Ada"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.dialogs.alerts == ["hello"])
        #expect(harness.dialogs.confirms == ["sure?"])
        #expect(harness.dialogs.prompts.map(\.message) == ["name?"])
        #expect(harness.dialogs.prompts.map(\.defaultText) == ["guest"])
        // A dialog is attributed to the file that raised it.
        #expect(harness.dialogs.sources == ["page.html"])
    }

    @Test func cancellingDialogsReachesThePage() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.dialogs.confirmAnswer = false
        harness.dialogs.promptAnswer = nil

        harness.show("<script>document.title = `${confirm('?')}:${prompt('?')}`;</script>")

        #expect(await harness.waitForTitle("false:null"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func anchorLinksScrollWithoutLeavingThePage() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        harness.show("""
            <title>anchors</title>
            <a id="go" href="#bottom">go</a>
            <div style="height: 4000px"></div>
            <h2 id="bottom">bottom</h2>
            """)
        #expect(await harness.waitForTitle("anchors"))
        _ = try await harness.evaluate("document.getElementById('go').click()")

        #expect(await harness.wait { harness.controller.address.hasSuffix("page.html#bottom") })
        let scrolled = try await harness.evaluate("window.scrollY") as? Double ?? 0
        #expect(scrolled > 1_000, "Expected the page to scroll to the anchor, scrollY was \(scrolled)")
        #expect(harness.controller.canGoBack)
    }

    @Test func linksNavigateInPlaceAndHistoryWorks() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<title>other</title><p>other page</p>"
        ])
        defer { harness.tearDown() }

        harness.show("<title>first</title><a id=\"next\" href=\"other.html\">next</a>")
        #expect(await harness.waitForTitle("first"))
        #expect(!harness.controller.canGoBack)

        _ = try await harness.evaluate("document.getElementById('next').click()")
        #expect(await harness.waitForTitle("other"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.controller.address == harness.fixture.url("site/other.html").absoluteString)
        #expect(harness.controller.canGoBack)
        #expect(!harness.controller.canGoForward)

        harness.controller.goBack()
        #expect(await harness.waitForTitle("first"))
        #expect(await harness.wait { harness.controller.canGoForward })

        harness.controller.goForward()
        #expect(await harness.waitForTitle("other"))
    }

    @Test func reloadingAfterAnEditKeepsTheScrollPosition() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        // The position is restored while the new document loads, so the edited
        // page reports it from a scroll event instead of the test guessing when.
        func page(_ title: String, reportsScroll: Bool = false) -> String {
            let report = reportsScroll
                ? "<script>addEventListener('scroll', () => { document.title = 'scrolled:' + Math.round(scrollY); });</script>"
                : ""
            return "<title>\(title)</title>\(report)<body style=\"margin:0\"><div style=\"height: 6000px\"></div></body>"
        }

        harness.show(page("v1"))
        #expect(await harness.waitForTitle("v1"))
        _ = try await harness.evaluate("window.scrollTo(0, 900)")
        #expect(try await harness.evaluate("window.scrollY") as? Double == 900)

        harness.show(page("v2", reportsScroll: true))
        #expect(
            await harness.waitForTitle("scrolled:900"),
            "A buffer edit should not reset the scroll position, title was \(harness.webView.title ?? "nil")"
        )
    }

    @Test func editsDoNotYankTheUserOffAnotherPage() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<title>other</title>"
        ])
        defer { harness.tearDown() }

        harness.show("<title>first</title>")
        #expect(await harness.waitForTitle("first"))
        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/other.html").path))
        #expect(await harness.waitForTitle("other"))

        harness.show("<title>edited</title>")
        // The edit is served the next time the document is opened.
        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/page.html").path))
        #expect(await harness.waitForTitle("edited"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func invalidAddressesAreReportedAndValidOnesLoad() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<title>first</title>")
        #expect(await harness.waitForTitle("first"))

        #expect(!harness.controller.navigate(toAddress: "not an address"))
        #expect(harness.controller.loadError != nil)
        #expect(!harness.controller.navigate(toAddress: "/etc/hosts"))

        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/page.html").path))
        #expect(harness.controller.loadError == nil)
    }

    @Test func localPagesCanBeOpenedInTheSystemBrowserAsFiles() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        harness.show("<title>first</title>")
        #expect(await harness.waitForTitle("first"))

        #expect(harness.controller.externalOpenTarget == .localFile(harness.fixture.url("site/page.html")))
    }

    @Test func zoomResizesThePageAndSurvivesNavigation() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<title>other</title>"
        ])
        defer { harness.tearDown() }
        harness.show("<title>first</title>")
        #expect(await harness.waitForTitle("first"))
        #expect(harness.controller.zoomFactor == 1)
        let unzoomedWidth = try await harness.evaluate("window.innerWidth") as? Double ?? 0
        #expect(unzoomedWidth > 0)

        // 100% -> 110% -> 125% -> 150% -> 175% -> 200%
        for _ in 0..<5 { harness.controller.zoomIn() }
        #expect(harness.controller.zoomFactor == 2)
        #expect(harness.webView.pageZoom == 2)
        let zoomedWidth = try await harness.evaluate("window.innerWidth") as? Double ?? 0
        #expect(abs(zoomedWidth * 2 - unzoomedWidth) <= 2, "At 200% the page should lay out in half the width: \(zoomedWidth) vs \(unzoomedWidth)")

        // Like a browser tab, the zoom stays when the user goes to another page and back.
        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/other.html").path))
        #expect(await harness.waitForTitle("other"))
        #expect(harness.controller.zoomFactor == 2)
        #expect(harness.webView.pageZoom == 2)

        harness.controller.resetZoom()
        #expect(harness.controller.zoomFactor == 1)
        #expect(harness.webView.pageZoom == 1)
    }

    @Test func zoomStopsAtTheLimitsAndResetsFromAnywhere() throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        while harness.controller.canZoomOut { harness.controller.zoomOut() }
        #expect(harness.controller.zoomFactor == HTMLPreviewZoom.levels.first)
        harness.controller.zoomOut()
        #expect(harness.controller.zoomFactor == HTMLPreviewZoom.levels.first)

        while harness.controller.canZoomIn { harness.controller.zoomIn() }
        #expect(harness.controller.zoomFactor == HTMLPreviewZoom.levels.last)
        let appliedZoom = Double(harness.webView.pageZoom)
        #expect(abs(appliedZoom - HTMLPreviewZoom.levels[HTMLPreviewZoom.levels.count - 1]) < 0.001, "pageZoom was \(appliedZoom)")

        harness.controller.resetZoom()
        #expect(harness.controller.zoomFactor == 1)
        #expect(harness.controller.canZoomIn && harness.controller.canZoomOut)
    }

    /// How much of the viewport the page's scroll bars take, in CSS pixels.
    /// Pages need a doctype: in quirks mode `clientHeight` of the root is the content height.
    private func scrollbarSize(_ harness: BrowserHarness) async throws -> (vertical: Double, horizontal: Double) {
        let values = try await harness.evaluate(
            "[innerWidth - document.documentElement.clientWidth, innerHeight - document.documentElement.clientHeight]"
        ) as? [Double] ?? []
        try #require(values.count == 2)
        return (values[0], values[1])
    }

    @Test func overflowingPagesShowScrollBarsAtBothEdges() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<!doctype html><title>other</title><body style=\"margin:0\"><div style=\"width:5000px;height:5000px\"></div></body>"
        ])
        defer { harness.tearDown() }

        harness.show("<!doctype html><title>big</title><body style=\"margin:0\"><div style=\"width:5000px;height:5000px\"></div></body>")
        #expect(await harness.waitForTitle("big"))
        var size = try await scrollbarSize(harness)
        #expect(abs(size.vertical - HTMLPreviewScrollbars.thickness) <= 1, "Vertical bar was \(size.vertical)")
        #expect(abs(size.horizontal - HTMLPreviewScrollbars.thickness) <= 1, "Horizontal bar was \(size.horizontal)")

        // A page that fits has nothing to scroll and shows no bars.
        harness.show("<!doctype html><title>small</title><p>short</p>")
        #expect(await harness.waitForTitle("small"))
        size = try await scrollbarSize(harness)
        #expect(size.vertical == 0 && size.horizontal == 0, "Unexpected bars \(size)")
    }

    @Test func scrollBarsKeepTheirSizeOnScreenWhenThePageIsZoomed() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<!doctype html><title>other</title><body style=\"margin:0\"><div style=\"width:5000px;height:5000px\"></div></body>"
        ])
        defer { harness.tearDown() }
        harness.show("<!doctype html><title>big</title><body style=\"margin:0\"><div style=\"width:5000px;height:5000px\"></div></body>")
        #expect(await harness.waitForTitle("big"))

        // At 200% a CSS pixel is two points, so the same 14-point bar is 7 CSS pixels.
        for _ in 0..<5 { harness.controller.zoomIn() }
        #expect(harness.controller.zoomFactor == 2)
        var size = try await scrollbarSize(harness)
        #expect(abs(size.vertical - HTMLPreviewScrollbars.thickness / 2) <= 1, "Vertical bar was \(size.vertical)")
        #expect(abs(size.horizontal - HTMLPreviewScrollbars.thickness / 2) <= 1, "Horizontal bar was \(size.horizontal)")

        // The next page is styled before it is parsed, at the zoom in force then.
        #expect(harness.controller.navigate(toAddress: harness.fixture.url("site/other.html").path))
        #expect(await harness.waitForTitle("other"))
        size = try await scrollbarSize(harness)
        #expect(abs(size.vertical - HTMLPreviewScrollbars.thickness / 2) <= 1, "Vertical bar was \(size.vertical)")

        harness.controller.resetZoom()
        size = try await scrollbarSize(harness)
        #expect(abs(size.horizontal - HTMLPreviewScrollbars.thickness) <= 1, "Horizontal bar was \(size.horizontal)")
    }

    /// The width of the scroll bar inside the page's frame, in the frame's CSS
    /// pixels, once the frame has loaded. A frame is restyled by a message to its
    /// own process, which the web process handles before the script run here.
    private func frameScrollbar(_ harness: BrowserHarness) async throws -> Double {
        let width = try await harness.evaluateAsync(
            """
            await frameReady;
            const frame = document.getElementById('f').contentWindow;
            return frame.innerWidth - frame.document.documentElement.clientWidth;
            """
        ) as? Double
        return try #require(width)
    }

    @Test func scrollBarsInFramesKeepTheirSizeOnScreenWhenThePageIsZoomed() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/inner.html": "<!doctype html><title>inner</title><body style=\"margin:0\"><div style=\"width:5000px;height:5000px\"></div></body>"
        ])
        defer { harness.tearDown() }
        harness.show("""
            <!doctype html><title>host</title>
            <script>const frameReady = new Promise(resolve => { window.markFrameReady = resolve; });</script>
            <body style="margin:0"><iframe id="f" src="inner.html" onload="markFrameReady()"
              style="width:400px;height:300px;border:0"></iframe></body>
            """)
        #expect(await harness.waitForTitle("host"))
        var width = try await frameScrollbar(harness)
        #expect(abs(width - HTMLPreviewScrollbars.thickness) <= 1, "Frame bar was \(width)")

        // At 200% the frame's bar must become 7 CSS pixels like the page's own.
        for _ in 0..<5 { harness.controller.zoomIn() }
        #expect(harness.controller.zoomFactor == 2)
        width = try await frameScrollbar(harness)
        #expect(abs(width - HTMLPreviewScrollbars.thickness / 2) <= 1, "Frame bar was \(width)")

        harness.controller.resetZoom()
        width = try await frameScrollbar(harness)
        #expect(abs(width - HTMLPreviewScrollbars.thickness) <= 1, "Frame bar was \(width)")
    }

    @Test func aPageStylingItsOwnScrollBarsKeepsThem() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        harness.show("""
            <!doctype html><title>styled</title>
            <style>::-webkit-scrollbar { width: 20px; height: 20px; }</style>
            <body style="margin:0"><div style="width:5000px;height:5000px"></div></body>
            """)
        #expect(await harness.waitForTitle("styled"))
        let size = try await scrollbarSize(harness)
        #expect(abs(size.vertical - 20) <= 1, "The page's own bar should win, vertical bar was \(size.vertical)")
    }

    @Test func switchingToAnotherDocumentShowsThatDocument() async throws {
        let harness = try BrowserHarness(files: ["site/a.html": "disk a", "site/b.html": "disk b"])
        defer { harness.tearDown() }
        harness.show("<title>a</title>", document: "site/a.html")
        #expect(await harness.waitForTitle("a"))

        // Two updates in one pass, as when a tab switch is followed by the new
        // document's text: reloading the page on screen would bring back document a.
        harness.show("<title>stale</title>", document: "site/b.html")
        harness.show("<title>b</title>", document: "site/b.html")

        #expect(await harness.waitForTitle("b"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.controller.address == harness.fixture.url("site/b.html").absoluteString)
    }

    @Test func newWindowLinksOpenInPlace() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/other.html": "<title>other</title>"
        ])
        defer { harness.tearDown() }
        harness.show("<title>first</title><a id=\"go\" href=\"other.html\" target=\"_blank\">go</a>")
        #expect(await harness.waitForTitle("first"))

        _ = try await harness.evaluate("document.getElementById('go').click()")

        #expect(await harness.waitForTitle("other"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.controller.canGoBack)
    }

    @Test func linkedFilesTheViewCannotShowAreOfferedForSaving() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "site/archive.zip": "PK-bytes"
        ])
        defer { harness.tearDown() }
        harness.show("<title>first</title><a id=\"get\" href=\"archive.zip\">get</a>")
        #expect(await harness.waitForTitle("first"))

        _ = try await harness.evaluate("document.getElementById('get').click()")

        #expect(await harness.wait { harness.dialogs.downloadNames == ["archive.zip"] }, "Saved: \(harness.dialogs.downloadNames)")
        // The page the link was on stays, and so does its address.
        let pageAddress = harness.fixture.url("site/page.html").absoluteString
        #expect(await harness.wait { harness.controller.address == pageAddress }, "Address was \(harness.controller.address)")
    }

    @Test func downloadAttributeOffersTheLinkedFileForSaving() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk", "site/data.txt": "plain"])
        defer { harness.tearDown() }
        harness.show("<title>first</title><a id=\"get\" href=\"data.txt\" download>get</a>")
        #expect(await harness.waitForTitle("first"))

        _ = try await harness.evaluate("document.getElementById('get').click()")

        #expect(await harness.wait { harness.dialogs.downloadNames == ["data.txt"] }, "Saved: \(harness.dialogs.downloadNames)")
    }

    @Test func aDirectoryAddressLoadsItsIndexWithRelativeLinksIntact() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "docs/index.html": "<title>docs</title><script src=\"app.js\"></script>",
            "docs/app.js": "document.title = 'docs:script-loaded';"
        ])
        defer { harness.tearDown() }
        harness.show("<title>first</title>")
        #expect(await harness.waitForTitle("first"))

        #expect(harness.controller.navigate(toAddress: harness.fixture.url("docs").path))

        // Without the folder's trailing slash `app.js` would be requested from the root.
        #expect(await harness.waitForTitle("docs:script-loaded"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func aLinkToAFolderWithoutASlashLoadsItsIndexWithRelativeLinksIntact() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "docs/index.html": "<title>docs</title><script src=\"app.js\"></script>",
            "docs/app.js": "document.title = 'docs:script-loaded';"
        ])
        defer { harness.tearDown() }
        harness.show("<title>first</title><a id=\"go\" href=\"/docs\">docs</a>")
        #expect(await harness.waitForTitle("first"))

        _ = try await harness.evaluate("document.getElementById('go').click()")

        #expect(await harness.waitForTitle("docs:script-loaded"), "Title was \(harness.webView.title ?? "nil")")
        #expect(harness.controller.address.hasSuffix("/workspace/docs/"), "Address was \(harness.controller.address)")
        // The redirect replaces the link's navigation: one step back is the page it was on.
        #expect(harness.controller.canGoBack)
        harness.controller.goBack()
        #expect(await harness.waitForTitle("first"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func aFrameShowingAFolderWithoutASlashLoadsItsIndexWithRelativeLinksIntact() async throws {
        let harness = try BrowserHarness(files: [
            "site/page.html": "disk",
            "docs/index.html": "<title>docs</title><script src=\"app.js\"></script>",
            "docs/app.js": "document.documentElement.dataset.loaded = 'yes';"
        ])
        defer { harness.tearDown() }
        harness.show("""
            <title>host</title>
            <script>const frameReady = new Promise(resolve => { window.markFrameReady = resolve; });</script>
            <iframe id="f" src="/docs" onload="if (document.getElementById('f').contentWindow.location.pathname == '/docs/') markFrameReady()"></iframe>
            """)
        #expect(await harness.waitForTitle("host"))

        // The frame is pointed at /docs/ by a script, so it loads a second time.
        let loaded = try await harness.evaluateAsync(
            """
            await frameReady;
            const frame = document.getElementById('f').contentWindow;
            return [frame.location.pathname, frame.document.title, frame.document.documentElement.dataset.loaded];
            """
        ) as? [String]
        #expect(loaded == ["/docs/", "docs", "yes"], "Frame was \(String(describing: loaded))")
    }

    @Test func developerToolsAreOfferedByTheSystemWebKit() throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }

        // The inspector is private WebKit API; this fails if a system update removes it.
        #expect(harness.controller.isDeveloperToolsAvailable)
        #expect(!harness.controller.isDeveloperToolsVisible)
    }

    // MARK: - WebAssembly

    @Test func wasmModulesLoadThroughFetch() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        try harness.fixture.write(HTMLPreviewFixture.addModule, to: "assets/add.wasm")

        harness.show("""
            <script type="module">
            try {
              const response = await fetch('/assets/add.wasm');
              const bytes = new Uint8Array(await response.arrayBuffer());
              const { instance } = await WebAssembly.instantiate(bytes);
              document.title = ['fetch', response.status, response.headers.get('content-type'), bytes.length, instance.exports.add(2, 3)].join(':');
            } catch (error) {
              document.title = 'error:' + error;
            }
            </script>
            """)

        let expected = "fetch:200:application/wasm:\(HTMLPreviewFixture.addModule.count):5"
        #expect(await harness.waitForTitle(expected), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func wasmModulesCompileWhileStreamingFromRootRelativeAndRelativeAddresses() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        try harness.fixture.write(HTMLPreviewFixture.addModule, to: "assets/add.wasm")

        harness.show("""
            <script type="module">
            try {
              const sums = [];
              for (const path of ['/assets/add.wasm', '../assets/add.wasm']) {
                const { instance } = await WebAssembly.instantiateStreaming(fetch(path));
                sums.push(instance.exports.add(40, 2));
              }
              document.title = 'streaming:' + sums.join(',');
            } catch (error) {
              document.title = 'error:' + error;
            }
            </script>
            """)

        #expect(await harness.waitForTitle("streaming:42,42"), "Title was \(harness.webView.title ?? "nil")")
    }

    @Test func streamingCompilationNeedsTheWasmMIMEType() async throws {
        let harness = try BrowserHarness(files: ["site/page.html": "disk"])
        defer { harness.tearDown() }
        // The same bytes under an extension that is not served as application/wasm.
        try harness.fixture.write(HTMLPreviewFixture.addModule, to: "assets/add.bin")

        harness.show("""
            <script type="module">
            const outcome = [];
            try {
              await WebAssembly.instantiateStreaming(fetch('/assets/add.bin'));
              outcome.push('streamed');
            } catch (error) {
              outcome.push(error.name, /MIME/i.test(error.message));
            }
            const bytes = await (await fetch('/assets/add.bin')).arrayBuffer();
            const { instance } = await WebAssembly.instantiate(bytes);
            outcome.push(instance.exports.add(1, 1));
            document.title = outcome.join(':');
            </script>
            """)

        #expect(await harness.waitForTitle("TypeError:true:2"), "Title was \(harness.webView.title ?? "nil")")
    }
}
