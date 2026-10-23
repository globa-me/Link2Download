import Foundation
import AppKit

@MainActor
final class AutomationController {
    let settings: SettingsStore
    let manager: DownloadManager
    var presentUI: ((String) -> Void)?
    var quit: (() -> Void)?
    private var stopping = false

    init(settings: SettingsStore, manager: DownloadManager) {
        self.settings = settings
        self.manager = manager
    }

    func handle(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try ControlCatalog.validate(method: method, params: params)
        guard !stopping else { throw ControlError("APP_STOPPING", "The application is shutting down.") }
        switch method {
        case "app.status":
            return ["apiVersion": ControlWire.apiVersion, "appVersion": AppBuildInfo.displayVersion,
                    "appPath": Bundle.main.bundleURL.path, "architecture": AppDiagnostics.runtimeArchitecture,
                    "minimumMacOS": "12.0", "activeDownloadId": manager.activeDownloadID?.uuidString as Any? ?? NSNull(),
                    "activeTranscodeId": manager.activeTranscodeID?.uuidString as Any? ?? NSNull(),
                    "recordCount": manager.records.count, "queuedCount": manager.records.filter { $0.status == .queued }.count,
                    "visible": NSApp?.windows.contains(where: \.isVisible) ?? false]
        case "capabilities.get":
            return ["apiVersion": ControlWire.apiVersion, "minimumMacOS": "12.0",
                    "methods": ControlCatalog.tools.map { ["method": $0.method, "tool": $0.name, "inputSchema": $0.inputSchema] },
                    "singleActiveDownload": true, "singleActiveTranscode": true,
                    "restartPolicy": "mark_interrupted_failed", "transport": "local_unix_socket"]
        case "settings.get": return ["settings": try ControlWire.object(settings.snapshot())]
        case "settings.update":
            let preferences = try updatedPreferences(params["changes"] as? [String: Any] ?? [:])
            settings.apply(preferences)
            return ["settings": try ControlWire.object(settings.snapshot())]
        case "settings.reset":
            settings.resetDefaults()
            return ["settings": try ControlWire.object(settings.snapshot())]
        case "downloads.enqueue":
            guard let input = params["url"] as? String else { throw ControlError("INVALID_PARAMS", "url is required.") }
            let mode = params["mode"] as? String
            let replayPreferences = (params["requestId"] as? String).flatMap { requestID in
                manager.records.first { $0.requestID == requestID }?.requestedPreferences
            }
            let preferences = try updatedPreferences(params["options"] as? [String: Any] ?? [:], mode: mode, base: replayPreferences)
            var url = input
            let playlist = params["playlist"] as? String
            let components = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))
            let hasPlaylist = components?.queryItems?.contains { $0.name.lowercased() == "list" } == true
            if hasPlaylist && playlist == nil {
                throw ControlError("PLAYLIST_CHOICE_REQUIRED", "Specify playlist=single or playlist=all for a playlist URL.")
            }
            if playlist == "single", hasPlaylist {
                guard let choice = manager.playlistPromptContextIfNeeded(for: input) else {
                    throw ControlError("INVALID_PARAMS", "This URL does not identify a single playlist video. Supply a video URL or playlist=all.")
                }
                url = choice.singleVideoURL
            }
            let id = try manager.enqueueControlled(urlString: url, preferences: preferences, requestID: params["requestId"] as? String)
            try manager.flushHistory()
            var result = try operationSnapshot(id)
            result["effectivePreferences"] = try ControlWire.object(preferences)
            result["resolvedProfile"] = try ControlWire.object(SettingsStore.resolveProfile(for: url, preferences: preferences))
            return result
        case "downloads.get": return try operationSnapshot(resolveOperationID(params), offset: params["offset"] as? Int ?? 0, limit: params["limit"] as? Int ?? 100)
        case "downloads.list":
            let query = (params["query"] as? String ?? "").lowercased()
            let status = params["status"] as? String
            let kind = params["kind"] as? String
            let filtered = manager.records.filter { record in
                (status == nil || record.status.rawValue == status) &&
                (kind == nil || kind == "all" || record.kind.rawValue == kind) &&
                (query.isEmpty || [record.title, record.sourceURL, record.serviceName, record.uploaderName ?? ""].joined(separator: "\n").lowercased().contains(query))
            }.sorted { $0.updatedAt > $1.updatedAt }
            let offset = params["offset"] as? Int ?? 0
            let limit = params["limit"] as? Int ?? 50
            return ["records": try ControlWire.object(Array(filtered.dropFirst(offset).prefix(limit))), "total": filtered.count,
                    "offset": offset, "limit": limit, "nextOffset": offset + limit < filtered.count ? offset + limit as Any : NSNull()]
        case "downloads.cancel":
            let targets = try selectedRecords(params)
            for record in targets { manager.cancel(recordID: record.id) }
            try manager.flushHistory()
            return try operationSnapshot(targets[0].operationID ?? targets[0].id)
        case "downloads.retry":
            let record = try findRecord(params)
            let id = try manager.retryControlled(recordID: record.id, useOriginalPreferences: params["preferences"] as? String == "original")
            try manager.flushHistory()
            return try operationSnapshot(id)
        case "downloads.retry_errors":
            var ids: [String] = [], failures: [[String: Any]] = []
            let targets = manager.records.filter { $0.status == .failed || $0.status == .cancelled }
            for record in targets {
                do { ids.append(try manager.retryControlled(recordID: record.id, useOriginalPreferences: params["preferences"] as? String == "original").uuidString) }
                catch { let failure = error as? ControlError ?? ControlError("INTERNAL_ERROR", error.localizedDescription); failures.append(["id": record.id.uuidString, "error": failure.object]) }
            }
            try manager.flushHistory()
            return ["operationIds": ids, "retried": ids.count, "errors": failures]
        case "transcodes.enqueue":
            let record = try findRecord(params)
            let replayPreferences = (params["requestId"] as? String).flatMap { requestID in
                manager.records.first { $0.requestID == requestID }?.requestedPreferences
            }
            let preferences = try updatedPreferences(params["options"] as? [String: Any] ?? [:], base: replayPreferences)
            let id = try manager.enqueueTranscodeControlled(recordID: record.id, preferences: preferences, requestID: params["requestId"] as? String)
            try manager.flushHistory()
            return try operationSnapshot(id)
        case "history.remove":
            let targets = try selectedRecords(params)
            for record in targets { manager.removeRecord(record.id) }
            try manager.flushHistory()
            return ["removed": targets.count, "filesDeleted": false]
        case "history.clear":
            let count = manager.records.count
            manager.removeAll()
            try manager.flushHistory()
            return ["removed": count, "filesDeleted": false]
        case "history.clear_errors":
            let count = manager.records.filter { $0.status == .failed || $0.status == .cancelled }.count
            manager.removeFailedAndCancelled()
            try manager.flushHistory()
            return ["removed": count, "filesDeleted": false]
        case "files.open", "files.reveal", "files.delete":
            let record = try findRecord(params)
            guard let path = record.filePath, FileManager.default.fileExists(atPath: path) else {
                throw ControlError("FILE_MISSING", "The downloaded file does not exist.")
            }
            if method == "files.delete" {
                guard !manager.records.contains(where: { candidate in
                    (candidate.status == .queued || candidate.id == manager.activeDownloadID || candidate.id == manager.activeTranscodeID) &&
                    (candidate.filePath == path || candidate.transcodeSourcePath == path)
                }) else { throw ControlError("FILE_IN_USE", "The file is still used by a download or transcode.") }
                manager.deleteFile(for: record.id)
                guard manager.records.first(where: { $0.id == record.id })?.filePath == nil else {
                    throw ControlError("FILE_DELETE_FAILED", "The file could not be deleted.")
                }
                try manager.flushHistory()
            } else if method == "files.open" {
                guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else { throw ControlError("OPEN_FAILED", "macOS could not open the file.") }
            } else { manager.openInFinder(recordID: record.id) }
            return ["id": record.id.uuidString, "path": path, "action": String(method.dropFirst(6))]
        case "sources.get", "sources.copy", "sources.open":
            let record = try findRecord(params)
            if method == "sources.copy" {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(record.sourceURL, forType: .string) else { throw ControlError("CLIPBOARD_FAILED", "Cannot write to the clipboard.") }
            } else if method == "sources.open" {
                guard let url = URL(string: record.sourceURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), NSWorkspace.shared.open(url) else {
                    throw ControlError("OPEN_FAILED", "macOS could not open the source URL.")
                }
            }
            return ["id": record.id.uuidString, "url": record.sourceURL]
        case "diagnostics.report": return ["report": DiagnosticRedactor.redact(manager.buildDebugReport())]
        case "diagnostics.logs":
            return ["logs": DiagnosticRedactor.redact(AppDiagnostics.shared.readTail(maxBytes: params["maxBytes"] as? Int ?? 50_000))]
        case "ui.set_filter":
            if let kind = params["kind"] as? String, let filter = ListFilter(rawValue: kind) { manager.listFilter = filter }
            if let query = params["query"] as? String { manager.searchQuery = query }
            return ["kind": manager.listFilter.rawValue, "query": manager.searchQuery]
        case "ui.show", "ui.hide", "ui.settings", "ui.about":
            presentUI?(String(method.dropFirst(3)))
            return ["action": method]
        case "app.quit":
            guard params["force"] as? Bool == true || !hasTasks else {
                throw ControlError("TASKS_ACTIVE", "Downloads or transcodes are pending. Use force=true to cancel them and quit.")
            }
            stopping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.quit?() }
            return ["quitting": true]
        default: throw ControlError("METHOD_NOT_FOUND", "Unknown control method.")
        }
    }

    var hasTasks: Bool {
        manager.activeDownloadID != nil || manager.activeTranscodeID != nil || manager.records.contains { $0.status == .queued }
    }

    func beginShutdown() { stopping = true }

    func operationSnapshot(_ id: UUID, offset: Int = 0, limit: Int = 100) throws -> [String: Any] {
        let records = manager.operationRecords(id)
        guard !records.isEmpty else { throw ControlError("RECORD_NOT_FOUND", "No operation with this ID exists.") }
        let busy = records.contains { $0.id == manager.activeDownloadID || $0.id == manager.activeTranscodeID }
        let stopping = busy && records.contains { $0.status == .cancelled || $0.status == .failed }
        let terminal = !busy && records.allSatisfy { [.completed, .failed, .cancelled].contains($0.status) }
        return ["operationId": id.uuidString, "records": try ControlWire.object(Array(records.dropFirst(offset).prefix(limit))), "terminal": terminal,
                "recordCount": records.count, "offset": offset, "limit": limit,
                "nextOffset": offset + limit < records.count ? offset + limit as Any : NSNull(),
                "stopping": stopping, "failed": records.contains { $0.status == .failed || $0.status == .cancelled }]
    }

    private func findRecord(_ params: [String: Any]) throws -> DownloadRecord {
        guard let raw = params["id"] as? String, let id = UUID(uuidString: raw) else { throw ControlError("INVALID_PARAMS", "id must be a record UUID.") }
        guard let record = manager.records.first(where: { $0.id == id }) else { throw ControlError("RECORD_NOT_FOUND", "No record with this ID exists.") }
        return record
    }

    private func resolveOperationID(_ params: [String: Any]) throws -> UUID {
        if let raw = params["operationId"] as? String {
            guard let id = UUID(uuidString: raw) else { throw ControlError("INVALID_PARAMS", "operationId must be a UUID.") }
            return id
        }
        let record = try findRecord(params)
        return record.operationID ?? record.id
    }

    private func selectedRecords(_ params: [String: Any]) throws -> [DownloadRecord] {
        if params["operationId"] != nil {
            let records = manager.operationRecords(try resolveOperationID(params))
            guard !records.isEmpty else { throw ControlError("RECORD_NOT_FOUND", "No operation with this ID exists.") }
            return records
        }
        return [try findRecord(params)]
    }

    private func updatedPreferences(_ changes: [String: Any], mode: String? = nil, base: DownloadPreferences? = nil) throws -> DownloadPreferences {
        var merged = try ControlWire.object(base ?? settings.snapshot()) as! [String: Any]
        if let mode, let explicit = changes["smartModeEnabled"] as? Bool,
           explicit != (mode == "smart") {
            throw ControlError("SMART_MODE_CONFLICT", "mode and smartModeEnabled specify contradictory modes.")
        }
        let manualKeys: Set<String> = ["kind", "quality", "videoFormat", "audioFormat", "speedLimit", "cookieSource", "includeSubtitles", "includeAdditionalAudioTracks"]
        let smart = mode == "smart" || changes["smartModeEnabled"] as? Bool == true
        if smart && !manualKeys.isDisjoint(with: changes.keys) {
            throw ControlError("SMART_MODE_CONFLICT", "Use manual mode when overriding kind, quality, formats, speed, cookies, subtitles or audio tracks.")
        }
        if smart {
            let defaults = try ControlWire.object(DownloadPreferences.default()) as! [String: Any]
            for key in manualKeys.union(["appleTranscodeEnabled", "transcodeBitrate", "smartModeEnabled"]) { merged[key] = defaults[key] }
        } else if mode == "manual" || !manualKeys.isDisjoint(with: changes.keys) { merged["smartModeEnabled"] = false }
        for (key, value) in changes { merged[key] = value }
        if mode == "manual" { merged["smartModeEnabled"] = false }
        let result: DownloadPreferences
        do { result = try JSONDecoder().decode(DownloadPreferences.self, from: ControlWire.data(merged)) }
        catch { throw ControlError("INVALID_PARAMS", "Invalid settings value: \(error.localizedDescription)") }
        var preferences = result
        preferences.saveDirectory = NSString(string: result.saveDirectory).expandingTildeInPath
        guard preferences.saveDirectory.hasPrefix("/"), !preferences.saveDirectory.contains("\0") else {
            throw ControlError("INVALID_DIRECTORY", "saveDirectory must be an absolute path.")
        }
        do {
            try FileManager.default.createDirectory(atPath: preferences.saveDirectory, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: preferences.saveDirectory) else { throw ControlError("INVALID_DIRECTORY", "The save directory is not writable.") }
        } catch { throw ControlError("INVALID_DIRECTORY", "Cannot use the save directory: \(error.localizedDescription)") }
        return preferences
    }
}
