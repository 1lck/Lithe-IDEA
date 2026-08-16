import AppKit
import Testing
@testable import Lithe

@Suite("macOS keyboard shortcut mapping")
struct MacKeyboardShortcutTests {
    @Test
    func mapsCharactersAndModifiersToCanonicalBinding() {
        let binding = MacKeyboardShortcutEventMapper.binding(
            keyCode: 3,
            charactersIgnoringModifiers: "f",
            modifierFlags: [.command, .shift]
        )
        #expect(binding == .keyPress(key: "f", modifiers: [.command, .shift]))
    }

    @Test
    func mapsSpecialAndFunctionKeysWithoutCharacters() {
        #expect(
            MacKeyboardShortcutEventMapper.binding(
                keyCode: 123,
                charactersIgnoringModifiers: nil,
                modifierFlags: [.option]
            ) == .keyPress(key: "left", modifiers: [.option])
        )
        #expect(
            MacKeyboardShortcutEventMapper.binding(
                keyCode: 96,
                charactersIgnoringModifiers: nil,
                modifierFlags: []
            ) == .keyPress(key: "f5", modifiers: [])
        )
    }

    @Test
    func ignoresUnsupportedKeyEvents() {
        #expect(
            MacKeyboardShortcutEventMapper.binding(
                keyCode: 255,
                charactersIgnoringModifiers: nil,
                modifierFlags: []
            ) == nil
        )
    }

    @Test
    func matcherReturnsTheStableCommandID() {
        let binding = KeyboardShortcutBinding.keyPress(key: "r", modifiers: [.control])
        let registrations = [
            KeyboardShortcutRegistration(commandID: "run", bindings: [binding])
        ]

        #expect(
            MacKeyboardShortcutMatcher.commandID(
                for: binding,
                registrations: registrations
            ) == "run"
        )
    }
}
