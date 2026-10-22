import Foundation
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// Scroll bars that stay on screen, like a desktop browser's.
///
/// WebKit draws the system's overlay scroll bars, which are invisible until the
/// page is being scrolled, so a page that is wider or taller than the preview
/// gives no sign of it. A style sheet puts classic bars at the right and bottom
/// edges, present whenever the content overflows. The rules sit in a cascade
/// layer, which any rule of the page's own outranks, so a page that styles its
/// scroll bars keeps its look; the script runs in a separate content world so
/// the page cannot see it.
enum HTMLPreviewScrollbars {
    /// The bar's size on screen, in points, whatever the page zoom is.
    static let thickness = 14.0

    static let contentWorld = WKContentWorld.defaultClient

    /// Runs before the page is parsed, in every frame, so frames and later
    /// navigations are covered without any work from the controller.
    static func userScript(zoom: Double) -> WKUserScript {
        WKUserScript(
            source: source(zoom: zoom),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: contentWorld
        )
    }

    /// Page zoom scales CSS lengths, so the sizes are divided by it to keep the
    /// bar the same size on screen. Running the source again replaces the sheet.
    static func source(zoom: Double) -> String {
        let unit = 1 / max(zoom, 0.01)
        func px(_ points: Double) -> String { String(format: "%.3fpx", points * unit) }
        let css = """
            @layer lithe-scrollbars{\
            ::-webkit-scrollbar{width:\(px(thickness));height:\(px(thickness));background:transparent}\
            ::-webkit-scrollbar-track{background:rgba(128,128,128,.10)}\
            ::-webkit-scrollbar-thumb{background:rgba(128,128,128,.50);background-clip:padding-box;\
            border:\(px(3)) solid transparent;border-radius:\(px(7));min-height:\(px(32));min-width:\(px(32))}\
            ::-webkit-scrollbar-thumb:hover{background:rgba(128,128,128,.75);background-clip:padding-box}\
            ::-webkit-scrollbar-corner{background:transparent}}
            """
        return """
            (function () {
              var css = \(literal(css));
              try {
                if (window.__litheScrollbarSheet) { window.__litheScrollbarSheet.replaceSync(css); return; }
                if (typeof CSSStyleSheet === 'function' && 'adoptedStyleSheets' in document) {
                  var sheet = new CSSStyleSheet();
                  sheet.replaceSync(css);
                  document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
                  window.__litheScrollbarSheet = sheet;
                  return;
                }
              } catch (error) {}
              var style = document.createElement('style');
              style.textContent = css;
              (document.head || document.documentElement).appendChild(style);
            })();
            """
    }

    /// A JavaScript string literal, so the CSS cannot break out of the script.
    private static func literal(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
