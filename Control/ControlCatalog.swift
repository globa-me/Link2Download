import Foundation
import CoreFoundation

struct ControlTool {
    let name: String
    let method: String
    let description: String
    let inputSchema: [String: Any]
    let readonly: Bool
    let destructive: Bool

    /// Results evolve additively; retain typed common fields and allow extra fields.
    /// Execution failures use the same output contract via the error alternative.
    var outputSchema: [String: Any] {
        let str: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let integer: [String: Any] = ["type": "integer"]
        let obj: [String: Any] = ["type": "object", "additionalProperties": true]
        let records: [String: Any] = ["type": "array", "items": obj]
        var properties: [String: Any] = [:]
        switch method {
        case "app.status": properties = ["apiVersion": integer, "appVersion": str, "appPath": str, "architecture": str, "minimumMacOS": str, "recordCount": integer, "queuedCount": integer, "visible": bool]
        case "app.quit": properties = ["quitting": bool]
        case "capabilities.get": properties = ["apiVersion": integer, "minimumMacOS": str, "methods": records, "singleActiveDownload": bool, "singleActiveTranscode": bool, "restartPolicy": str, "transport": str]
        case "downloads.enqueue", "downloads.get", "downloads.cancel", "downloads.retry", "transcodes.enqueue":
            properties = ["operationId": str, "records": records, "terminal": bool, "stopping": bool, "failed": bool, "recordCount": integer, "offset": integer, "limit": integer, "nextOffset": ["anyOf": [integer, ["type": "null"]]]]
        case "downloads.list": properties = ["records": records, "total": integer, "offset": integer, "limit": integer, "nextOffset": ["anyOf": [integer, ["type": "null"]]]]
        case "downloads.retry_errors": properties = ["operationIds": ["type": "array", "items": str], "retried": integer, "errors": records]
        case "settings.get", "settings.update", "settings.reset":
            properties = ["settings": ["type": "object", "properties": ControlCatalog.preferenceProperties, "required": ControlCatalog.preferenceProperties.keys.sorted(), "additionalProperties": true]]
        case "history.remove", "history.clear", "history.clear_errors": properties = ["removed": integer, "filesDeleted": bool]
        case "files.open", "files.reveal", "files.delete": properties = ["id": str, "path": str, "action": str]
        case "sources.get", "sources.copy", "sources.open": properties = ["id": str, "url": str]
        case "diagnostics.report": properties = ["report": str]
        case "diagnostics.logs": properties = ["logs": str]
        case "ui.set_filter": properties = ["kind": str, "query": str]
        case "ui.show", "ui.hide", "ui.settings", "ui.about": properties = ["action": str]
        default: break
        }
        let success: [String: Any] = ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": true]
        let failure: [String: Any] = ["type": "object", "properties": ["error": ["type": "object", "properties": ["code": str, "message": str], "required": ["code", "message"], "additionalProperties": true]], "required": ["error"], "additionalProperties": true]
        return ["type": "object", "anyOf": [success, failure]]
    }

    var mcpDefinition: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema, "outputSchema": outputSchema,
         "annotations": ["readOnlyHint": readonly, "destructiveHint": destructive,
                         "idempotentHint": readonly, "openWorldHint": ["downloads.enqueue", "sources.open", "files.open"].contains(method)]]
    }
}

