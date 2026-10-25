import AppKit
import Testing
@testable import Lithe

@MainActor
@Suite("Shortcut marked-text policy")
struct MacShortcutMarkedTextTests {
    @Test
    func markedTextDefersKeyAndModifierShortcuts() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.setMarkedText(
            "ni",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0)
        )

        #expect(view.hasMarkedText())
        #expect(MacShortcutInputPolicy.shouldDeferToMarkedText(view))

        view.unmarkText()
        #expect(!MacShortcutInputPolicy.shouldDeferToMarkedText(view))
    }
}
