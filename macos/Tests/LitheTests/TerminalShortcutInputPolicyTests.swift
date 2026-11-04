import AppKit
import Combine
import Testing
@testable import Lithe

/// Regression coverage for Control chords stolen from a focused terminal by the application keymap.
@MainActor
@Suite("Terminal shortcut input policy")
struct TerminalShortcutInputPolicyTests {
    @MainActor
    private final class Commands: ObservableObject {
        private(set) var ids: [String] = []

        func record(_ id: String) {
            ids.append(id)
            objectWillChange.send()
        }
    }

    @Test
    func keyMonitorTogglesTerminalWithoutStealingShellControlKeys() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = LitheTerminalView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(terminal)
        defer { window.close() }
        #expect(window.makeFirstResponder(terminal))
        let commands = Commands()
        let detector = MacShortcutDetectorFactory().make { commands.record($0) }
        defer { detector.stop() }
        detector.update(registrations: [
            .init(commandID: "debug", bindings: [.keyPress(key: "d", modifiers: .control)]),
            .init(commandID: "run", bindings: [.keyPress(key: "r", modifiers: .control)]),
            .init(commandID: "toggle-terminal", bindings: [.keyPress(key: "`", modifiers: .control)]),
            .init(commandID: "save", bindings: [.keyPress(key: "s", modifiers: .command)])
        ])
        detector.start()
        for (key, code, flags) in [("d", UInt16(2), NSEvent.ModifierFlags.control),
                                   ("`", UInt16(50), .control), ("r", UInt16(15), .control),
                                   ("s", UInt16(1), .command)] {
            NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)))
        }
        let received = await waitForChanges([commands.objectWillChange.eraseToAnyPublisher()], timeout: .seconds(5)) {
            commands.ids.count >= 2
        }
        #expect(received)
        #expect(commands.ids == ["toggle-terminal", "save"])
    }

    @Test
    func terminalToggleBindingRemainsAvailableWhenTerminalIsFocused() {
        let terminal = LitheTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let binding = KeyboardShortcutBinding.keyPress(key: "`", modifiers: .control)
        let registrations = [KeyboardShortcutRegistration(commandID: "toggle-terminal", bindings: [binding])]
        let command = MacKeyboardShortcutMatcher.commandID(for: binding, registrations: registrations)
        #expect(command == "toggle-terminal")
        #expect(!MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: [.control], commandID: command))
        #expect(MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: [.control], commandID: nil))
        #expect(MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: [.control], commandID: "debug"))
        #expect(MacShortcutInputPolicy.shouldDeferToTerminal(terminal, modifierFlags: [.control], commandID: "run"))
    }

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
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
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
