import Foundation
import Darwin

/// Parser kept separate from execution so command safety can be tested without launching the app.
struct CLIInvocation {
    enum Action { case help, mcp, command, wait, watch }
    var action: Action = .command
    var json = false
    var appPath: String?
    var autoLaunch = true
    var method = ""
    var params: [String: Any] = [:]
    var timeout: TimeInterval = 600
    var interval: TimeInterval = 1

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var invocation = CLIInvocation()
        var args = arguments
        var filtered: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--json": invocation.json = true
            case "--no-launch": invocation.autoLaunch = false
            case "--help", "-h": invocation.action = .help; return invocation
            case "--app":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else { throw ControlError("USAGE", "--app requires a path") }
                index += 1; invocation.appPath = args[index]
            default: filtered.append(args[index])
            }
            index += 1
        }
        args = filtered
        guard let group = args.first else { invocation.action = .help; return invocation }
        if group == "help" { invocation.action = .help; return invocation }
        if group == "mcp" {
            guard args == ["mcp", "serve"] else { throw ControlError("USAGE", "Use mcp serve") }
            invocation.action = .mcp; return invocation
        }
        let subcommand = args.count > 1 ? args[1] : ""
        var rest: [String]
        if group == "capabilities" {
            invocation.method = "capabilities.get"; rest = Array(args.dropFirst())
        } else if group == "call" {
            guard !subcommand.isEmpty else { throw ControlError("USAGE", "call requires a wire method") }
            invocation.method = subcommand; rest = Array(args.dropFirst(2))
        } else {
            let mapping = [
                "app status": "app.status", "app quit": "app.quit",
                "download add": "downloads.enqueue", "download get": "downloads.get", "download list": "downloads.list",
                "download cancel": "downloads.cancel", "download retry": "downloads.retry", "download retry-errors": "downloads.retry_errors",
                "download wait": "downloads.get", "download watch": "downloads.get",
                "transcode add": "transcodes.enqueue", "settings get": "settings.get", "settings set": "settings.update", "settings reset": "settings.reset",
                "history remove": "history.remove", "history clear": "history.clear", "history clear-errors": "history.clear_errors",
                "file open": "files.open", "file reveal": "files.reveal", "file delete": "files.delete",
                "source get": "sources.get", "source copy": "sources.copy", "source open": "sources.open",
                "diagnostics report": "diagnostics.report", "diagnostics logs": "diagnostics.logs",
                "ui show": "ui.show", "ui settings": "ui.settings", "ui about": "ui.about", "ui hide": "ui.hide", "ui filter": "ui.set_filter"
            ]
            guard let method = mapping["\(group) \(subcommand)"] else { throw ControlError("USAGE", "Unknown command. Run link2download --help") }
            invocation.method = method
            if group == "download" && subcommand == "wait" { invocation.action = .wait }
            if group == "download" && subcommand == "watch" { invocation.action = .watch }
            rest = Array(args.dropFirst(2))
        }
        var flags: [String: String] = [:]
        var positional: [String] = []
        index = 0
        let booleanFlags: Set<String> = ["force", "smart-mode-enabled", "apple-transcode-enabled", "include-subtitles", "include-additional-audio-tracks"]
        while index < rest.count {
            let value = rest[index]
            if value == "--" { positional.append(contentsOf: rest.dropFirst(index + 1)); break }
            if value.hasPrefix("--") {
                let split = String(value.dropFirst(2)).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(split[0])
                let flagValue: String
                if split.count == 2 { flagValue = String(split[1]) }
                else if booleanFlags.contains(key) || (key.hasPrefix("no-") && booleanFlags.contains(String(key.dropFirst(3)))) {
                    if index + 1 < rest.count && ["true", "false"].contains(rest[index + 1]) { index += 1; flagValue = rest[index] }
                    else { flagValue = "true" }
                } else {
                    guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else { throw ControlError("USAGE", "--\(key) requires a value") }
                    index += 1; flagValue = rest[index]
                }
                guard flags[key] == nil else { throw ControlError("USAGE", "Duplicate flag --\(key)") }
                flags[key] = flagValue
            } else { positional.append(value) }
            index += 1
        }
        func pop(_ key: String) -> String? { flags.removeValue(forKey: key) }
        func jsonObject(_ text: String, label: String) throws -> [String: Any] {
            guard let bytes = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: bytes), let result = obj as? [String: Any] else {
                throw ControlError("USAGE", "\(label) requires a JSON object")
            }
            return result
        }
        if group == "call" {
            invocation.params = try pop("params").map { try jsonObject($0, label: "--params") } ?? [:]
        } else {
            func target(operationDefault: Bool = false) throws {
                if let id = pop("operation-id") { invocation.params["operationId"] = id }
                if let id = pop("id") {
                    guard invocation.params["operationId"] == nil else { throw ControlError("USAGE", "Use id or operation-id, not both") }
                    invocation.params["id"] = id
                }
                if !positional.isEmpty {
                    guard invocation.params.isEmpty else { throw ControlError("USAGE", "Specify one target") }
                    invocation.params[operationDefault ? "operationId" : "id"] = positional.removeFirst()
                }
            }
            let preferenceFlags = [
                "language": "language", "smart-mode-enabled": "smartModeEnabled", "apple-transcode-enabled": "appleTranscodeEnabled",
                "kind": "kind", "quality": "quality", "video-format": "videoFormat", "audio-format": "audioFormat",
                "save-directory": "saveDirectory", "speed-limit": "speedLimit", "transcode-bitrate": "transcodeBitrate",
                "cookie-source": "cookieSource", "include-subtitles": "includeSubtitles", "include-additional-audio-tracks": "includeAdditionalAudioTracks"
            ]
            func preferences() throws -> [String: Any] {
                var prefs: [String: Any] = [:]
                for (flag, property) in preferenceFlags {
                    let negative = pop("no-" + flag)
                    let positive = pop(flag)
                    guard negative == nil || (booleanFlags.contains(flag) && positive == nil) else { throw ControlError("USAGE", "Conflicting or invalid --no-\(flag)") }
                    guard var value = positive ?? negative else { continue }
                    if booleanFlags.contains(flag) {
                        guard value == "true" || value == "false" else { throw ControlError("USAGE", "--\(flag) requires true or false") }
                        prefs[property] = negative != nil ? value != "true" : value == "true"
                    } else {
                        if property == "quality" { value = ["720": "p720", "1080": "p1080", "4k": "p4k", "8k": "p8k", "quality1080": "p1080", "quality720": "p720"][value] ?? value }
                        if property == "speedLimit" && ["50", "25", "10", "4"].contains(value) { value = "mbps" + value }
                        if property == "transcodeBitrate" {
                            if value == "auto" { value = "autoHigh" }
                            else if ["6", "10", "16", "24", "35", "50", "80"].contains(value) { value = "mbps" + value }
                        }
                        if property == "saveDirectory" { value = NSString(string: value).expandingTildeInPath; if !value.hasPrefix("/") { value = URL(fileURLWithPath: value).standardizedFileURL.path } }
                        prefs[property] = value
                    }
                }
                return prefs
            }
            switch invocation.method {
            case "downloads.enqueue":
                guard !positional.isEmpty else { throw ControlError("USAGE", "download add requires URL") }
                invocation.params["url"] = positional.removeFirst()
                for key in ["playlist", "mode"] { if let value = pop(key) { invocation.params[key] = value } }
                if let value = pop("request-id") { invocation.params["requestId"] = value }
                var options = try pop("options").map { try jsonObject($0, label: "--options") } ?? [:]
                options.merge(try preferences()) { _, new in new }
                if !options.isEmpty { invocation.params["options"] = options }
            case "settings.update":
                var changes = try pop("changes").map { try jsonObject($0, label: "--changes") } ?? [:]
                changes.merge(try preferences()) { _, new in new }
                invocation.params["changes"] = changes
            case "downloads.get", "downloads.cancel", "history.remove":
                try target(operationDefault: invocation.action == .wait || invocation.action == .watch)
                if invocation.method == "downloads.get" {
                    for key in ["limit", "offset"] {
                        if let value = pop(key) { guard let number = Int(value) else { throw ControlError("USAGE", "--\(key) requires an integer") }; invocation.params[key] = number }
                    }
                }
            case "downloads.retry", "files.open", "files.reveal", "files.delete", "sources.get", "sources.copy", "sources.open", "transcodes.enqueue":
                try target()
                if invocation.method == "downloads.retry", let value = pop("preferences") { invocation.params["preferences"] = value }
                if invocation.method == "transcodes.enqueue" {
                    if let value = pop("request-id") { invocation.params["requestId"] = value }
                    var options = try pop("options").map { try jsonObject($0, label: "--options") } ?? [:]
                    options.merge(try preferences()) { _, new in new }
                    if !options.isEmpty { invocation.params["options"] = options }
                }
            case "downloads.retry_errors":
                if let value = pop("preferences") { invocation.params["preferences"] = value }
            case "downloads.list":
                for key in ["query", "status", "kind"] { if let value = pop(key) { invocation.params[key] = value } }
                for key in ["limit", "offset"] {
                    if let value = pop(key) { guard let num = Int(value) else { throw ControlError("USAGE", "--\(key) requires an integer") }; invocation.params[key] = num }
                }
            case "diagnostics.logs":
                if let value = pop("max-bytes") { guard let num = Int(value) else { throw ControlError("USAGE", "--max-bytes requires an integer") }; invocation.params["maxBytes"] = num }
            case "ui.set_filter":
                for key in ["query", "kind"] { if let value = pop(key) { invocation.params[key] = value } }
            case "app.quit":
                if let value = pop("force") { guard ["true", "false"].contains(value) else { throw ControlError("USAGE", "--force requires true or false") }; invocation.params["force"] = value == "true" }
            default: break
            }
            if invocation.action == .wait || invocation.action == .watch {
                if let value = pop("timeout") {
                    guard let number = Double(value), number.isFinite, number >= 0 else { throw ControlError("USAGE", "--timeout requires nonnegative seconds") }
                    invocation.timeout = number
                }
                if let value = pop("interval") {
                    guard let number = Double(value), number.isFinite, number >= 0.1, number <= 60 else { throw ControlError("USAGE", "--interval requires seconds between 0.1 and 60") }
                    invocation.interval = number
                }
            }
        }
        guard positional.isEmpty else { throw ControlError("USAGE", "Unexpected argument: \(positional[0])") }
        guard flags.isEmpty else { throw ControlError("USAGE", "Unknown flag: --\(flags.keys.sorted()[0])") }
        try ControlCatalog.validate(method: invocation.method, params: invocation.params)
        return invocation
    }
}

