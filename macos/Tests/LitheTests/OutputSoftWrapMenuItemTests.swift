import AppKit
import Testing
@testable import Lithe

@Suite("Output soft-wrap menu item")
@MainActor
struct OutputSoftWrapMenuItemTests {
    @Test
    func checkmarkReflectsTheCurrentWrapMode() {
        #expect(OutputSoftWrapMenuItem(isOn: true, onToggle: {}).state == .on)
        #expect(OutputSoftWrapMenuItem(isOn: false, onToggle: {}).state == .off)
    }

    @Test
    func choosingTheItemInvokesTheToggleExactlyOnce() throws {
        var toggles = 0
        let item = OutputSoftWrapMenuItem(isOn: false) { toggles += 1 }
        let action = try #require(item.action)
        let target = try #require(item.target as? NSObject)

        // Dispatch through the item's own target-action pair, as AppKit does
        // when the menu entry is chosen.
        _ = target.perform(action, with: item)

        #expect(toggles == 1)
    }

    @Test
    func itemIsSelfContainedAndHasNoShortcut() {
        let item = OutputSoftWrapMenuItem(isOn: false, onToggle: {})

        // The item must not rely on the responder chain, or it would be
        // disabled inside the text view's context menu.
        #expect(item.target === item)
        #expect(item.keyEquivalent.isEmpty)
        #expect(!item.title.isEmpty)
    }
}
