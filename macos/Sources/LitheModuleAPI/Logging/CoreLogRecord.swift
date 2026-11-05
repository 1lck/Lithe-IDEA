import Foundation

/// Catalog disk scalars supplied by Core. No protocol payload or nested object
/// can cross this ingress; encodeLogBatch still validates and redacts the record.
public enum CoreLogScalar: Codable, Hashable, Sendable {
    case string(String), int(Int64), uint(UInt64), bool(Bool)
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Int64.self) { self = .int(v) }
        else if let v = try? value.decode(UInt64.self) { self = .uint(v) }
        else { self = .string(try value.decode(String.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .int(let v): try value.encode(v)
        case .uint(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        }
    }
}

/// Core owns identity, severity, channel and fields; the host owns sequence and
/// assigns a timestamp only when the source did not supply one.
public struct CoreLogRecord: Codable, Equatable, Sendable {
    public let event: String
    public let level: String
    public let channel: String
    public let op: String?
    public let fields: [String: CoreLogScalar]
    public let ts: String?

    public init(event: String, level: String, channel: String, op: String? = nil,
                fields: [String: CoreLogScalar], ts: String? = nil) {
        self.event = event; self.level = level; self.channel = channel
        self.op = op; self.fields = fields; self.ts = ts
    }
}
