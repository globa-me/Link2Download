import Foundation
import CoreFoundation
import Darwin

/// A deliberately small MCP stdio transport using APIs available on macOS 12.
/// The app owns long-running jobs; closing/cancelling a request never cancels a download.
final class MCPServer {
    typealias Handler = (String, [String: Any]) throws -> [String: Any]
    static let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    private let handler: Handler
    private var initialized = false

    init(handler: @escaping Handler) { self.handler = handler }

    func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        var pending = Data()
        var oversized = false
        func emit(_ response: [String: Any]?) throws {
            guard let response = response else { return }
            var bytes = try ControlWire.data(response)
            bytes.append(0x0a)
            try output.write(contentsOf: bytes)
        }
        // FileHandle.read(upToCount:) waits to fill its buffer on macOS pipes;
        // POSIX read returns currently available bytes so a single request is answered
        // immediately while the client keeps stdin open.
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ControlError("MCP_IO_ERROR", "Cannot read MCP stdin") }
            if count == 0 { break }
            for byte in buffer.prefix(count) {
                if byte == 0x0a {
                    if oversized {
                        try emit(error(id: NSNull(), code: -32700, message: "Message exceeds maximum size"))
                    } else if !pending.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) {
                        try emit(respond(to: pending))
                    }
                    pending.removeAll(keepingCapacity: true)
                    oversized = false
                } else if !oversized {
                    if pending.count >= ControlWire.maxMessageBytes {
                        pending.removeAll(keepingCapacity: true)
                        oversized = true
                    } else { pending.append(byte) }
                }
            }
        }
        if oversized { try emit(error(id: NSNull(), code: -32700, message: "Message exceeds maximum size")) }
        else if !pending.isEmpty { try emit(respond(to: pending)) }
    }

    /// Kept transport independent so protocol behavior can be tested without an app.
    func respond(to data: Data) -> [String: Any]? {
        let decoded: Any
        do { decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { return self.error(id: NSNull(), code: -32700, message: "Parse error") }
        guard let message = decoded as? [String: Any] else {
            return error(id: NSNull(), code: -32600, message: "Expected a JSON-RPC object (batch requests are unsupported)")
        }
        return respond(to: message)
    }

    func respond(to message: [String: Any]) -> [String: Any]? {
        let hasID = message.keys.contains("id")
        let requestID = message["id"] ?? NSNull()
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String,
              !hasID || validID(requestID) else {
            return error(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request")
        }
        // JSON-RPC notifications never receive a response, even if unknown or malformed.
        if !hasID {
            // notifications/initialized and notifications/cancelled need no app action.
            // Cancellation is request-scoped; use downloads_cancel to stop accepted jobs.
            return nil
        }
        if let params = message["params"], !(params is [String: Any]) {
            return error(id: requestID, code: -32602, message: "params must be an object")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard !initialized else { return error(id: requestID, code: -32600, message: "Already initialized") }
            guard let requested = params["protocolVersion"] as? String,
                  params["capabilities"] is [String: Any],
                  let client = params["clientInfo"] as? [String: Any], client["name"] is String, client["version"] is String else {
                return error(id: requestID, code: -32602, message: "initialize requires protocolVersion, capabilities and clientInfo name/version")
            }
            initialized = true
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions.last!
            return result(id: requestID, ["protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "link2download", "version": "1.0.0"],
                "instructions": "Control the local Link2Download app. Enqueue returns immediately. Poll downloads_get until terminal is true and stopping is false. Closing MCP does not stop downloads. File deletion and history removal are separate operations. Job options do not alter persistent settings."])
        case "ping": return result(id: requestID, [:])
        case "tools/list":
            guard initialized else { return error(id: requestID, code: -32002, message: "Initialize first") }
            if params["cursor"] != nil { return error(id: requestID, code: -32602, message: "This tool list has no pagination cursor") }
            return result(id: requestID, ["tools": ControlCatalog.tools.map { $0.mcpDefinition }])
        case "tools/call":
            guard initialized else { return error(id: requestID, code: -32002, message: "Initialize first") }
            guard let name = params["name"] as? String, let tool = ControlCatalog.tool(named: name) else {
                return error(id: requestID, code: -32602, message: "Unknown or missing tool name")
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(id: requestID, code: -32602, message: "arguments must be an object")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                try ControlCatalog.validate(method: tool.method, params: args)
                return result(id: requestID, try toolResult(handler(tool.method, args), failed: false))
            } catch let failure as ControlError {
                return result(id: requestID, (try? toolResult(["error": failure.object], failed: true)) ?? [:])
            } catch {
                return result(id: requestID, (try? toolResult(["error": ["code": "INTERNAL_ERROR", "message": error.localizedDescription]], failed: true)) ?? [:])
            }
        default: return error(id: requestID, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func toolResult(_ object: [String: Any], failed: Bool) throws -> [String: Any] {
        ["content": [["type": "text", "text": try ControlWire.string(object)]],
         "structuredContent": object, "isError": failed]
    }
    private func validID(_ id: Any) -> Bool {
        if id is String { return true }
        guard let n = id as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
        return n.doubleValue.isFinite && n.doubleValue.rounded() == n.doubleValue
    }
    private func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }
    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
