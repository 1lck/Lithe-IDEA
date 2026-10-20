import AppKit
import Testing
@testable import Lithe

/// Regression coverage for Control chords stolen from a focused terminal by the application keymap.
@MainActor
@Suite("Terminal shortcut input policy")
struct TerminalShortcutInputPolicyTests {
    @Test
    func focusedTerminalDefersPlainControlChords() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        // Ctrl-D ends input in readline; the Eclipse keymap binds it to "Debug".
        #expect(MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: [.control]))
    }

    @Test
    func combinedChordsKeepTheirApplicationMeaning() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let chordModifiers: [NSEvent.ModifierFlags] = [
            [.control, .shift],
            [.control, .option],
            [.control, .command],
            [.command],
            [.option],
            []
        ]
        for modifiers in chordModifiers {
            #expect(
                !MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: modifiers),
                "\(modifiers) must stay with the application keymap"
            )
        }
    }

    @Test
    func otherRespondersKeepTheirControlChords() {
        let editor = CodeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        #expect(!MacShortcutInputPolicy.shouldDeferToTerminal(editor, modifierFlags: [.control]))
        #expect(!MacShortcutInputPolicy.shouldDeferToTerminal(nil, modifierFlags: [.control]))
    }

    @Test
    func capsLockDoesNotBreakTheDeferral() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        #expect(
            MacShortcutInputPolicy.shouldDeferToTerminal(
                terminal,
                modifierFlags: [.control, .capsLock]
            )
        )
    }
}
