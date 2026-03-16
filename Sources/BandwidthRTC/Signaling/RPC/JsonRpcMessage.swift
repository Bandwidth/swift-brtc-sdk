import Foundation

// MARK: - JSON-RPC 2.0 Protocol Types

/// Outgoing JSON-RPC request (expects a response).
struct JsonRpcRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

/// Outgoing JSON-RPC notification (no response expected).
struct JsonRpcNotification<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: P

    enum CodingKeys: String, CodingKey {
        case jsonrpc, method, params
    }
}

/// Empty params for notifications/requests with no parameters.
struct EmptyParams: Codable {}

/// Incoming JSON-RPC response.
struct JsonRpcResponse: Decodable {
    let jsonrpc: String
    let id: String
    let result: AnyCodable?
    let error: JsonRpcError?
}

/// JSON-RPC error object.
struct JsonRpcError: Decodable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

/// Incoming JSON-RPC message (could be a response or server notification).
/// Used for initial routing before decoding the specific type.
struct JsonRpcIncoming: Decodable {
    let jsonrpc: String?
    let id: String?
    let method: String?
    let params: AnyCodable?
    let result: AnyCodable?
    let error: JsonRpcError?

    var isResponse: Bool { id != nil && method == nil }
    var isNotification: Bool { method != nil && id == nil }
}

// MARK: - AnyCodable (lightweight wrapper for arbitrary JSON)

struct AnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Cannot encode AnyCodable"))
        }
    }

    /// Decode the underlying value as a specific Decodable type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // JSONSerialization.data(withJSONObject:) only accepts arrays/dictionaries.
        // Wrap primitives in an array so they serialize, then decode the wrapper.
        if JSONSerialization.isValidJSONObject(value) {
            let data = try JSONSerialization.data(withJSONObject: value)
            return try JSONDecoder().decode(type, from: data)
        } else {
            let data = try JSONSerialization.data(withJSONObject: [value])
            return try JSONDecoder().decode([T].self, from: data)[0]
        }
    }
}
