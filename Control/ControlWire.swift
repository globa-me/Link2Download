import Foundation

/// Stable application errors shared by the app, CLI and MCP adapter (macOS 12+).
struct ControlError: Error, LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    var errorDescription: String? { message }
    var object: [String: Any] { ["code": code, "message": message] }
}

enum ControlWire {
    static let apiVersion = 1
    static let maxMessageBytes = 2_000_000

    static func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func string(_ object: Any) throws -> String {
        String(decoding: try data(object), as: UTF8.self)
    }
}
