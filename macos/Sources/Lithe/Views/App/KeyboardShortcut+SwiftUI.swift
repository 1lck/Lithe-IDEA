import AppKit
import SwiftUI

private struct SwiftUIKeyboardShortcutValue {
    let key: KeyEquivalent
    let modifiers: EventModifiers
}

private extension KeyboardShortcutBinding {
    var swiftUIValue: SwiftUIKeyboardShortcutValue? {
        guard case let .keyPress(key, modifiers) = self,
              let keyEquivalent = Self.keyEquivalent(for: key) else { return nil }

        var eventModifiers: EventModifiers = []
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        return SwiftUIKeyboardShortcutValue(key: keyEquivalent, modifiers: eventModifiers)
    }

    static func keyEquivalent(for key: String) -> KeyEquivalent? {
        if key.count == 1, let character = key.first {
            return KeyEquivalent(character)
        }
        switch key {
        case "up": return .upArrow
        case "down": return .downArrow
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "return": return .return
        case "tab": return .tab
        case "space": return .space
        case "delete": return .delete
        default:
            guard key.first == "f", let number = Int(key.dropFirst()), (1...20).contains(number),
                  let scalar = UnicodeScalar(NSF1FunctionKey + number - 1) else { return nil }
            return KeyEquivalent(Character(String(scalar)))
        }
    }
}

extension View {
    @ViewBuilder
    func litheKeyboardShortcut(_ binding: KeyboardShortcutBinding?) -> some View {
        if let value = binding?.swiftUIValue {
            keyboardShortcut(value.key, modifiers: value.modifiers)
        } else {
            self
        }
    }
}
