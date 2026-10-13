import AppKit
import SwiftUI

/// Plain configuration input, using the same TextKit policy as the source and SQL editors.
struct MacConfigurationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = MacConfigurationTextView()
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(label)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? MacConfigurationTextView else { return }
        editor.isEditable = context.environment.isEnabled
        editor.textColor = NSColor(LitheTheme.primaryText)
        editor.insertionPointColor = NSColor(LitheTheme.primaryText)
        // Normal binding updates must not interrupt IME composition or reset the caret.
        if editor.string != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let location = min(selection.location, text.utf16.count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, text.utf16.count - location)))
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

/// Configuration syntax must retain the literal characters the user types.
final class MacConfigurationTextView: NSTextView {
    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = LitheTheme.uiNSFont(size: 11, weight: .regular)
        textContainerInset = NSSize(width: 6, height: 6)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
