import AppKit
import SwiftUI

struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = CommitMessageTextView()
        editor.delegate = context.coordinator
        editor.onFocus = { context.coordinator.parent.focused = $0 }
        editor.string = text
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? CommitMessageTextView else { return }
        editor.textColor = NSColor(LitheTheme.primaryText)
        editor.insertionPointColor = NSColor(LitheTheme.primaryText)
        editor.placeholderColor = NSColor(LitheTheme.tertiaryText)
        editor.font = LitheTheme.editorFont(size: LitheTheme.Commit.messageFontSize)
        // Leave IME composition and the selection untouched during normal typing.
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            editor.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageEditor
        init(parent: CommitMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            editor.needsDisplay = true
        }
    }
}

final class CommitMessageTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    var placeholderColor = NSColor.placeholderTextColor
    nonisolated(unsafe) private var outsideClickMonitor: Any?

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
        font = LitheTheme.editorFont(size: LitheTheme.Commit.messageFontSize)
        textContainerInset = NSSize(
            width: LitheTheme.Commit.editorHorizontalInset,
            height: LitheTheme.Commit.editorVerticalInset
        )
        textContainer?.lineFragmentPadding = 0
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        setAccessibilityLabel("Commit Message")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?(true)
            if outsideClickMonitor == nil {
                outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    self?.releaseFocusForOutsideClick(event)
                    return event
                }
            }
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            removeOutsideClickMonitor()
            onFocus?(false)
        }
        return accepted
    }

    func releaseFocusForOutsideClick(_ event: NSEvent) {
        guard let window, window.firstResponder === self, event.window === window,
              let scroll = enclosingScrollView else { return }
        let point = scroll.convert(event.locationInWindow, from: nil)
        if !scroll.bounds.contains(point) { window.makeFirstResponder(nil) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeOutsideClickMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let font else { return }
        // Use TextKit for the placeholder too, so its baseline matches the caret.
        let storage = NSTextStorage(string: "Commit Message", attributes: [
            .font: font, .foregroundColor: placeholderColor
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: textContainer?.containerSize ?? bounds.size)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}
