import Foundation

/// Versioned host-rendered content. Plugins describe semantics, never styling or code.
public struct PluginNativeUI: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case tree, list, form }
    public struct Node: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let children: [Node]?
    }
    public enum ControlValue: Codable, Equatable, Sendable {
        case text(String)
        case checked(Bool)
        case number(Double)

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let text = try? value.decode(String.self) { self = .text(text) }
            else if let checked = try? value.decode(Bool.self) { self = .checked(checked) }
            else { self = .number(try value.decode(Double.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .text(let text): try value.encode(text)
            case .checked(let checked): try value.encode(checked)
            case .number(let number): try value.encode(number)
            }
        }
    }
    public struct GridLayout: Codable, Equatable, Sendable {
        public let columns: Int
    }
    public struct Control: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case input, search, editor, select, segmented, checkbox, stepper }
        public struct Option: Codable, Equatable, Sendable {
            public let id: String
            public let label: String
        }
        public let id: String
        public let kind: Kind
        public let label: String
        public let value: ControlValue
        public let placeholder: String?
        public let options: [Option]?
        public let enabled: Bool?
        public let onCommit: String?
        public let span: Int?
        public let info: String?
        public let rows: Int?
        public let minimum: Double?
        public let maximum: Double?
        public let step: Double?

        /// Restored state and user edits must still fit the current declaration.
        public func accepts(_ value: ControlValue) -> Bool {
            switch (kind, value) {
            case (.input, .text(let text)), (.search, .text(let text)): return text.utf8.count <= 1024
            case (.editor, .text(let text)): return text.utf8.count <= 8192
            case (.select, .text(let id)), (.segmented, .text(let id)): return options?.contains { $0.id == id } == true
            case (.checkbox, .checked): return true
            case (.stepper, .number(let number)):
                return number.isFinite && minimum.map { number >= $0 } == true && maximum.map { number <= $0 } == true
            default: return false
            }
        }
    }
    public struct Button: Codable, Equatable, Identifiable, Sendable {
        public enum Width: String, Codable, Sendable { case content, fill }
        public let id: String
        public let label: String
        public let action: String
        /// Legacy layout hint; native actions now use the shared natural-width style.
        public let width: Width?
        public let primary: Bool?
        public let enabled: Bool?
        public let span: Int?
        public let info: String?
    }
    public struct Source: Codable, Equatable, Sendable {
        public let buildSystemID: String
        public let function: String
    }
    public struct Action: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, Sendable { case refresh, invoke }
        public let id: String
        public let title: String
        public let icon: PluginUIIcon?
        public let kind: Kind
        public let function: String?
        public let requiresSelection: Bool
    }
    public let schemaVersion: Int
    public let id: String
    public let kind: Kind
    public let nodes: [Node]
    public let controls: [Control]?
    public let layout: GridLayout?
    public let buttons: [Button]?
    public let source: Source?
    public let actions: [Action]
    public let toolbar: [String]
    public let contextMenu: [String]
}
