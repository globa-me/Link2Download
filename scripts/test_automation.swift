import Foundation

@main
struct AutomationRegression {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Link2Download-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "Link2Download.automation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var initial = DownloadPreferences.default()
        initial.saveDirectory = directory.appendingPathComponent("downloads").path
        defaults.set(try JSONEncoder().encode(initial), forKey: "link2download.preferences")
        let settings = SettingsStore(defaults: defaults)
        let manager = DownloadManager(settings: settings, historyDirectory: directory)
        // Keep workers occupied by harmless sentinels: tests must never execute
        // yt-dlp, ffmpeg, browser/keychain access, or real network downloads.
        manager.activeDownloadID = UUID()
        manager.activeTranscodeID = UUID()
        let controller = AutomationController(settings: settings, manager: manager)
        func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] { try controller.handle(method, params) }
        func expect(_ code: String, _ body: () throws -> Void) throws {
            do { try body(); throw TestFailure("Expected \(code)") }
            catch let error as ControlError { guard error.code == code else { throw TestFailure("Expected \(code), received \(error.code): \(error.message)") } }
        }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message) } }
        func operationID(_ response: [String: Any]) throws -> UUID {
            guard let raw = response["operationId"] as? String, let id = UUID(uuidString: raw) else { throw TestFailure("Missing operation ID") }
            return id
        }
        func record(_ id: UUID) throws -> DownloadRecord {
            guard let value = manager.records.first(where: { $0.id == id }) else { throw TestFailure("Missing record") }
            return value
        }

        let allChanges: [String: Any] = ["language": "russian", "smartModeEnabled": false, "appleTranscodeEnabled": false,
            "kind": "audio", "quality": "p1080", "videoFormat": "mkv", "audioFormat": "ogg",
            "saveDirectory": directory.appendingPathComponent("custom").path, "speedLimit": "mbps10",
            "transcodeBitrate": "mbps16", "cookieSource": "none", "includeSubtitles": true, "includeAdditionalAudioTracks": true]
        _ = try call("settings.update", ["changes": allChanges])
        let manual = settings.snapshot()
        let reloadedSettings = SettingsStore(defaults: defaults)
        try require(reloadedSettings.snapshot() == manual, "Atomic update must persist the complete final snapshot")
        let actual = try ControlWire.object(manual) as! [String: Any]
        try require(NSDictionary(dictionary: actual).isEqual(to: allChanges), "All 14 preference fields must be applied")
        try expect("INVALID_PARAMS") { _ = try call("settings.update", ["changes": ["quality": "4k"]]) }
        try expect("INVALID_PARAMS") { _ = try call("settings.update", ["changes": ["unknown": true]]) }
        try expect("INVALID_PARAMS") { _ = try call("settings.update", ["changes": ["smartModeEnabled": 1]]) }
        try expect("INVALID_DIRECTORY") { _ = try call("settings.update", ["changes": ["saveDirectory": "relative/path"]]) }
        try require(settings.snapshot() == manual, "Rejected updates must leave preferences unchanged")
        _ = try call("settings.update", ["changes": ["smartModeEnabled": true]])
        try require(settings.smartModeEnabled && settings.kind == .video && settings.quality == .best && settings.audioFormat == .m4a, "Smart mode resets its controlled fields")
        try require(settings.saveDirectory == manual.saveDirectory && settings.language == manual.language, "Smart mode preserves language and destination")
        try expect("SMART_MODE_CONFLICT") { _ = try call("settings.update", ["changes": ["smartModeEnabled": true, "kind": "audio"]]) }
        try expect("SMART_MODE_CONFLICT") { _ = try call("downloads.enqueue", ["url": "https://example.org/video", "mode": "manual", "options": ["smartModeEnabled": true]]) }
        try expect("SMART_MODE_CONFLICT") { _ = try call("downloads.enqueue", ["url": "https://example.org/video", "mode": "smart", "options": ["smartModeEnabled": false]]) }
        let beforeJob = settings.snapshot()
        let inputURL = "https://www.youtube.com/watch?v=P8e-FfBFRTQ"
        let jobParams: [String: Any] = ["url": inputURL, "mode": "manual", "requestId": "audio-request", "options": ["kind": "audio", "audioFormat": "m4a", "cookieSource": "none"]]
        let audioID = try operationID(call("downloads.enqueue", jobParams))
        let audio = try record(audioID)
        try require(audio.kind == .audio && audio.requestedPreferences?.smartModeEnabled == false && audio.outputFormat == "M4A", "Manual per-job overrides must resolve independently")
        try require(settings.snapshot() == beforeJob, "Enqueue must not modify global settings")
        let count = manager.records.count
        let duplicate = try operationID(call("downloads.enqueue", jobParams))
        try require(duplicate == audioID && manager.records.count == count, "A request ID must not enqueue twice")
        var conflicting = jobParams
        conflicting["options"] = ["kind": "video"]
        try expect("REQUEST_CONFLICT") { _ = try call("downloads.enqueue", conflicting) }
        _ = try call("settings.update", ["changes": ["language": "english"]])
        var localizedParams = jobParams
        localizedParams["options"] = ["kind": "audio", "audioFormat": "m4a", "cookieSource": "none", "language": "english"]
        let localizedDuplicate = try operationID(call("downloads.enqueue", localizedParams))
        try require(localizedDuplicate == audioID && manager.records.count == count, "Localization must not change operation identity")
        _ = try call("downloads.cancel", ["id": audioID.uuidString])
        _ = try call("settings.update", ["changes": ["speedLimit": "mbps4", "audioFormat": "mp3"]])
        let terminalDuplicate = try operationID(call("downloads.enqueue", jobParams))
        try require(terminalDuplicate == audioID && (try record(audioID)).status == .cancelled, "An idempotent terminal request must not restart work")
        manager.records[manager.records.firstIndex(where: { $0.id == audioID })!].errorCode = "PROCESS_FAILED"
        manager.records[manager.records.firstIndex(where: { $0.id == audioID })!].errorMessage = "Previous failure"
        _ = try call("downloads.retry", ["id": audioID.uuidString, "preferences": "current"])
        try require((try record(audioID)).errorCode == nil && (try record(audioID)).errorMessage == nil, "Retry must clear prior structured and displayed errors")
        try require((try record(audioID)).kind == .video, "Current retry must resolve current settings")
        let currentRetryDuplicate = try operationID(call("downloads.enqueue", ["url": inputURL]))
        try require(currentRetryDuplicate == audioID && manager.records.count == count, "Active duplicate matching must use current retry attempt, not immutable original preferences")
        try require((try record(audioID)).attemptPreferences == settings.snapshot() && (try record(audioID)).requestedPreferences == audio.requestedPreferences, "Current attempt and original request snapshots must remain separate")
        _ = try call("downloads.cancel", ["id": audioID.uuidString])
        _ = try call("downloads.retry", ["id": audioID.uuidString, "preferences": "original"])
        try require((try record(audioID)).kind == .audio, "Original retry must preserve initial per-job preferences")
        _ = try call("downloads.cancel", ["id": audioID.uuidString])
        manager.activeTranscodeID = audioID
        try expect("TASK_STOPPING") { _ = try call("downloads.retry", ["id": audioID.uuidString]) }
        let stopping = try call("downloads.get", ["id": audioID.uuidString])
        try require(stopping["stopping"] as? Bool == true && stopping["terminal"] as? Bool == false, "Stopping workers are not terminal")
        manager.activeTranscodeID = UUID()
        let stopped = try call("downloads.get", ["id": audioID.uuidString])
        try require(stopped["stopping"] as? Bool == false && stopped["terminal"] as? Bool == true, "Cancelled work is terminal after worker stops")
        try expect("INVALID_PARAMS") { _ = try call("downloads.get", ["id": "invalid"]) }
        try expect("INVALID_PARAMS") { _ = try call("downloads.get", ["id": audioID.uuidString, "operationId": audioID.uuidString]) }
        try expect("INVALID_PARAMS") { _ = try call("downloads.list", ["limit": 0]) }
        try expect("INVALID_PARAMS") { _ = try call("downloads.list", ["kind": "music"]) }
        try expect("INVALID_PARAMS") { _ = try call("downloads.enqueue", ["url": inputURL, "unsupported": true]) }
        try expect("INVALID_URL") { _ = try call("downloads.enqueue", ["url": "file:///tmp/private"]) }
        try expect("METHOD_NOT_FOUND") { _ = try call("unknown.method") }

        let subtitleParams: [String: Any] = ["url": inputURL + "&subtitle-fixture=1", "mode": "manual", "requestId": "subtitle-request",
            "options": ["includeSubtitles": true, "language": "english"]]
        _ = try call("downloads.enqueue", subtitleParams)
        var otherSubtitleParams = subtitleParams
        otherSubtitleParams["options"] = ["includeSubtitles": true, "language": "russian"]
        try expect("REQUEST_CONFLICT") { _ = try call("downloads.enqueue", otherSubtitleParams) }

        let playlistURL = inputURL + "&list=PL-example&index=2"
        try expect("PLAYLIST_CHOICE_REQUIRED") { _ = try call("downloads.enqueue", ["url": playlistURL]) }
        let singleID = try operationID(call("downloads.enqueue", ["url": " \(playlistURL) \n", "playlist": "single", "requestId": "single-video"]))
        let single = try record(singleID)
        try require(single.sourceURL == inputURL, "Single-video choice must remove playlist parameters and trim URL")
        let allID = try operationID(call("downloads.enqueue", ["url": playlistURL, "playlist": "all", "requestId": "whole-playlist"]))
        try require((try record(allID)).sourceURL.contains("list=PL-example"), "Playlist all must keep playlist identity")
        var child = try record(allID)
        child.id = UUID()
        child.requestID = nil
        child.operationID = allID
        manager.records.append(child)
        let grouped = try call("downloads.get", ["id": child.id.uuidString])
        try require(grouped["operationId"] as? String == allID.uuidString && (grouped["records"] as? [[String: Any]])?.count == 2, "Child lookup must return whole operation")
        if let rootIndex = manager.records.firstIndex(where: { $0.id == allID }) { manager.records[rootIndex].status = .completed }
        if let childIndex = manager.records.firstIndex(where: { $0.id == child.id }) { manager.records[childIndex].status = .failed }
        manager.activeTranscodeID = child.id
        let page = try call("downloads.get", ["operationId": allID.uuidString, "limit": 1, "offset": 0])
        try require((page["records"] as? [[String: Any]])?.count == 1 && page["recordCount"] as? Int == 2 && page["failed"] as? Bool == true && page["stopping"] as? Bool == true && page["terminal"] as? Bool == false, "Operation summary must include children outside the requested page")
        manager.activeTranscodeID = UUID()
        _ = try call("downloads.cancel", ["operationId": allID.uuidString])

        let sourcePath = directory.appendingPathComponent("source.mp4")
        try Data("fixture".utf8).write(to: sourcePath)
        var completed = DownloadRecord(sourceURL: inputURL, serviceName: "YouTube", title: "Fixture", durationSeconds: 10,
            status: .completed, progress: 1, statusMessage: "done", kind: .video, qualityLabel: "1080p", outputFormat: "MP4", filePath: sourcePath.path)
        let transcodeSourceID = completed.id
        manager.records.append(completed)
        let copyID = try operationID(call("transcodes.enqueue", ["id": completed.id.uuidString, "requestId": "mov-copy", "options": ["transcodeBitrate": "mbps24"]]))
        try require((try record(copyID)).requestedPreferences?.transcodeBitrate == .mbps24, "Transcode must accept bitrate override")
        try expect("FILE_IN_USE") { _ = try call("files.delete", ["id": completed.id.uuidString]) }
        _ = try call("downloads.cancel", ["id": copyID.uuidString])
        if let copyIndex = manager.records.firstIndex(where: { $0.id == copyID }) {
            // Successful transcodes release their source path after processing.
            manager.records[copyIndex].status = .completed
            manager.records[copyIndex].transcodeSourcePath = nil
        }
        let completedCopyReplay = try operationID(call("transcodes.enqueue", ["id": completed.id.uuidString, "requestId": "mov-copy", "options": ["transcodeBitrate": "mbps24"]]))
        try require(completedCopyReplay == copyID && (try record(copyID)).status == .completed, "A completed transcode must remain idempotent after releasing its source path")
        _ = try call("files.delete", ["id": completed.id.uuidString])
        let replayedCopyID = try operationID(call("transcodes.enqueue", ["id": completed.id.uuidString, "requestId": "mov-copy", "options": ["transcodeBitrate": "mbps24"]]))
        try require(replayedCopyID == copyID && (try record(copyID)).status == .completed, "Deleting a source file must not break transcode request replay or restart it")
        try require((try record(copyID)).transcodeSourceRecordID == completed.id, "Transcode input identity must be stored independently of the mutable file path")
        try expect("REQUEST_CONFLICT") { _ = try call("transcodes.enqueue", ["id": completed.id.uuidString, "requestId": "mov-copy", "options": ["transcodeBitrate": "mbps35"]]) }
        var otherSource = completed
        otherSource.id = UUID()
        manager.records.append(otherSource)
        try expect("REQUEST_CONFLICT") { _ = try call("transcodes.enqueue", ["id": otherSource.id.uuidString, "requestId": "mov-copy", "options": ["transcodeBitrate": "mbps24"]]) }
        _ = try call("history.remove", ["id": otherSource.id.uuidString])
        try Data("fixture".utf8).write(to: sourcePath)
        _ = try call("history.remove", ["id": completed.id.uuidString])
        try require(FileManager.default.fileExists(atPath: sourcePath.path), "Removing history must preserve files")
        completed.id = UUID()
        manager.records.append(completed)
        _ = try call("files.delete", ["id": completed.id.uuidString])
        try require(!FileManager.default.fileExists(atPath: sourcePath.path) && (try record(completed.id)).filePath == nil, "Deleting file must retain history without file path")

        let redacted = DiagnosticRedactor.redact("https://alice:password@example.org/video?token=secret#fragment https://second.example/a?signature=hidden")
        try require(!["alice", "password", "token", "secret", "fragment", "signature", "hidden"].contains(where: redacted.contains), "Diagnostics must remove URL credentials, query and fragment")
        try require(redacted.contains("example.org/video") && redacted.contains("second.example/a"), "Diagnostics should retain useful URL origins/paths")
        _ = try call("diagnostics.logs", ["maxBytes": 1000])

        try manager.flushHistory()
        let persisted = DownloadManager(settings: settings, historyDirectory: directory)
        persisted.activeDownloadID = UUID()
        persisted.activeTranscodeID = UUID()
        let savedCount = persisted.records.count
        try require(persisted.records.first(where: { $0.id == copyID })?.transcodeSourceRecordID == transcodeSourceID, "Transcode source identity must survive persistence")
        let savedID = try persisted.enqueueControlled(urlString: inputURL, preferences: audio.requestedPreferences!, requestID: "audio-request")
        try require(savedID == audioID && persisted.records.count == savedCount, "Idempotency must survive persistence and restart")
        try require(persisted.records.allSatisfy { $0.status != .queued && $0.status != .downloading }, "Restart must mark interrupted work failed without resuming")
        try persisted.flushHistory()
        let legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        var legacy = completed
        legacy.status = .downloading
        // History dates use Codable's reference-date numbers, unlike wire ISO8601.
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        for key in ["operationID", "requestID", "requestedPreferences", "resolvedProfile", "attemptPreferences", "attemptProfile", "errorCode", "transcodeSourceRecordID"] { oldObject.removeValue(forKey: key) }
        try ControlWire.data([oldObject]).write(to: legacyDirectory.appendingPathComponent("history.json"))
        let legacyManager = DownloadManager(settings: settings, historyDirectory: legacyDirectory)
        try require(legacyManager.records.count == 1 && legacyManager.records[0].status == .failed && legacyManager.records[0].requestedPreferences == nil && legacyManager.records[0].errorCode == "SESSION_INTERRUPTED", "Legacy history must decode and reconcile interrupted work")
        try legacyManager.flushHistory()
        print("PASS: automation settings, overrides, durable idempotency, retries, localization, grouping, stopping, playlists, files, diagnostics, validation and legacy history")
    }
    struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
