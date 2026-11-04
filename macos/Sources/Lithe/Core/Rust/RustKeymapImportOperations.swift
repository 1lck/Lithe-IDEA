import Foundation
import LitheCoreContracts

/// A Core-validated file selector, relative to the user's selected source.
struct KeymapImportInputSelector: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable { case file, directory }
    let kind: Kind
    let path: String
    let fileExtension: String?

    private enum CodingKeys: String, CodingKey {
        case kind, path
        case fileExtension = "extension"
    }
}

/// A metadata-only test of a path below the selected source directory.
enum KeymapImportRecognitionProbe: Decodable, Equatable, Sendable {
    enum Base: String, Decodable, Sendable { case userConfig }
    case file(path: String)
    case directory(path: String)
    case root(base: Base, components: [String])

    private enum Kind: String, Decodable { case file, directory, root }
    private enum CodingKeys: String, CodingKey { case kind, path, base, components }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(Kind.self, forKey: .kind) {
        case .file: self = .file(path: try fields.decode(String.self, forKey: .path))
        case .directory: self = .directory(path: try fields.decode(String.self, forKey: .path))
        case .root: self = .root(base: try fields.decode(Base.self, forKey: .base),
                                 components: try fields.decode([String].self, forKey: .components))
        }
    }
}

/// Native I/O consumes the selectors and resource budgets returned by Core.
struct KeymapImportSourcePlan: Decodable, Equatable, Sendable {
    struct Limits: Decodable, Equatable, Sendable {
        let selectors: Int
        let probes: Int
        let files: Int
        let fileBytes: Int
        let totalBytes: Int
        let chunkBytes: Int
        let directoryEntries: Int
        let directoryMatches: Int
    }
    let inputs: [KeymapImportInputSelector]
    let recognition: [KeymapImportRecognitionProbe]
    let limits: Limits
}

/// A normalized Core-validated binding; platform adapters map it to native keys.
struct KeymapImportBinding: Codable, Equatable, Sendable {
    struct Key: Codable, Hashable, Sendable {
        enum Modifier: String, Codable, Hashable, Sendable { case control, alt, shift, meta }
        let key: String
        let modifiers: [Modifier]
    }
    let commandID: String
    let keys: [Key]
}

enum KeymapNativeBindingError: Error { case unsupported }

extension KeymapImportBinding {
    /// Converts only keys this host can actually register; forward delete,
    /// higher function keys and other unsupported keys fail as a whole.
    func nativeBindings() throws -> [KeyboardShortcutBinding] {
        try keys.map { item in
            var modifiers: KeyboardShortcutModifiers = []
            for modifier in item.modifiers {
                switch modifier {
                case .control: modifiers.insert(.control)
                case .alt: modifiers.insert(.option)
                case .shift: modifiers.insert(.shift)
                case .meta: modifiers.insert(.command)
                }
            }
            guard item.key != "delete" else { throw KeymapNativeBindingError.unsupported }
            let binding = KeyboardShortcutBinding.keyPress(key: item.key == "backspace" ? "delete" : item.key, modifiers: modifiers)
            guard binding.isAssignable else { throw KeymapNativeBindingError.unsupported }
            return binding
        }
    }
}

struct KeymapImportCurrent: Encodable, Sendable {
    let commandID: String
    let customized: Bool
    let keys: [KeymapImportBinding.Key]
}

struct KeymapImportBindingPlan: Decodable, Sendable {
    struct Conflict: Decodable, Sendable {
        let commandID: String
        let ownerID: String
        let key: KeymapImportBinding.Key
    }
    let displaced: [KeymapImportBinding]
    let conflicts: [Conflict]
}

/// Bridges generic shortcut import data to Core; it never parses source formats.
struct RustKeymapImportOperations: Sendable {
    let core: RustCoreBridge

    func planSources(manifest: Data, providerID: String) throws -> KeymapImportSourcePlan {
        struct Request: Encodable { let manifest: ToolingJSONValue; let providerID: String }
        let payload = Request(manifest: try JSONDecoder().decode(ToolingJSONValue.self, from: manifest), providerID: providerID)
        let result: Result<KeymapImportSourcePlan, RustCoreBridge.CoreCallError> = core.executeResult(command: "keymap.planImportSources", payload: payload)
        return try result.get()
    }

    func decodeImport(commandIDs: [String], reply: ToolingJSONValue) throws -> [KeymapImportBinding] {
        struct Request: Encodable { let commandIDs: [String]; let reply: ToolingJSONValue }
        struct Response: Decodable { let bindings: [KeymapImportBinding] }
        let result: Result<Response, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "keymap.decodeImport", payload: Request(commandIDs: commandIDs, reply: reply)
        )
        return try result.get().bindings
    }

    func planBindings(current: [KeymapImportCurrent], incoming: [KeymapImportBinding]) throws -> KeymapImportBindingPlan {
        struct Reply: Encodable { let bindings: [KeymapImportBinding] }
        struct Request: Encodable { let current: [KeymapImportCurrent]; let incoming: Reply }
        let result: Result<KeymapImportBindingPlan, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "keymap.planImportBindings", payload: Request(current: current, incoming: Reply(bindings: incoming))
        )
        return try result.get()
    }
}
