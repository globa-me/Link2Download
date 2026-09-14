import Foundation

@main
struct RetryHistoryRegression {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Link2Download-retry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore()
        settings.saveDirectory = directory.path
        let manager = DownloadManager(settings: settings, historyDirectory: directory)
        // Keep requests queued so this test cannot launch downloads or use the network.
        manager.activeDownloadID = UUID()
        manager.activeTranscodeID = UUID()
        let url = "https://www.youtube.com/watch?v=P8e-FfBFRTQ"
        let profile = settings.resolveProfile(for: url)
        func makeRecord(_ status: DownloadStatus) -> DownloadRecord {
            DownloadRecord(sourceURL: url, serviceName: "YouTube", title: "Existing title",
                durationSeconds: 100, status: status, progress: 0.4,
                downloadProgress: 0.4, statusMessage: "Old status", kind: profile.kind,
                qualityLabel: settings.label(for: profile.quality), outputFormat: profile.outputFormatLabel,
                filePath: "/stale/path", downloadedBytes: 1234, errorMessage: "Old error")
        }

        let failed = makeRecord(.failed)
        manager.records = [failed]
        manager.retry(recordID: failed.id)
        precondition(manager.records.count == 1 && manager.records[0].id == failed.id)
        precondition(manager.records[0].status == .queued)
        precondition(manager.records[0].progress == 0 && manager.records[0].errorMessage == nil)
        precondition(manager.records[0].filePath == nil && manager.records[0].downloadedBytes == nil)
        precondition(manager.records[0].title == failed.title && manager.records[0].createdAt == failed.createdAt)
        manager.enqueue(urlString: url)
        precondition(manager.records.count == 1)
        manager.removeRecord(failed.id)

        let cancelled = makeRecord(.cancelled)
        manager.records = [cancelled]
        manager.enqueue(urlString: url)
        precondition(manager.records.count == 1 && manager.records[0].id == cancelled.id)
        manager.removeRecord(cancelled.id)

        let stopping = makeRecord(.cancelled)
        manager.records = [stopping]
        manager.activeDownloadID = stopping.id
        manager.retry(recordID: stopping.id)
        manager.enqueue(urlString: url)
        precondition(manager.records.count == 1 && manager.records[0].status == .cancelled)
        manager.activeDownloadID = UUID()
        manager.records = []

        let completed = makeRecord(.completed)
        manager.records = [completed]
        manager.enqueue(urlString: url)
        precondition(manager.records.count == 2 && manager.records[0].status == .completed)
        manager.removeAll()

        var transcode = makeRecord(.failed)
        transcode.operationType = .transcodeCopy
        let sourceFile = directory.appendingPathComponent("source.mp4")
        try Data().write(to: sourceFile)
        transcode.transcodeSourcePath = sourceFile.path
        manager.records = [transcode]
        manager.retry(recordID: transcode.id)
        precondition(manager.records.count == 1 && manager.records[0].id == transcode.id)
        precondition(manager.records[0].status == .queued)
        print("PASS: retry/paste reuse history, active duplicate/cancellation protection, completed history preserved, transcode retry reuses row")
    }
}