@main
struct Link2DownloadCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        var jsonErrors = args.contains("--json")
        do {
            let command = try CLIInvocation.parse(args)
            jsonErrors = command.json
            if command.action == .help { print(help); return }
            let client = ControlClient(appPath: command.appPath, autoLaunch: command.autoLaunch)
            if command.action == .mcp {
                // Initialize and tool discovery remain local; app launch occurs on first tool call.
                try MCPServer { method, params in try client.call(method: method, params: params) }.run()
                return
            }
            if command.action == .wait || command.action == .watch {
                let deadline = Date().addingTimeInterval(command.timeout)
                var previous: String?
                while true {
                    let response = try client.call(method: command.method, params: command.params)
                    if command.action == .watch {
                        let encoded = try ControlWire.string(response)
                        if encoded != previous { print(encoded); fflush(stdout); previous = encoded }
                    }
                    if response["terminal"] as? Bool == true && response["stopping"] as? Bool != true {
                        if command.action == .wait { try show(response, json: command.json) }
                        let records = response["records"] as? [[String: Any]] ?? []
                        let unsuccessful = response["failed"] as? Bool == true || records.contains { ["failed", "cancelled"].contains($0["status"] as? String ?? "") }
                        if unsuccessful { exit(1) }
                        return
                    }
                    guard Date() < deadline else { throw ControlError("WAIT_TIMEOUT", "Timed out waiting. The job continues; it was not cancelled.") }
                    Thread.sleep(forTimeInterval: min(command.interval, max(0, deadline.timeIntervalSinceNow)))
                }
            }
            try show(client.call(method: command.method, params: command.params), json: command.json)
        } catch {
            let failure = error as? ControlError ?? ControlError("INTERNAL_ERROR", error.localizedDescription)
            let line = jsonErrors ? ((try? ControlWire.string(["error": failure.object])) ?? "{\"error\":{\"code\":\"INTERNAL_ERROR\"}}") : "\(failure.code): \(failure.message)"
            FileHandle.standardError.write(Data((line + "\n").utf8))
            exit(failure.code == "USAGE" || failure.code == "INVALID_PARAMS" ? 2 : failure.code == "WAIT_TIMEOUT" ? 3 : 1)
        }
    }
    private static func show(_ object: [String: Any], json: Bool) throws {
        if json { print(try ControlWire.string(object)) }
        else { print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]), as: UTF8.self)) }
    }
    static let help = """
    Link2Download CLI — local control of the macOS application (macOS 12+)
    Usage: link2download [--json] [--app PATH] [--no-launch] COMMAND

    app status | app quit [--force]
    capabilities
    download add URL [--playlist single|all] [--mode smart|manual] [OPTIONS]
      [--request-id KEY] [--options JSON]
    download get ID | download get --operation-id UUID [--limit 1..500] [--offset N]
    download list [--query TEXT] [--status queued|downloading|completed|failed|cancelled]
      [--kind video|audio] [--limit 1..500] [--offset N]
    download cancel ID | download cancel --operation-id UUID
    download retry ID [--preferences current|original] | download retry-errors [--preferences current|original]
    download wait OPERATION_ID [--timeout SECONDS] [--interval 0.1..60]
    download watch OPERATION_ID [--timeout SECONDS] [--interval 0.1..60]
      wait/watch also accept --id RECORD_ID, --limit and --offset; watch emits NDJSON on changes.
      Record pages default to 100; terminal/failed summarize the complete operation.
      Default timeout 600 seconds; timeout never cancels the job.
    transcode add ID [--request-id KEY] [OPTIONS] [--options JSON]
    settings get | settings set [OPTIONS] [--changes JSON] | settings reset
    history remove ID | history remove --operation-id UUID | history clear | history clear-errors
    file open ID | file reveal ID | file delete ID
    source get ID | source copy ID | source open ID
    diagnostics report | diagnostics logs [--max-bytes 1000..180000]
    ui show | ui settings | ui about | ui hide | ui filter [--kind all|video|audio] [--query TEXT]
    call WIRE_METHOD [--params JSON]
    mcp serve

    OPTIONS (job-only for download add; persistent for settings set):
      --kind video|audio                   --quality best|720|1080|4k|8k
      --video-format mp4|mkv               --audio-format mp3|m4a|ogg
      --save-directory PATH               --speed-limit unlimited|50|25|10|4 (Mbit/s)
      --transcode-bitrate auto|6|10|16|24|35|50|80 (Mbit/s)
      --cookie-source auto|none|safari|chrome|comet|chromium|firefox|edge
      --language system|english|russian|hindi|chinese
      --smart-mode-enabled BOOL           --apple-transcode-enabled BOOL
      --include-subtitles BOOL            --include-additional-audio-tracks BOOL
      Boolean flags can omit true, or use --no-FLAG. Raw enum values are also accepted.
      Manual options disable Smart Mode unless explicitly contradicted (then rejected).

    Stdout: result JSON (--json: compact); MCP: JSON-RPC only; watch: NDJSON.
    Errors: stderr; --json emits a structured error. Exit: 0 success, 1 failure,
    2 invalid command/parameters, 3 wait timeout. Jobs survive CLI/MCP disconnection.
    """
}
