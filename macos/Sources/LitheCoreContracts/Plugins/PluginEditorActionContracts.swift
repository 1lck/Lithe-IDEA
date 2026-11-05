import Foundation

/// The editor presentation one host declares to Core, which relays it to a
/// plugin backend through `lithe/host/getCapabilities` and validates every
/// registration and result against it.
public struct PluginEditorHostOptions: Encodable, Equatable, Sendable {
    /// Icon names the host has resources for; actions and alternatives use them.
    public let actionIcons: [String]
    /// Largest document, in UTF-8 bytes, the host collects actions for.
    public let actionSourceBytes: Int
    /// Provider types `lithe/host/editor/registerProviders` routes on this host.
    public let providerTypes: [String]

    public init(actionIcons: [String], actionSourceBytes: Int, providerTypes: [String]) {
        self.actionIcons = actionIcons
        self.actionSourceBytes = actionSourceBytes
        self.providerTypes = providerTypes
    }
}

/// Core validates independent editor presentation without interpreting plugin business data.
public protocol PluginEditorActionDecoding: Sendable {
    /// `kind` is `registration`, `actions` (with the exact document `text`)
    /// or `invokeResult`; `host` selects the version 2 rules.
    func decodeEditorActions(
        kind: String, value: ToolingJSONValue, text: String, host: PluginEditorHostOptions
    ) throws -> ToolingJSONValue
}

/// A provider registration naming a type the host does not route.
public struct PluginEditorProviderUnsupported: Error, Equatable, Sendable {
    /// The offending option, for example `providers.hover`.
    public let option: String

    public init(option: String) {
        self.option = option
    }
}

/// Core validates provider registrations and the normalized shape of each
/// provider function's answer; the host never interprets plugin payloads.
public protocol PluginEditorProviderDecoding: Sendable {
    /// Throws `PluginEditorProviderUnsupported` for a type outside `types`.
    func decodeEditorProviderRegistration(value: ToolingJSONValue, types: [String]) throws -> ToolingJSONValue
    /// `legend` is the registered legend of a semantic tokens provider.
    func decodeEditorProviderResult(
        type: String, value: ToolingJSONValue, legend: ToolingJSONValue?
    ) throws -> ToolingJSONValue
    /// Core's definition merge: the language server's locations come first and
    /// plugin locations only add to them. Both lists are LSP `Location` values;
    /// the result is the indices each side keeps.
    func mergeEditorDefinitions(
        documentURI: String, line: Int, character: Int, server: [ToolingJSONValue], plugin: [ToolingJSONValue]
    ) throws -> (server: [Int], plugin: [Int])
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
    /// A further choice offered next to the main action, such as debugging
    /// next to running; clicking it invokes its own function.
    public struct Alternative: Equatable, Decodable, Sendable {
        public let id: String
        public let title: String
        public let icon: String
        public let invoke: Invocation
    }
    public let id: String
    public let range: Range
    public let title: String
    public let icon: String
    public let invoke: Invocation
    public let alternatives: [Alternative]

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        range = try container.decode(Range.self, forKey: .range)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decode(String.self, forKey: .icon)
        invoke = try container.decode(Invocation.self, forKey: .invoke)
        alternatives = try container.decodeIfPresent([Alternative].self, forKey: .alternatives) ?? []
    }

    /// Every function a click on this action or one of its alternatives calls.
    public var functionIDs: [String] { [invoke.functionID] + alternatives.map(\.invoke.functionID) }

    private enum CodingKeys: String, CodingKey { case id, range, title, icon, invoke, alternatives }
}

/// Where a clicked action asks the host to look, from the action function's
/// `reveal` result: LSP shaped locations the host presents.
public struct PluginEditorReveal: Equatable, Decodable, Sendable {
    public struct Position: Equatable, Decodable, Sendable {
        public let line: Int
        public let character: Int
    }
    public struct Range: Equatable, Decodable, Sendable {
        public let start: Position
        public let end: Position
    }
    public struct Location: Equatable, Decodable, Sendable {
        public let uri: String
        public let range: Range
    }
    public let locations: [Location]
}