/// Dependency-free contracts, shared by the app and macOS 12 CLI/MCP helper.
enum ControlCatalog {
    static func string(_ values: [String]? = nil, min: Int? = nil, max: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string"]
        if let values = values { schema["enum"] = values }
        if let min = min { schema["minLength"] = min }
        if let max = max { schema["maxLength"] = max }
        return schema
    }
    static let boolean: [String: Any] = ["type": "boolean"]
    static let uuid: [String: Any] = ["type": "string", "format": "uuid"]
    static func object(_ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    static let preferenceProperties: [String: Any] = [
        "language": string(["system", "english", "russian", "hindi", "chinese"]),
        "smartModeEnabled": boolean, "appleTranscodeEnabled": boolean,
        "kind": string(["video", "audio"]), "quality": string(["smart", "best", "p720", "p1080", "p4k", "p8k"]),
        "videoFormat": string(["mp4", "mkv"]), "audioFormat": string(["mp3", "m4a", "ogg"]),
        "saveDirectory": string(min: 1, max: 4096), "speedLimit": string(["unlimited", "mbps50", "mbps25", "mbps10", "mbps4"]),
        "transcodeBitrate": string(["autoHigh", "mbps6", "mbps10", "mbps16", "mbps24", "mbps35", "mbps50", "mbps80"]),
        "cookieSource": string(["auto", "none", "safari", "chrome", "comet", "chromium", "firefox", "edge"]),
        "includeSubtitles": boolean, "includeAdditionalAudioTracks": boolean
    ]
    static let tools: [ControlTool] = {
        func tool(_ method: String, _ description: String, _ schema: [String: Any] = object(), read: Bool = false, destructive: Bool = false) -> ControlTool {
            ControlTool(name: method.replacingOccurrences(of: ".", with: "_"), method: method,
                        description: description, inputSchema: schema, readonly: read, destructive: destructive)
        }
        let id = object(["id": uuid], required: ["id"])
        var target = object(["id": uuid, "operationId": uuid])
        target["oneOf"] = [["required": ["id"]], ["required": ["operationId"]]]
        var getTarget = object(["id": uuid, "operationId": uuid, "limit": ["type": "integer", "minimum": 1, "maximum": 500], "offset": ["type": "integer", "minimum": 0]])
        getTarget["oneOf"] = target["oneOf"]
        return [
            tool("app.status", "Read application and worker status.", read: true),
            tool("app.quit", "Quit Link2Download. Active work requires force=true.", object(["force": boolean]), destructive: true),
            tool("capabilities.get", "Read API version, commands, option enums and runtime capabilities.", read: true),
            tool("downloads.enqueue", "Enqueue a URL and return an operation ID immediately. Job options do not alter global settings. Specify playlist single or all for playlist URLs.", object(["url": string(min: 1, max: 8192), "playlist": string(["single", "all"]), "options": object(preferenceProperties), "mode": string(["smart", "manual"]), "requestId": string(min: 1, max: 200)], required: ["url"])),
            tool("downloads.get", "Read progress for a record ID or operation ID, including processing and terminal/stopping flags across all records. Paginates records (default 100, max 500).", getTarget, read: true),
            tool("downloads.list", "Search persisted history and queue. Pagination limit 1–500, offset >= 0.", object(["query": string(max: 1000), "status": string(["queued", "downloading", "completed", "failed", "cancelled"]), "kind": string(["video", "audio"]), "limit": ["type": "integer", "minimum": 1, "maximum": 500], "offset": ["type": "integer", "minimum": 0]]), read: true),
            tool("downloads.cancel", "Request cancellation for a record or entire operation; poll until stopping is false.", target),
            tool("downloads.retry", "Retry a failed or cancelled record with current settings (default) or original preferences.", object(["id": uuid, "preferences": string(["original", "current"])], required: ["id"])),
            tool("downloads.retry_errors", "Retry all eligible failed/cancelled records with current (default) or original preferences.", object(["preferences": string(["original", "current"])])),
            tool("transcodes.enqueue", "Create an Apple MOV copy of a completed video record. Returns immediately.", object(["id": uuid, "requestId": string(min: 1, max: 200), "options": object(preferenceProperties)], required: ["id"])),
            tool("settings.get", "Read persistent preferences.", read: true),
            tool("settings.update", "Atomically update persistent preferences. For per-job overrides use downloads_enqueue.options.", object(["changes": object(preferenceProperties)], required: ["changes"])),
            tool("settings.reset", "Reset persistent preferences to application defaults.", destructive: true),
            tool("history.remove", "Cancel/remove a record or operation from history. Downloaded files are retained.", target, destructive: true),
            tool("history.clear", "Cancel/remove all history records and return counts. Downloaded files are retained.", destructive: true),
            tool("history.clear_errors", "Remove failed/cancelled history records, stopping any lingering workers, and return counts. Downloaded files are retained.", destructive: true),
            tool("files.open", "Open a downloaded file in its associated application.", id),
            tool("files.reveal", "Show a downloaded file in Finder.", id),
            tool("files.delete", "Delete a downloaded file while keeping its history record.", id, destructive: true),
            tool("sources.get", "Get the source URL for a history record.", id, read: true),
            tool("sources.copy", "Copy a history record's source URL to the macOS clipboard.", id),
            tool("sources.open", "Open a history record's source URL in the browser.", id),
            tool("diagnostics.report", "Read application/runtime diagnostics without cookie values or credentials.", read: true),
            tool("diagnostics.logs", "Read a bounded, redacted recent log tail.", object(["maxBytes": ["type": "integer", "minimum": 1000, "maximum": 180000]]), read: true),
            tool("ui.show", "Show the application window."),
            tool("ui.settings", "Show the settings window."),
            tool("ui.about", "Show the About panel."),
            tool("ui.hide", "Hide application windows."),
            tool("ui.set_filter", "Change the visible GUI history filter/search.", object(["query": string(max: 1000), "kind": string(["all", "video", "audio"])]))
        ]
    }()
    static func tool(named name: String) -> ControlTool? { tools.first { $0.name == name } }
    static func tool(method: String) -> ControlTool? { tools.first { $0.method == method } }
    static func validate(method: String, params: [String: Any]) throws {
        guard let tool = tool(method: method) else { throw ControlError("METHOD_NOT_FOUND", "Unknown method: \(method)") }
        try validate(params, schema: tool.inputSchema, path: "params")
        if method == "downloads.get" || method == "downloads.cancel" || method == "history.remove" {
            guard (params["id"] != nil) != (params["operationId"] != nil) else {
                throw ControlError("INVALID_PARAMS", "Specify exactly one of id or operationId")
            }
        }
    }
    private static func validate(_ value: Any, schema: [String: Any], path: String) throws {
        func invalid(_ message: String) -> ControlError { ControlError("INVALID_PARAMS", "\(path): \(message)") }
        switch schema["type"] as? String {
        case "object":
            guard let obj = value as? [String: Any] else { throw invalid("expected object") }
            let props = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where obj[key] == nil { throw invalid("missing \(key)") }
            for (key, child) in obj {
                guard let childSchema = props[key] as? [String: Any] else { throw invalid("unknown field \(key)") }
                try validate(child, schema: childSchema, path: "\(path).\(key)")
            }
        case "string":
            guard let str = value as? String else { throw invalid("expected string") }
            if let min = schema["minLength"] as? Int, str.unicodeScalars.count < min { throw invalid("shorter than minimum length \(min)") }
            if let max = schema["maxLength"] as? Int, str.unicodeScalars.count > max { throw invalid("exceeds maximum length \(max)") }
            if let choices = schema["enum"] as? [String], !choices.contains(str) { throw invalid("expected one of \(choices.joined(separator: ", "))") }
            if schema["format"] as? String == "uuid", UUID(uuidString: str) == nil { throw invalid("expected UUID") }
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("expected boolean") }
        case "integer":
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue else { throw invalid("expected integer") }
            if let min = schema["minimum"] as? Int, n.doubleValue < Double(min) { throw invalid("below minimum \(min)") }
            if let max = schema["maximum"] as? Int, n.doubleValue > Double(max) { throw invalid("above maximum \(max)") }
        default: break
        }
    }
}
