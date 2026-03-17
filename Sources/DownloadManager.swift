import Foundation
import AppKit

@MainActor
final class DownloadManager: ObservableObject {
    @Published var records: [DownloadRecord] = []
    @Published var activeDownloadID: UUID?
    @Published var listFilter: ListFilter = .all
    @Published var searchQuery: String = ""
    @Published var toastMessage: String?

    private var queue: [QueuedRequest] = []
    private var workerTask: Task<Void, Never>?

    private let settings: SettingsStore
    private let service: YTDLPService
    private let historyFileURL: URL
    private let thumbnailsDirectoryURL: URL

    init(settings: SettingsStore, service: YTDLPService = YTDLPService()) {
        self.settings = settings
        self.service = service

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let appSupport = support.appendingPathComponent("Link2Download", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.historyFileURL = appSupport.appendingPathComponent("history.json")
        self.thumbnailsDirectoryURL = appSupport.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectoryURL, withIntermediateDirectories: true)

        loadHistory()
    }

    var filteredRecords: [DownloadRecord] {
        let source: [DownloadRecord]
        switch listFilter {
        case .all:
            source = records
        case .video:
            source = records.filter { $0.kind == .video }
        case .audio:
            source = records.filter { $0.kind == .audio }
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? source : source.filter { record in
            let pool = [
                record.title,
                record.serviceName,
                record.sourceURL,
                record.uploaderName ?? ""
            ]
            return pool.joined(separator: "\n").localizedCaseInsensitiveContains(query)
        }

        return filtered.sorted { $0.updatedAt > $1.updatedAt }
    }

    func enqueue(urlString: String) {
        let cleanURL = service.normalize(urlString: urlString)
        guard service.validate(urlString: cleanURL) else {
            toastMessage = settings.t("toast.invalidURL")
            return
        }

        let profile = settings.resolveProfile(for: cleanURL)
        let qualityLabel = settings.label(for: profile.quality)
        let formatLabel = profile.outputFormatLabel

        if let existingIndex = records.firstIndex(where: {
            $0.sourceURL == cleanURL &&
            ($0.status == .queued || $0.status == .downloading) &&
            $0.kind == profile.kind &&
            $0.qualityLabel == qualityLabel &&
            $0.outputFormat == formatLabel
        }) {
            records[existingIndex].updatedAt = Date()
            toastMessage = settings.t("toast.alreadyQueued")
            persistHistory()
            return
        }

        let preferences = settings.snapshot()
        let serviceName = service.inferServiceName(from: cleanURL)

        let record = DownloadRecord(
            sourceURL: cleanURL,
            serviceName: serviceName,
            title: cleanURL,
            durationSeconds: nil,
            status: .queued,
            progress: 0,
            statusMessage: settings.t("row.status.queued"),
            kind: profile.kind,
            qualityLabel: qualityLabel,
            outputFormat: formatLabel,
            processingStage: nil
        )

        records.append(record)
        queue.append(QueuedRequest(recordID: record.id, urlString: cleanURL, preferences: preferences, profile: profile))
        refreshQueuedStatuses()
        persistHistory()
        startNextIfNeeded()
    }

    func removeRecord(_ id: UUID) {
        if let record = records.first(where: { $0.id == id }),
           record.status == .queued || record.status == .downloading {
            cancel(recordID: id)
        }
        records.removeAll { $0.id == id }
        queue.removeAll { $0.recordID == id }
        refreshQueuedStatuses()
        persistHistory()
    }

    func removeAll() {
        if let activeDownloadID {
            service.cancel(taskID: activeDownloadID)
        }
        records.removeAll()
        queue.removeAll()
        refreshQueuedStatuses()
        persistHistory()
    }

    func retry(recordID: UUID) {
        guard let sourceURL = records.first(where: { $0.id == recordID })?.sourceURL else { return }
        enqueue(urlString: sourceURL)
    }

    func retryFailedAndCancelled() {
        let sourceURLs = records
            .filter { $0.status == .failed || $0.status == .cancelled }
            .map(\.sourceURL)

        for sourceURL in sourceURLs {
            enqueue(urlString: sourceURL)
        }
    }

    func removeFailedAndCancelled() {
        let ids = records
            .filter { $0.status == .failed || $0.status == .cancelled }
            .map(\.id)
        for id in ids {
            removeRecord(id)
        }
    }

    func cancel(recordID: UUID) {
        if activeDownloadID == recordID {
            service.cancel(taskID: recordID)
            updateRecord(recordID) { record in
                record.status = .cancelled
                record.statusMessage = settings.t("row.status.cancelled")
                record.errorMessage = nil
                record.processingStage = nil
                record.updatedAt = Date()
            }
            return
        }

        if let queueIndex = queue.firstIndex(where: { $0.recordID == recordID }) {
            queue.remove(at: queueIndex)
            updateRecord(recordID) { record in
                record.status = .cancelled
                record.statusMessage = settings.t("row.status.cancelled")
                record.errorMessage = nil
                record.processingStage = nil
                record.updatedAt = Date()
            }
            refreshQueuedStatuses()
        }
    }

    func deleteFile(for recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        guard let path = records[index].filePath else { return }

        do {
            try FileManager.default.removeItem(atPath: path)
            records[index].filePath = nil
            records[index].fileSizeBytes = nil
            records[index].statusMessage = settings.t("meta.noFile")
            records[index].updatedAt = Date()
            persistHistory()
        } catch {
            records[index].errorMessage = error.localizedDescription
            records[index].status = .failed
            records[index].updatedAt = Date()
            persistHistory()
        }
    }

    func openInFinder(recordID: UUID) {
        guard let path = records.first(where: { $0.id == recordID })?.filePath else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openFile(recordID: UUID) {
        guard let path = records.first(where: { $0.id == recordID })?.filePath else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func copySourceURL(recordID: UUID) {
        guard let sourceURL = records.first(where: { $0.id == recordID })?.sourceURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceURL, forType: .string)
    }

    func openSourceInBrowser(recordID: UUID) {
        guard let sourceURL = records.first(where: { $0.id == recordID })?.sourceURL,
              let url = URL(string: sourceURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func clearToast() {
        toastMessage = nil
    }

    private func startNextIfNeeded() {
        guard activeDownloadID == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        activeDownloadID = request.recordID
        updateRecord(request.recordID) { record in
            record.status = .downloading
            record.statusMessage = settings.t("progress.preparing")
            record.progress = 0.0
            record.processingStage = .preparing
            record.downloadedBytes = nil
            record.totalBytes = nil
            record.averageSpeedBytesPerSecond = nil
            record.fileSizeBytes = nil
            record.updatedAt = Date()
        }
        refreshQueuedStatuses()

        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(request)
        }
    }

    private func runDownload(_ request: QueuedRequest) async {
        do {
            let service = self.service
            let tools = try await runOffMain {
                try service.locateTools()
            }

            updateRecord(request.recordID) { record in
                record.statusMessage = settings.t("progress.downloading")
                record.processingStage = .downloading
                record.progress = max(record.progress, 0.01)
                record.updatedAt = Date()
            }

            let metadataLock = NSLock()
            var thumbnailFetchStarted = false

            let files = try await runOffMain {
                try service.download(
                    urlString: request.urlString,
                    profile: request.profile,
                    preferences: request.preferences,
                    tools: tools,
                    taskID: request.recordID,
                    onProgress: { [weak self] progress, message, transfer in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.updateRecord(request.recordID) { record in
                                if let progress {
                                    record.progress = max(0.0, min(progress, 1.0))
                                }
                                if let transfer {
                                    if let downloaded = transfer.downloadedBytes {
                                        record.downloadedBytes = max(record.downloadedBytes ?? 0, downloaded)
                                    }
                                    if let total = transfer.totalBytes {
                                        record.totalBytes = total
                                        record.fileSizeBytes = total
                                    }
                                    if let average = transfer.averageSpeedBytesPerSecond {
                                        record.averageSpeedBytesPerSecond = max(average, 0.0)
                                    }
                                }
                                if !message.isEmpty {
                                    record.statusMessage = self.localizedProgressMessage(message)
                                    if let stage = self.processingStage(from: message) {
                                        record.processingStage = stage
                                        if stage == .downloading {
                                            record.progress = max(record.progress, 0.01)
                                        }
                                    }
                                }
                                if progress == nil,
                                   let downloaded = record.downloadedBytes,
                                   let total = record.totalBytes,
                                   total > 0 {
                                    let rawFraction = Double(downloaded) / Double(total)
                                    let mappedMax = (request.preferences.smartModeEnabled && request.profile.kind == .video) ? 0.78 : 1.0
                                    let mappedFraction = min(max(rawFraction * mappedMax, 0.0), mappedMax)
                                    record.progress = max(record.progress, mappedFraction)
                                }
                                record.updatedAt = Date()
                            }
                        }
                    },
                    onMetadata: { [weak self] discovered in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.updateRecord(request.recordID) { record in
                                if let title = discovered.title, !title.isEmpty {
                                    record.title = title
                                }
                                if let duration = discovered.durationSeconds {
                                    record.durationSeconds = duration
                                }
                                if let serviceName = discovered.serviceName, !serviceName.isEmpty {
                                    record.serviceName = serviceName
                                }
                                if let uploader = discovered.uploaderName, !uploader.isEmpty {
                                    record.uploaderName = uploader
                                }
                                record.updatedAt = Date()
                            }
                        }

                        guard let thumbnailURL = discovered.thumbnailURL, !thumbnailURL.isEmpty else {
                            return
                        }

                        metadataLock.lock()
                        let shouldStartFetch = !thumbnailFetchStarted
                        if shouldStartFetch {
                            thumbnailFetchStarted = true
                        }
                        metadataLock.unlock()
                        guard shouldStartFetch else { return }

                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self else { return }
                            guard let thumbnailData = service.fetchThumbnailData(urlString: thumbnailURL) else { return }

                            Task { @MainActor in
                                guard let thumbnailPath = self.saveThumbnail(data: thumbnailData, recordID: request.recordID) else { return }
                                self.updateRecord(request.recordID) { record in
                                    if record.thumbnailPath == nil {
                                        record.thumbnailPath = thumbnailPath
                                    }
                                    record.updatedAt = Date()
                                }
                            }
                        }
                    }
                )
            }

            let subtitlesWarning: String?
            if request.profile.kind == .video && request.profile.includeSubtitles {
                subtitlesWarning = await runOffMain {
                    service.downloadSubtitlesOptional(
                        urlString: request.urlString,
                        preferences: request.preferences,
                        tools: tools,
                        taskID: request.recordID
                    )
                }
            } else {
                subtitlesWarning = nil
            }

            await handleCompletedFiles(files, for: request)

            if let subtitlesWarning, !subtitlesWarning.isEmpty {
                updateRecord(request.recordID) { record in
                    record.statusMessage = settings.t("warn.subtitlesPartial")
                    record.updatedAt = Date()
                }
            }
        } catch {
            if case DownloadError.cancelled = error {
                updateRecord(request.recordID) { record in
                    record.status = .cancelled
                    record.statusMessage = settings.t("row.status.cancelled")
                    record.errorMessage = nil
                    record.processingStage = nil
                    record.updatedAt = Date()
                }
            } else {
                updateRecord(request.recordID) { record in
                    record.status = .failed
                    record.statusMessage = settings.t("meta.failed")
                    record.errorMessage = self.userFriendlyErrorMessage(error, sourceURL: request.urlString)
                    record.processingStage = nil
                    record.updatedAt = Date()
                }

                if let downloadError = error as? DownloadError {
                    switch downloadError {
                    case .toolsMissing:
                        self.toastMessage = self.settings.t("toast.toolMissing")
                    default:
                        break
                    }
                }
            }
        }

        self.activeDownloadID = nil
        self.persistHistory()
        self.startNextIfNeeded()
    }

