import Foundation

struct KeyboardShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    static let supported: Self = [.control, .option, .shift, .command]
}

enum KeyboardModifier: String, Codable, Hashable, Sendable {
    case shift
}

enum KeyboardShortcutBinding: Hashable, Sendable {
    case keyPress(key: String, modifiers: KeyboardShortcutModifiers)
    case doubleTap(KeyboardModifier)

    var displayText: String {
        switch self {
        case let .keyPress(key, modifiers):
            let prefix = [
                modifiers.contains(.control) ? "⌃" : "",
                modifiers.contains(.option) ? "⌥" : "",
                modifiers.contains(.shift) ? "⇧" : "",
                modifiers.contains(.command) ? "⌘" : ""
            ].joined()
            return prefix + Self.displayName(for: key)
        case .doubleTap(.shift):
            return "⇧ ⇧"
        }
    }

    var isAssignable: Bool {
        switch self {
        case let .keyPress(key, modifiers):
            guard Self.isSupportedKey(key), modifiers.isSubset(of: .supported) else { return false }
            let isTextKey = key.count == 1
            let actionModifiers: KeyboardShortcutModifiers = [.command, .control, .option]
            return !isTextKey || !modifiers.intersection(actionModifiers).isEmpty
        case .doubleTap:
            return true
        }
    }

    var keyPressValue: (key: String, modifiers: KeyboardShortcutModifiers)? {
        guard case let .keyPress(key, modifiers) = self else { return nil }
        return (key, modifiers)
    }

    static func isSupportedKey(_ key: String) -> Bool {
        if key.count == 1 {
            return key.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && !CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
        }
        if key.first == "f", let number = Int(key.dropFirst()) {
            return (1...20).contains(number)
        }
        return ["up", "down", "left", "right", "return", "tab", "space", "delete"].contains(key)
    }

    private static func displayName(for key: String) -> String {
        switch key {
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "delete": "⌫"
        default: key.uppercased()
        }
    }
}

extension KeyboardShortcutBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case key
        case modifiers
        case modifier
    }

    private enum Kind: String, Codable {
        case keyPress
        case doubleTap
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .keyPress:
            let key = try container.decode(String.self, forKey: .key)
            let modifiers = try container.decode(KeyboardShortcutModifiers.self, forKey: .modifiers)
            let value = Self.keyPress(key: key, modifiers: modifiers)
            guard value.isAssignable else {
                throw DecodingError.dataCorruptedError(
                    forKey: .key,
                    in: container,
                    debugDescription: "Unsupported keyboard shortcut"
                )
            }
            self = value
        case .doubleTap:
            self = .doubleTap(try container.decode(KeyboardModifier.self, forKey: .modifier))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keyPress(key, modifiers):
            try container.encode(Kind.keyPress, forKey: .kind)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
        case let .doubleTap(modifier):
            try container.encode(Kind.doubleTap, forKey: .kind)
            try container.encode(modifier, forKey: .modifier)
        }
    }
}

struct KeyboardShortcutRegistration: Equatable, Sendable {
    let commandID: String
    let bindings: [KeyboardShortcutBinding]
}
