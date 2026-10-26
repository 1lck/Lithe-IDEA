import Foundation

/// Why a v2 debug projection was rejected before it could reach the UI.
public struct DebugProjectionV2Error: Error, Equatable, Sendable {
    public let message: String
}

/// A source location identity. Exactly one identity is allowed per source so a
/// frame can never name a file and a session-bound document at the same time.
public enum DebugProjectionV2Source: Decodable, Equatable, Sendable {
    case workspace(path: String)
    case session(sourceReference: Int, name: String, origin: String?)
    case external(grantID: String, name: String)

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        let kind = try container.decode(String.self, forKey: key("kind"))
        let allowed: Set<String>
        switch kind {
        case "workspace": allowed = ["kind", "path"]
        case "session": allowed = ["kind", "sourceReference", "name", "origin"]
        case "external": allowed = ["kind", "grantID", "name"]
        default:
            throw DebugProjectionV2Error(message: "unknown source kind \(kind)")
        }
        if let extra = Set(container.allKeys.map(\.stringValue)).subtracting(allowed).sorted().first {
            throw DebugProjectionV2Error(message: "source of kind \(kind) must not carry \(extra)")
        }
        switch kind {
        case "workspace":
            let path = try container.decode(String.self, forKey: key("path"))
            let drive = path.utf8.count > 1
                && Array(path.utf8)[1] == UInt8(ascii: ":")
                && (path.first?.isLetter ?? false)
            if path.isEmpty || path.hasPrefix("/") || drive
                || path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw DebugProjectionV2Error(message: "workspace path \(path) must stay inside the workspace")
            }
            self = .workspace(path: path)
        case "session":
            let reference = try container.decode(Int.self, forKey: key("sourceReference"))
            guard (1...Int(Int32.max)).contains(reference) else {
                throw DebugProjectionV2Error(message: "sourceReference out of range")
            }
            self = .session(
                sourceReference: reference,
                name: try container.decode(String.self, forKey: key("name")),
                origin: try container.decodeIfPresent(String.self, forKey: key("origin"))
            )
        default:
            self = .external(
                grantID: try container.decode(String.self, forKey: key("grantID")),
                name: try container.decode(String.self, forKey: key("name"))
            )
        }
    }
}

/// A frame whose source is optional (assembly, JIT and native frames have none).
/// Addresses stay strings because 64-bit values exceed JSON number precision.
public struct DebugProjectionV2Frame: Decodable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let source: DebugProjectionV2Source?
    public let line: Int?
    public let column: Int?
    public let instructionPointerReference: String?
    public let presentationHint: String?

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey {
            case id, name, source, line, column, endLine, endColumn
            case instructionPointerReference, presentationHint
        }
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decodeIfPresent(DebugProjectionV2Source.self, forKey: .source)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        column = try container.decodeIfPresent(Int.self, forKey: .column)
        let endLine = try container.decodeIfPresent(Int.self, forKey: .endLine)
        let endColumn = try container.decodeIfPresent(Int.self, forKey: .endColumn)
        instructionPointerReference = try container.decodeIfPresent(
            String.self,
            forKey: .instructionPointerReference
        )
        presentationHint = try container.decodeIfPresent(String.self, forKey: .presentationHint)
        if line != nil, source == nil {
            throw DebugProjectionV2Error(message: "frame line requires a source")
        }
        if (column != nil && line == nil) || (endLine != nil && line == nil)
            || (endColumn != nil && endLine == nil) {
            throw DebugProjectionV2Error(message: "frame coordinates need their parent coordinate")
        }
        if [line, column, endLine, endColumn].contains(where: { $0 == 0 }) {
            throw DebugProjectionV2Error(message: "frame coordinates are one-based")
        }
    }
}

public struct DebugProjectionV2Scope: Decodable, Equatable, Sendable {
    public let name: String
    public let presentationHint: String?
    public let variablesReference: Int
    public let expensive: Bool
}

/// `supported` is only true when the adapter, the extension and the user all allow it.
public struct DebugProjectionV2CapabilityState: Decodable, Equatable, Sendable {
    public let adapter: Bool
    public let extensionEnabled: Bool
    public let authorized: Bool
    public let supported: Bool

    private enum CodingKeys: String, CodingKey {
        case adapter, authorized, supported
        case extensionEnabled = "extension"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adapter = try container.decode(Bool.self, forKey: .adapter)
        extensionEnabled = try container.decode(Bool.self, forKey: .extensionEnabled)
        authorized = try container.decode(Bool.self, forKey: .authorized)
        supported = try container.decode(Bool.self, forKey: .supported)
        if supported != (adapter && extensionEnabled && authorized) {
            throw DebugProjectionV2Error(message: "capability supported overstates its layers")
        }
    }
}

public enum DebugProjectionV2Payload: Decodable, Equatable, Sendable {
    case stackTrace(threadID: Int, frames: [DebugProjectionV2Frame])
    case scopes(frameID: String, scopes: [DebugProjectionV2Scope])
    case capabilities(revision: Int, states: [String: DebugProjectionV2CapabilityState])

    private enum CodingKeys: String, CodingKey {
        case kind, threadID, frames, frameID, scopes, revision, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "stackTrace":
            self = .stackTrace(
                threadID: try container.decode(Int.self, forKey: .threadID),
                frames: try container.decode([DebugProjectionV2Frame].self, forKey: .frames)
            )
        case "scopes":
            self = .scopes(
                frameID: try container.decode(String.self, forKey: .frameID),
                scopes: try container.decode([DebugProjectionV2Scope].self, forKey: .scopes)
            )
        case "capabilities":
            self = .capabilities(
                revision: try container.decode(Int.self, forKey: .revision),
                states: try container.decode(
                    [String: DebugProjectionV2CapabilityState].self,
                    forKey: .capabilities
                )
            )
        case let kind:
            throw DebugProjectionV2Error(message: "unknown projection kind \(kind)")
        }
    }
}

/// Versioned envelope that every v2 projection arrives in. `stopGeneration`
/// lets the UI drop projections that belong to an earlier stop.
public struct DebugProjectionV2: Decodable, Equatable, Sendable {
    public let projectionVersion: Int
    public let sessionID: String
    public let stopGeneration: Int
    public let projection: DebugProjectionV2Payload

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectionVersion = try container.decode(Int.self, forKey: .projectionVersion)
        guard projectionVersion == 2 else {
            throw DebugProjectionV2Error(message: "unsupported projection version \(projectionVersion)")
        }
        sessionID = try container.decode(String.self, forKey: .sessionID)
        stopGeneration = try container.decode(Int.self, forKey: .stopGeneration)
        projection = try container.decode(DebugProjectionV2Payload.self, forKey: .projection)
    }

    private enum CodingKeys: String, CodingKey {
        case projectionVersion, sessionID, stopGeneration, projection
    }
}