    private func handleCompletedFiles(_ files: [CompletedFile], for request: QueuedRequest) async {
        if files.isEmpty {
            updateRecord(request.recordID) { record in
                record.status = .completed
                record.progress = 1.0
                record.statusMessage = settings.t("row.status.completed")
                record.processingStage = nil
                record.averageSpeedBytesPerSecond = nil
                record.updatedAt = Date()
            }
            return
        }

        let first = files[0]
        updateRecord(request.recordID) { record in
            record.status = .completed
            record.progress = 1.0
            record.statusMessage = settings.t("row.status.completed")
            record.processingStage = nil
            record.filePath = first.path
            record.fileSizeBytes = first.fileSizeBytes
            record.downloadedBytes = first.fileSizeBytes
            record.totalBytes = first.fileSizeBytes
            record.averageSpeedBytesPerSecond = nil
            if let title = first.title, !title.isEmpty {
                record.title = title
            }
            if let duration = first.durationSeconds {
                record.durationSeconds = duration
            }
            if let ext = first.ext, !ext.isEmpty {
                record.outputFormat = ext.uppercased()
            }
            if let resolution = first.resolution, !resolution.isEmpty {
                record.qualityLabel = resolution
            }
            record.updatedAt = Date()
        }

        if files.count > 1 {
            let parentRecord = records.first(where: { $0.id == request.recordID })
            for file in files.dropFirst() {
                let extra = DownloadRecord(
                    sourceURL: request.urlString,
                    serviceName: service.inferServiceName(from: request.urlString),
                    title: file.title?.isEmpty == false ? file.title! : URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent,
                    durationSeconds: file.durationSeconds,
                    status: .completed,
                    progress: 1.0,
                    statusMessage: settings.t("row.status.completed"),
                    kind: request.profile.kind,
                    qualityLabel: file.resolution ?? settings.label(for: request.profile.quality),
                    outputFormat: (file.ext ?? request.profile.outputFormatLabel).uppercased(),
                    filePath: file.path,
                    fileSizeBytes: file.fileSizeBytes,
                    downloadedBytes: file.fileSizeBytes,
                    totalBytes: file.fileSizeBytes,
                    averageSpeedBytesPerSecond: nil,
                    uploaderName: parentRecord?.uploaderName,
                    thumbnailPath: parentRecord?.thumbnailPath,
                    errorMessage: nil,
                    processingStage: nil
                )
                self.records.append(extra)
            }
        }
    }

