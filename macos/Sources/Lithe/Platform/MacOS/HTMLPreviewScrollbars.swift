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
///
/// The bar is sized in CSS pixels, which page zoom scales, so the sheet depends
/// on the zoom. The public API can run a script in the main frame or in one
/// given frame, never in all of them, so each frame reports itself when its
/// script starts and the controller restyles the ones it knows after a zoom.
enum HTMLPreviewScrollbars {
    /// The bar's size on screen, in points, whatever the page zoom is.
    static let thickness = 14.0

    static let contentWorld = WKContentWorld.defaultClient

    /// The message a frame sends once, with a token naming its document, so the
    /// controller can restyle it later.
    static let frameReportName = "litheScrollbarFrame"

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

    /// Restyles one frame after the zoom changed. The result is the token the
    /// frame's document reported, or an empty string when its script is not there.
    static func updateScript(zoom: Double) -> String {
        "window.__litheApplyScrollbarStyle ? window.__litheApplyScrollbarStyle(\(HTMLPreviewScript.literal(css(zoom: zoom)))) : '';"
    }

    /// Page zoom scales CSS lengths, so the sizes are divided by it to keep the
    /// bar the same size on screen.
    static func css(zoom: Double) -> String {
        let unit = 1 / max(zoom, 0.01)
        func px(_ points: Double) -> String { String(format: "%.3fpx", points * unit) }
        return """
            @layer lithe-scrollbars{\
            ::-webkit-scrollbar{width:\(px(thickness));height:\(px(thickness));background:transparent}\
            ::-webkit-scrollbar-track{background:rgba(128,128,128,.10)}\
            ::-webkit-scrollbar-thumb{background:rgba(128,128,128,.50);background-clip:padding-box;\
            border:\(px(3)) solid transparent;border-radius:\(px(7));min-height:\(px(32));min-width:\(px(32))}\
            ::-webkit-scrollbar-thumb:hover{background:rgba(128,128,128,.75);background-clip:padding-box}\
            ::-webkit-scrollbar-corner{background:transparent}}
            """
    }

    static func source(zoom: Double) -> String {
        """
        (function () {
          var sheet = null;
          var style = null;
          function apply(css) {
            if (style) { style.textContent = css; return; }
            try {
              if (sheet) { sheet.replaceSync(css); return; }
              if (typeof CSSStyleSheet === 'function' && 'adoptedStyleSheets' in document) {
                sheet = new CSSStyleSheet();
                sheet.replaceSync(css);
                document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
                return;
              }
            } catch (error) { sheet = null; }
            style = document.createElement('style');
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
          var token = Math.random().toString(36).slice(2);
          window.__litheApplyScrollbarStyle = function (css) { apply(css); return token; };
          apply(\(HTMLPreviewScript.literal(css(zoom: zoom))));

          // The main frame is restyled directly; the others have to be reported.
          var handler = window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(frameReportName);
          if (handler && window.parent !== window) { handler.postMessage(token); }
        })();
        """
    }
}

/// Receives a frame's report of itself. It holds the controller weakly: the web
/// view's content controller keeps the handler alive, and the controller owns
/// the web view.
@MainActor
final class HTMLPreviewScrollbarFrameReceiver: NSObject, WKScriptMessageHandler {
    private weak var controller: HTMLPreviewBrowserController?

    init(_ controller: HTMLPreviewBrowserController) { self.controller = controller }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let token = message.body as? String else { return }
        controller?.trackScrollbarFrame(message.frameInfo, token: token)
    }
}
