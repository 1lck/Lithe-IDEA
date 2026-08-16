import Foundation

public enum ToolingJSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case object([String: ToolingJSONValue])
    case array([ToolingJSONValue])
    case null

    public var foundationObject: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .object(let value): value.mapValues(\.foundationObject)
        case .array(let value): value.map(\.foundationObject)
        case .null: NSNull()
        }
    }

    public static func fromFoundation(_ value: Any) -> ToolingJSONValue? {
        if value is NSNull { return .null }
        if let value = value as? String { return .string(value) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                return .integer(number.intValue)
            }
            return .number(double)
        }
        if let values = value as? [Any] { return .array(values.compactMap(fromFoundation)) }
        if let object = value as? [String: Any] {
            return .object(object.compactMapValues(fromFoundation))
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ToolingJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ToolingJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
