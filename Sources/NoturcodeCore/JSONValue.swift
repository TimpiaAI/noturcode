import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public func firstString(for keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue { return value }
        }
        return nil
    }

    public func value(at path: [String]) -> JSONValue? {
        path.reduce(Optional(self)) { value, key in value?[key] }
    }

    public func firstString(at paths: [[String]]) -> String? {
        for path in paths {
            if let value = value(at: path)?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    public func recursivelySummedTokens() -> Int? {
        let tokenKeys: Set<String> = [
            "input_tokens", "output_tokens", "cached_input_tokens",
            "cache_creation_input_tokens", "cache_read_input_tokens"
        ]

        func walk(_ value: JSONValue) -> Int {
            switch value {
            case let .object(object):
                return object.reduce(into: 0) { total, pair in
                    if tokenKeys.contains(pair.key), let amount = pair.value.intValue {
                        total += amount
                    } else {
                        total += walk(pair.value)
                    }
                }
            case let .array(array):
                return array.reduce(0) { $0 + walk($1) }
            default:
                return 0
            }
        }

        let total = walk(self)
        return total > 0 ? total : nil
    }
}
