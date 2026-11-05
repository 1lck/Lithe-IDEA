import Foundation

/// A key sequence and `when` clause that several commands are bound to at once, as decided by Core.
struct KeymapBindingConflict: Decodable, Equatable, Sendable {
    let key: String
    let commands: [String]
}

extension KeyboardShortcutBinding {
    /// Native key to Core binding grammar. The AppKit key names stay here; what the
    /// resulting text means (aliases, modifier order, equivalence) is Core's.
    var coreBindingText: String {
        switch self {
        case let .keyPress(key, modifiers):
            let names = [
                modifiers.contains(.control) ? "ctrl" : nil,
                modifiers.contains(.option) ? "alt" : nil,
                modifiers.contains(.shift) ? "shift" : nil,
                modifiers.contains(.command) ? "meta" : nil
            ].compactMap { $0 }
            // macOS calls the Backspace key "delete".
            return (names + [key == "delete" ? "backspace" : key]).joined(separator: "+")
        case .doubleTap(.shift):
            return "doubleshift"
        }
    }
}

extension RustCoreBridge {
    /// Conflicts among the final bindings after `overrides` replace `base` per command.
    /// An empty override unbinds the command. Failure is returned, never treated as "no conflict".
    func analyzeKeymapConflicts(
        base: [KeyboardShortcutRegistration],
        overrides: [String: [KeyboardShortcutBinding]]
    ) -> Result<[KeymapBindingConflict], CoreCallError> {
        struct Entry: Encodable { let command: String; let key: String }
        struct Layer: Encodable { let entries: [Entry]; let disabledCommands: [String] }
        struct Request: Encodable { let platform = "macos"; let layers: [Layer] }
        struct Response: Decodable { let conflicts: [KeymapBindingConflict] }
        func entries(_ commandID: String, _ bindings: [KeyboardShortcutBinding]) -> [Entry] {
            bindings.map { Entry(command: commandID, key: $0.coreBindingText) }
        }
        let request = Request(layers: [
            Layer(entries: base.flatMap { entries($0.commandID, $0.bindings) }, disabledCommands: []),
            Layer(
                entries: overrides.sorted { $0.key < $1.key }.flatMap { entries($0.key, $0.value) },
                disabledCommands: overrides.filter { $0.value.isEmpty }.map(\.key).sorted()
            )
        ])
        let result: Result<Response, CoreCallError> = executeResult(
            command: "keymap.analyzeConflicts", payload: request)
        return result.map(\.conflicts)
    }
}