    private func userFriendlyErrorMessage(_ error: Error, sourceURL: String) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        let isVimeoSource = sourceURL.lowercased().contains("vimeo.com")
        let hasVimeo404Pattern =
            lower.contains("[vimeo]") &&
            (lower.contains("macos api json") || lower.contains("http error 404"))

        if isVimeoSource && hasVimeo404Pattern {
            return settings.t("error.vimeo.linkHint")
        }

        return raw
    }

    private func runOffMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOffMain<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private func updateRecord(_ id: UUID, mutate: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        mutate(&records[index])
        persistHistory()
    }

    private func localizedProgressMessage(_ raw: String) -> String {
        switch raw {
        case "__L2D_STATUS_PREPARING__":
            return settings.t("progress.preparing")
        case "__L2D_STATUS_DOWNLOADING__":
            return settings.t("progress.downloading")
        case "__L2D_STATUS_FINALIZING__":
            return settings.t("progress.finalizing")
        case "__L2D_STATUS_APPLE_OPTIMIZE__":
            return settings.t("progress.appleOptimize")
        case "__L2D_STATUS_APPLE_COPY__":
            return settings.t("progress.appleCopy")
        case "__L2D_STATUS_APPLE_HW_TRANSCODE__":
            return settings.t("progress.appleHWTranscode")
        case "__L2D_STATUS_APPLE_SW_TRANSCODE__":
            return settings.t("progress.appleSWTranscode")
        default:
            if raw.hasPrefix("__L2D_STATUS_ERROR__:") {
                return String(raw.dropFirst("__L2D_STATUS_ERROR__:".count))
            }
            return raw
        }
    }

    private func processingStage(from raw: String) -> DownloadProcessingStage? {
        switch raw {
        case "__L2D_STATUS_PREPARING__":
            return .preparing
        case "__L2D_STATUS_DOWNLOADING__":
            return .downloading
        case "__L2D_STATUS_FINALIZING__":
            return .remuxing
        case "__L2D_STATUS_APPLE_OPTIMIZE__", "__L2D_STATUS_APPLE_COPY__":
            return .remuxing
        case "__L2D_STATUS_APPLE_HW_TRANSCODE__":
            return .hardwareTranscode
        case "__L2D_STATUS_APPLE_SW_TRANSCODE__":
            return .softwareTranscode
        default:
            return nil
        }
    }

    private func refreshQueuedStatuses() {
        let positions = Dictionary(uniqueKeysWithValues: queue.enumerated().map { ($0.element.recordID, $0.offset + 1) })
        var changed = false

        for index in records.indices where records[index].status == .queued {
            let statusText: String
            if let position = positions[records[index].id] {
                statusText = "\(settings.t("row.status.queued")) #\(position)"
            } else {
                statusText = settings.t("row.status.queued")
            }

            if records[index].statusMessage != statusText {
                records[index].statusMessage = statusText
                changed = true
            }
        }

        if changed {
            persistHistory()
        }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
            return
        }
        records = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: historyFileURL, options: .atomic)
    }

    private func saveThumbnail(data: Data, recordID: UUID) -> String? {
        let fileURL = thumbnailsDirectoryURL.appendingPathComponent("\(recordID.uuidString).jpg")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private struct QueuedRequest {
        let recordID: UUID
        let urlString: String
        let preferences: DownloadPreferences
        let profile: ResolvedDownloadProfile
    }
}
