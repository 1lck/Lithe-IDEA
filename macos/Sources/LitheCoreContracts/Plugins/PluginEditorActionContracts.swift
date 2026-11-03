import Foundation

/// Core validates independent editor presentation without interpreting plugin business data.
public protocol PluginEditorActionDecoding: Sendable {
    func decodeEditorActions(kind: String, value: ToolingJSONValue, text: String) throws -> ToolingJSONValue
}

/// One plugin-private action, anchored in a one-based UTF-16 document range.
public struct PluginEditorAction: Equatable, Decodable, Sendable {
    public struct Position: Equatable, Decodable, Sendable {
        public let line: Int
        public let column: Int
    }
    public struct Range: Equatable, Decodable, Sendable {
        public let start: Position
        public let end: Position
    }
    public struct Invocation: Equatable, Decodable, Sendable {
        public let functionID: String
        public let params: ToolingJSONValue
    }
    public let id: String
    public let range: Range
    public let title: String
    public let icon: String
    public let invoke: Invocation
}
