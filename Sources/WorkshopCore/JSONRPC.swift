import Foundation

/// Dynamic JSON value for JSON-RPC params/results.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        if case .number(let n) = self { return Int64(n) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// True when the object carries only the `via` provenance marker — the
    /// author label already conveys it, so no structured card is warranted.
    public var isViaOnly: Bool {
        if case .object(let o) = self { return !o.isEmpty && o.keys.allSatisfy { $0 == "via" } }
        return false
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Decode this value into a Codable type via JSON round-trip.
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Encode a Codable value into JSONValue.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public struct JSONRPCErrorObject: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String = "2.0"
    public var id: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCErrorObject?

    public init(id: JSONValue?, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: JSONValue?, error: JSONRPCErrorObject) {
        self.id = id
        self.error = error
    }
}

public struct JSONRPCNotification: Codable, Equatable, Sendable {
    public var jsonrpc: String = "2.0"
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}
