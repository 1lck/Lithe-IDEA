import AppKit
import LitheModuleAPI
import SwiftUI

/// Execution consent must expose every argument and the directory, including
/// long single-line values. TextKit owns layout, selection and viewport drawing.
struct PluginHostMessageDetailsView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> PluginHostMessageDetailsScrollView {
        PluginHostMessageDetailsScrollView(text: text)
    }

    func updateNSView(_ scroll: PluginHostMessageDetailsScrollView, context: Context) {
        guard let document = scroll.documentView as? NSTextView else { return }
        if document.string != text { document.string = text }
        document.textColor = NSColor(LitheTheme.primaryText)
    }
}

final class PluginHostMessageDetailsScrollView: NSScrollView {
    init(text: String) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        verticalScroller = LitheScrollViewChrome.CompactScroller()
        autohidesScrollers = true
        let document = MacConfigurationTextView()
        document.isEditable = false
        document.isSelectable = true
        document.allowsUndo = false
        document.font = LitheTheme.editorFont(size: 11)
        document.setAccessibilityLabel(L10n.string("Open a plugin terminal"))
        document.string = text
        documentView = document
        LitheTextViewportLayout.apply(to: document, in: self, softWrap: true)
    }

    required init?(coder: NSCoder) { nil }
}
