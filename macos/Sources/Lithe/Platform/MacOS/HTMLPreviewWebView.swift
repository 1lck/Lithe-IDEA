import LitheModuleAPI
import AppKit
import SwiftUI

/// Hosts the browser controller's web view in SwiftUI.
///
/// The controller owns the web view and its lifetime; this wrapper only embeds
/// the container and forwards editor changes, so re-creating the wrapper (for
/// example when switching between editor, split and preview modes) never reloads the page.
struct HTMLPreviewWebView: NSViewRepresentable {
    @Environment(\.applicationLogSink) private var logSink
    let controller: HTMLPreviewBrowserController
    let payload: HTMLPreviewBrowserController.Payload

    func makeNSView(context: Context) -> NSView {
        controller.logSink = logSink
        controller.update(payload)
        return controller.containerView
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.logSink = logSink
        controller.update(payload)
    }
}
