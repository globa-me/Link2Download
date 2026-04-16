import Foundation
import AppKit

@MainActor
final class DownloadManager: ObservableObject {
    @Published var records: [DownloadRecord] = []
    @Published var activeDownloadID: UUID?
    @Published var activeTranscodeID: UUID?
    @Published var listFilter: ListFilter = .all
    @Published var searchQuery: String = ""
    @Published var toastMessage: String?

    struct PlaylistPromptContext {
        let originalURL: String
        let singleVideoURL: String
    }

    private var downloadQueue: [QueuedDownloadRequest] = []
    private var transcodeQueue: [QueuedTranscodeRequest] = []
    private var downloadWorkerTask: Task<Void, Never>?
    private var transcodeWorkerTask: Task<Void, Never>?

    private let settings: SettingsStore
    private let service: YTDLPService
    private let diagnostics = AppDiagnostics.shared
    private let historyFileURL: URL
    private let thumbnailsDirectoryURL: URL
    private let historyPersistenceQueue = DispatchQueue(label: "Link2Download.DownloadManager.history", qos: .utility)
    private var pendingHistoryPersistWorkItem: DispatchWorkItem?

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
            diagnostics.log(.warning, "Rejected invalid URL from clipboard/input")
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
            diagnostics.log(.info, "Skipped duplicate enqueue for active item: \(cleanURL)")
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
            downloadProgress: 0.0,
            processingProgress: nil,
            statusMessage: settings.t("row.status.queued"),
            kind: profile.kind,
            qualityLabel: qualityLabel,
            outputFormat: formatLabel,
            processingStage: nil
        )

        records.append(record)
        diagnostics.log(
            .info,
            "Enqueued download; id=\(record.id.uuidString) kind=\(profile.kind.rawValue) quality=\(profile.quality.rawValue) format=\(formatLabel) smart=\(preferences.smartModeEnabled)"
        )
        downloadQueue.append(
            QueuedDownloadRequest(
                recordID: record.id,
                urlString: cleanURL,
                preferences: preferences,
                profile: profile
            )
        )
        refreshQueuedStatuses()
        persistHistory()
        startNextDownloadIfNeeded()
    }

    func enqueueTranscodeCopy(recordID: UUID) {
        guard let sourceRecord = records.first(where: { $0.id == recordID }) else { return }
        guard sourceRecord.kind == .video else {
            toastMessage = settings.t("toast.transcodeVideoOnly")
            return
        }
        guard let sourcePath = sourceRecord.filePath,
              FileManager.default.fileExists(atPath: sourcePath) else {
            toastMessage = settings.t("toast.transcodeSourceMissing")
            return
        }

        if sourceRecord.status == .queued || sourceRecord.status == .downloading {
            toastMessage = settings.t("toast.alreadyQueued")
            return
        }

        enqueueTranscodeCopy(sourceRecord: sourceRecord, sourcePath: sourcePath)
    }

    func playlistPromptContextIfNeeded(for urlString: String) -> PlaylistPromptContext? {
        let cleanURL = service.normalize(urlString: urlString)
        guard let components = URLComponents(string: cleanURL),
              let host = components.host?.lowercased(),
              isYouTubeHost(host),
              hasPlaylistQuery(in: components),
              isLikelySingleVideoURL(components) else {
            return nil
        }

        var singleVideoComponents = components
        let filteredQueryItems = (components.queryItems ?? []).filter { item in
            let key = item.name.lowercased()
            return key != "list" && key != "index" && key != "start_radio"
        }
        singleVideoComponents.queryItems = filteredQueryItems.isEmpty ? nil : filteredQueryItems

        guard let singleVideoURL = singleVideoComponents.url?.absoluteString,
              singleVideoURL != cleanURL else {
            return nil
        }

        return PlaylistPromptContext(originalURL: cleanURL, singleVideoURL: singleVideoURL)
    }

    func removeRecord(_ id: UUID) {
        if let record = records.first(where: { $0.id == id }),
           record.status == .queued || record.status == .downloading {
            cancel(recordID: id)
        }
        records.removeAll { $0.id == id }
        downloadQueue.removeAll { $0.recordID == id }
        transcodeQueue.removeAll { $0.recordID == id }
        refreshQueuedStatuses()
        persistHistory()
    }

    func removeAll() {
        if let activeDownloadID {
            service.cancel(taskID: activeDownloadID)
        }
        if let activeTranscodeID {
            service.cancel(taskID: activeTranscodeID)
        }
        records.removeAll()
        downloadQueue.removeAll()
        transcodeQueue.removeAll()
        refreshQueuedStatuses()
        persistHistory()
    }

    func retry(recordID: UUID) {
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        if let sourcePath = record.transcodeSourcePath,
           FileManager.default.fileExists(atPath: sourcePath) {
            if record.operationType == .transcodeCopy {
                enqueueTranscodeCopy(sourceRecord: record, sourcePath: sourcePath)
            } else {
                enqueueExistingTranscode(recordID: record.id, sourcePath: sourcePath, sourceURL: record.sourceURL)
            }
            return
        }
        enqueue(urlString: record.sourceURL)
    }

    func retryFailedAndCancelled() {
        let targets = records
            .filter { $0.status == .failed || $0.status == .cancelled }
        for record in targets {
            retry(recordID: record.id)
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
            diagnostics.log(.warning, "Cancelling active task; id=\(recordID.uuidString)")
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

        if activeTranscodeID == recordID {
            diagnostics.log(.warning, "Cancelling active transcode; id=\(recordID.uuidString)")
            service.cancel(taskID: recordID)
            updateRecord(recordID) { record in
                record.status = .cancelled
                record.statusMessage = settings.t("row.status.cancelled")
                record.errorMessage = nil
                record.processingStage = nil
                record.processingProgress = nil
                record.updatedAt = Date()
            }
            return
        }

        if let queueIndex = downloadQueue.firstIndex(where: { $0.recordID == recordID }) {
            diagnostics.log(.warning, "Removed queued task; id=\(recordID.uuidString)")
            downloadQueue.remove(at: queueIndex)
            updateRecord(recordID) { record in
                record.status = .cancelled
                record.statusMessage = settings.t("row.status.cancelled")
                record.errorMessage = nil
                record.processingStage = nil
                record.downloadProgress = nil
                record.processingProgress = nil
                record.updatedAt = Date()
            }
            refreshQueuedStatuses()
            return
        }

        if let queueIndex = transcodeQueue.firstIndex(where: { $0.recordID == recordID }) {
            diagnostics.log(.warning, "Removed queued transcode; id=\(recordID.uuidString)")
            transcodeQueue.remove(at: queueIndex)
            updateRecord(recordID) { record in
                record.status = .cancelled
                record.statusMessage = settings.t("row.status.cancelled")
                record.errorMessage = nil
                record.processingStage = nil
                record.processingProgress = nil
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

    func copyDebugReportToClipboard() {
        let report = buildDebugReport()
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(report, forType: .string)
        if ok {
            toastMessage = settings.t("toast.debugCopied")
            diagnostics.log(.info, "Debug report copied to clipboard (\(report.count) chars)")
        } else {
            toastMessage = settings.t("toast.debugFailed")
            diagnostics.log(.error, "Failed to copy debug report to clipboard")
        }
    }

    private func enqueueTranscodeCopy(sourceRecord: DownloadRecord, sourcePath: String) {
        if records.contains(where: {
            $0.operationType == .transcodeCopy &&
            ($0.status == .queued || $0.status == .downloading) &&
            $0.transcodeSourcePath == sourcePath
        }) {
            toastMessage = settings.t("toast.alreadyQueued")
            return
        }

        let preferences = settings.snapshot()
        let transcodeRecord = DownloadRecord(
            sourceURL: sourceRecord.sourceURL,
            serviceName: sourceRecord.serviceName,
            title: "\(sourceRecord.title) [Apple MOV]",
            durationSeconds: sourceRecord.durationSeconds,
            status: .queued,
            progress: 0.0,
            downloadProgress: nil,
            processingProgress: 0.0,
            statusMessage: settings.t("row.status.queued"),
            kind: .video,
            qualityLabel: sourceRecord.qualityLabel,
            outputFormat: "MOV",
            filePath: nil,
            fileSizeBytes: nil,
            downloadedBytes: nil,
            totalBytes: nil,
            averageSpeedBytesPerSecond: nil,
            uploaderName: sourceRecord.uploaderName,
            thumbnailPath: sourceRecord.thumbnailPath,
            errorMessage: nil,
            processingStage: nil,
            operationType: .transcodeCopy,
            transcodeSourcePath: sourcePath,
            originalVideoBitrateBps: sourceRecord.originalVideoBitrateBps ?? sourceRecord.transcodedVideoBitrateBps,
            transcodedVideoBitrateBps: nil
        )

        records.append(transcodeRecord)
        diagnostics.log(
            .info,
            "Enqueued transcode copy; id=\(transcodeRecord.id.uuidString) source_id=\(sourceRecord.id.uuidString) source_file=\(URL(fileURLWithPath: sourcePath).lastPathComponent) bitrate=\(preferences.transcodeBitrate.rawValue)"
        )
        transcodeQueue.append(
            QueuedTranscodeRequest(
                recordID: transcodeRecord.id,
                sourcePath: sourcePath,
                sourceURL: sourceRecord.sourceURL,
                preferences: preferences,
                replaceOriginal: false
            )
        )
        refreshQueuedStatuses()
        persistHistory()
        startNextTranscodeIfNeeded()
    }

    private func enqueueExistingTranscode(recordID: UUID, sourcePath: String, sourceURL: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        if activeTranscodeID == recordID || transcodeQueue.contains(where: { $0.recordID == recordID }) {
            toastMessage = settings.t("toast.alreadyQueued")
            return
        }

        let preferences = settings.snapshot()
        updateRecord(recordID) { record in
            record.status = .queued
            record.errorMessage = nil
            record.processingStage = .remuxing
            record.processingProgress = 0.0
            record.transcodeSourcePath = sourcePath
            record.updatedAt = Date()
        }

        diagnostics.log(
            .info,
            "Re-enqueued in-place transcode; id=\(recordID.uuidString) source_file=\(URL(fileURLWithPath: sourcePath).lastPathComponent) bitrate=\(preferences.transcodeBitrate.rawValue)"
        )
        transcodeQueue.append(
            QueuedTranscodeRequest(
                recordID: records[index].id,
                sourcePath: sourcePath,
                sourceURL: sourceURL,
                preferences: preferences,
                replaceOriginal: true
            )
        )
        refreshQueuedStatuses()
        persistHistory()
        startNextTranscodeIfNeeded()
    }

    private func startNextDownloadIfNeeded() {
        guard activeDownloadID == nil, !downloadQueue.isEmpty else { return }
        let request = downloadQueue.removeFirst()
        activeDownloadID = request.recordID
        updateRecord(request.recordID) { record in
            record.status = .downloading
            record.statusMessage = settings.t("progress.preparing")
            record.progress = 0.0
            record.downloadProgress = 0.0
            record.processingProgress = nil
            record.processingStage = .preparing
            record.errorMessage = nil
            record.downloadedBytes = nil
            record.totalBytes = nil
            record.averageSpeedBytesPerSecond = nil
            record.fileSizeBytes = nil
            record.updatedAt = Date()
        }
        refreshQueuedStatuses()

        downloadWorkerTask = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(request)
        }
    }

    private func startNextTranscodeIfNeeded() {
        guard activeTranscodeID == nil, !transcodeQueue.isEmpty else { return }
        let request = transcodeQueue.removeFirst()
        activeTranscodeID = request.recordID
        updateRecord(request.recordID) { record in
            record.status = .downloading
            record.statusMessage = settings.t("progress.appleOptimize")
            record.processingStage = .remuxing
            record.processingProgress = max(record.processingProgress ?? 0.0, 0.0)
            record.errorMessage = nil
            if record.operationType == .transcodeCopy {
                record.progress = 0.0
                record.downloadProgress = nil
                record.downloadedBytes = nil
                record.totalBytes = nil
                record.averageSpeedBytesPerSecond = nil
                record.fileSizeBytes = nil
            }
            record.updatedAt = Date()
        }
        refreshQueuedStatuses()

        transcodeWorkerTask = Task { [weak self] in
            guard let self else { return }
            await self.runTranscode(request)
        }
    }

    private func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" ||
        host.hasSuffix(".youtube.com") ||
        host == "youtu.be" ||
        host.hasSuffix(".youtu.be")
    }

    private func hasPlaylistQuery(in components: URLComponents) -> Bool {
        (components.queryItems ?? []).contains { item in
            item.name.lowercased() == "list" && !(item.value?.isEmpty ?? true)
        }
    }

    private func isLikelySingleVideoURL(_ components: URLComponents) -> Bool {
        let queryItems = components.queryItems ?? []
        if queryItems.contains(where: { $0.name.lowercased() == "v" && !($0.value?.isEmpty ?? true) }) {
            return true
        }

        guard let host = components.host?.lowercased() else { return false }
        let path = components.path.lowercased()

        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let slug = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !slug.isEmpty
        }

        return path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
    }

    private func runDownload(_ request: QueuedDownloadRequest) async {
        let requiresAppleProcessing = requiresAppleProcessing(for: request)
        do {
            diagnostics.log(
                .info,
                "Download started; id=\(request.recordID.uuidString) url=\(request.urlString)"
            )
            let service = self.service
            let tools = try await runOffMain {
                try service.locateTools()
            }
            var downloadPhasePreferences = request.preferences
            if requiresAppleProcessing {
                downloadPhasePreferences.appleTranscodeEnabled = false
            }

            updateRecord(request.recordID) { record in
                record.statusMessage = settings.t("progress.downloading")
                record.processingStage = .downloading
                record.downloadProgress = max(record.downloadProgress ?? 0.0, 0.01)
                record.processingProgress = nil
                record.updatedAt = Date()
            }

            let metadataLock = NSLock()
            var thumbnailFetchStarted = false

            let attempt = try await downloadWithCookieFallback(
                request,
                preferences: downloadPhasePreferences,
                tools: tools,
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
            let files = attempt.files

            let subtitlesWarning: String?
            if request.profile.kind == .video && request.profile.includeSubtitles {
                subtitlesWarning = await runOffMain {
                    service.downloadSubtitlesOptional(
                        urlString: request.urlString,
                        preferences: attempt.preferences,
                        tools: tools,
                        taskID: request.recordID
                    )
                }
            } else {
                subtitlesWarning = nil
            }

            if requiresAppleProcessing {
                await stageCompletedFilesForProcessing(files, for: request)
            } else {
                await handleCompletedFiles(files, for: request)
            }
            diagnostics.log(.info, "Download completed; id=\(request.recordID.uuidString) files=\(files.count)")

            if let subtitlesWarning, !subtitlesWarning.isEmpty, !requiresAppleProcessing {
                updateRecord(request.recordID) { record in
                    record.statusMessage = settings.t("warn.subtitlesPartial")
                    record.updatedAt = Date()
                }
            }
        } catch {
            if case DownloadError.cancelled = error {
                diagnostics.log(.warning, "Download cancelled; id=\(request.recordID.uuidString)")
                updateRecord(request.recordID) { record in
                    record.status = .cancelled
                    record.statusMessage = settings.t("row.status.cancelled")
                    record.errorMessage = nil
                    record.processingStage = nil
                    record.processingProgress = nil
                    record.updatedAt = Date()
                }
            } else {
                diagnostics.log(.error, "Download failed; id=\(request.recordID.uuidString) error=\(error.localizedDescription)")
                updateRecord(request.recordID) { record in
                    record.status = .failed
                    record.statusMessage = settings.t("meta.failed")
                    record.errorMessage = self.userFriendlyErrorMessage(error, sourceURL: request.urlString)
                    record.processingStage = nil
                    record.processingProgress = nil
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
        self.startNextDownloadIfNeeded()
        self.startNextTranscodeIfNeeded()
    }

    private func downloadWithCookieFallback(
        _ request: QueuedDownloadRequest,
        preferences: DownloadPreferences,
        tools: YTDLPService.RuntimeTools,
        onMetadata: ((DownloadDiscoveredMetadata) -> Void)? = nil
    ) async throws -> (files: [CompletedFile], preferences: DownloadPreferences) {
        do {
            let files = try await performDownloadAttempt(
                request,
                preferences: preferences,
                tools: tools,
                onMetadata: onMetadata
            )
            return (files, preferences)
        } catch {
            guard shouldRetryWithBrowserCookies(after: error, preferences: preferences) else {
                throw error
            }

            let retrySources = automaticCookieRetrySources(for: request.urlString)
            guard !retrySources.isEmpty else {
                throw error
            }

            var lastError: Error = error
            for source in retrySources {
                var retryPreferences = preferences
                retryPreferences.cookieSource = source

                diagnostics.log(
                    .info,
                    "Retrying download with browser cookies; id=\(request.recordID.uuidString) browser=\(source.rawValue)"
                )
                updateRecord(request.recordID) { record in
                    record.statusMessage = "\(settings.t("progress.cookiesRetry")): \(settings.label(for: source))"
                    record.processingStage = .preparing
                    record.updatedAt = Date()
                }

                do {
                    let files = try await performDownloadAttempt(
                        request,
                        preferences: retryPreferences,
                        tools: tools,
                        onMetadata: onMetadata
                    )
                    diagnostics.log(
                        .info,
                        "Browser cookie retry succeeded; id=\(request.recordID.uuidString) browser=\(source.rawValue)"
                    )
                    return (files, retryPreferences)
                } catch {
                    lastError = error

                    if isRequestedFormatUnavailableError(error) {
                        do {
                            if let explicitSelector = try await runOffMain({
                                try self.service.resolveExplicitFormatSelector(
                                    urlString: request.urlString,
                                    profile: request.profile,
                                    preferences: retryPreferences,
                                    tools: tools,
                                    taskID: request.recordID
                                )
                            }) {
                                diagnostics.log(
                                    .info,
                                    "Retrying download with explicit format selector; id=\(request.recordID.uuidString) browser=\(source.rawValue) format=\(explicitSelector)"
                                )
                                let files = try await performDownloadAttempt(
                                    request,
                                    preferences: retryPreferences,
                                    tools: tools,
                                    formatOverride: explicitSelector,
                                    onMetadata: onMetadata
                                )
                                diagnostics.log(
                                    .info,
                                    "Explicit format selector retry succeeded; id=\(request.recordID.uuidString) browser=\(source.rawValue) format=\(explicitSelector)"
                                )
                                return (files, retryPreferences)
                            }
                        } catch {
                            lastError = error
                            diagnostics.log(
                                .warning,
                                "Explicit format selector retry failed; id=\(request.recordID.uuidString) browser=\(source.rawValue) error=\(error.localizedDescription)"
                            )
                        }
                    }

                    diagnostics.log(
                        .warning,
                        "Browser cookie retry failed; id=\(request.recordID.uuidString) browser=\(source.rawValue) error=\(lastError.localizedDescription)"
                    )
                    if !shouldContinueCookieFallback(after: lastError) {
                        throw lastError
                    }
                }
            }

            throw lastError
        }
    }

    private func performDownloadAttempt(
        _ request: QueuedDownloadRequest,
        preferences: DownloadPreferences,
        tools: YTDLPService.RuntimeTools,
        formatOverride: String? = nil,
        onMetadata: ((DownloadDiscoveredMetadata) -> Void)? = nil
    ) async throws -> [CompletedFile] {
        let service = self.service
        return try await runOffMain {
            try service.download(
                urlString: request.urlString,
                profile: request.profile,
                preferences: preferences,
                tools: tools,
                taskID: request.recordID,
                formatOverride: formatOverride,
                onProgress: { [weak self] progress, message, transfer in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.updateRecord(request.recordID) { record in
                            let stage = self.processingStage(from: message)
                            if !message.isEmpty {
                                record.statusMessage = self.localizedProgressMessage(message)
                            }
                            self.applyPhaseProgress(
                                to: &record,
                                progress: progress,
                                transfer: transfer,
                                stage: stage
                            )
                            record.updatedAt = Date()
                        }
                    }
                },
                onMetadata: onMetadata
            )
        }
    }

    private func runTranscode(_ request: QueuedTranscodeRequest) async {
        do {
            diagnostics.log(
                .info,
                "Transcode started; id=\(request.recordID.uuidString) source=\(request.sourcePath)"
            )
            let service = self.service
            let tools = try await runOffMain {
                try service.locateTools()
            }

            let conversion = try await runOffMain {
                try service.transcodeVideo(
                    sourcePath: request.sourcePath,
                    preferences: request.preferences,
                    tools: tools,
                    taskID: request.recordID,
                    replaceOriginal: request.replaceOriginal,
                    onProgress: { [weak self] progress, message, _ in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.updateRecord(request.recordID) { record in
                                if let progress {
                                    let clamped = max(0.0, min(progress, 1.0))
                                    record.processingProgress = max(record.processingProgress ?? 0.0, clamped)
                                }
                                if !message.isEmpty {
                                    record.statusMessage = self.localizedProgressMessage(message)
                                    record.processingStage = self.processingStage(from: message) ?? .remuxing
                                }
                                record.updatedAt = Date()
                            }
                        }
                    }
                )
            }

            let size = await runOffMain {
                self.fileSizeAtPath(conversion.outputPath)
            }

            updateRecord(request.recordID) { record in
                record.status = .completed
                record.progress = 1.0
                if record.downloadProgress != nil {
                    record.downloadProgress = 1.0
                }
                record.processingProgress = 1.0
                record.statusMessage = settings.t("row.status.completed")
                record.processingStage = nil
                record.filePath = conversion.outputPath
                record.fileSizeBytes = size
                record.averageSpeedBytesPerSecond = nil
                record.outputFormat = "MOV"
                record.originalVideoBitrateBps = conversion.sourceVideoBitrateBps
                record.transcodedVideoBitrateBps = conversion.outputVideoBitrateBps
                record.transcodeSourcePath = nil
                record.updatedAt = Date()
            }
            diagnostics.log(.info, "Transcode completed; id=\(request.recordID.uuidString) output=\(conversion.outputPath)")
        } catch {
            if case DownloadError.cancelled = error {
                diagnostics.log(.warning, "Transcode cancelled; id=\(request.recordID.uuidString)")
                updateRecord(request.recordID) { record in
                    record.status = .cancelled
                    record.statusMessage = settings.t("row.status.cancelled")
                    record.errorMessage = nil
                    record.processingStage = nil
                    record.processingProgress = nil
                    record.updatedAt = Date()
                }
            } else {
                diagnostics.log(.error, "Transcode failed; id=\(request.recordID.uuidString) error=\(error.localizedDescription)")
                updateRecord(request.recordID) { record in
                    record.status = .failed
                    record.statusMessage = settings.t("meta.failed")
                    record.errorMessage = self.userFriendlyErrorMessage(error, sourceURL: request.sourceURL)
                    record.processingStage = nil
                    record.processingProgress = nil
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

        self.activeTranscodeID = nil
        self.persistHistory()
        self.startNextTranscodeIfNeeded()
        self.startNextDownloadIfNeeded()
    }

    private func handleCompletedFiles(_ files: [CompletedFile], for request: QueuedDownloadRequest) async {
        if files.isEmpty {
            updateRecord(request.recordID) { record in
                record.status = .completed
                record.progress = 1.0
                record.downloadProgress = 1.0
                record.processingProgress = nil
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
            record.downloadProgress = 1.0
            record.processingProgress = nil
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
            record.operationType = .download
            record.transcodeSourcePath = nil
            record.originalVideoBitrateBps = first.originalVideoBitrateBps
            record.transcodedVideoBitrateBps = first.transcodedVideoBitrateBps
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
                    downloadProgress: 1.0,
                    processingProgress: nil,
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
                    processingStage: nil,
                    operationType: .download,
                    transcodeSourcePath: nil,
                    originalVideoBitrateBps: file.originalVideoBitrateBps,
                    transcodedVideoBitrateBps: file.transcodedVideoBitrateBps
                )
                self.records.append(extra)
            }
        }
    }

    private func stageCompletedFilesForProcessing(_ files: [CompletedFile], for request: QueuedDownloadRequest) async {
        guard !files.isEmpty else {
            await handleCompletedFiles(files, for: request)
            return
        }

        let first = files[0]
        updateRecord(request.recordID) { record in
            self.applyDownloadedFileSnapshot(first, to: &record, request: request)
            record.status = .queued
            record.processingStage = .remuxing
            record.processingProgress = 0.0
            record.transcodeSourcePath = first.path
            record.updatedAt = Date()
        }

        transcodeQueue.append(
            QueuedTranscodeRequest(
                recordID: request.recordID,
                sourcePath: first.path,
                sourceURL: request.urlString,
                preferences: request.preferences,
                replaceOriginal: true
            )
        )

        if files.count > 1 {
            let parentRecord = records.first(where: { $0.id == request.recordID })
            for file in files.dropFirst() {
                let extra = DownloadRecord(
                    sourceURL: request.urlString,
                    serviceName: service.inferServiceName(from: request.urlString),
                    title: file.title?.isEmpty == false ? file.title! : URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent,
                    durationSeconds: file.durationSeconds,
                    status: .queued,
                    progress: 0.5,
                    downloadProgress: 1.0,
                    processingProgress: 0.0,
                    statusMessage: settings.t("row.status.queued"),
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
                    processingStage: .remuxing,
                    operationType: .download,
                    transcodeSourcePath: file.path,
                    originalVideoBitrateBps: file.originalVideoBitrateBps,
                    transcodedVideoBitrateBps: file.transcodedVideoBitrateBps
                )
                records.append(extra)
                transcodeQueue.append(
                    QueuedTranscodeRequest(
                        recordID: extra.id,
                        sourcePath: file.path,
                        sourceURL: request.urlString,
                        preferences: request.preferences,
                        replaceOriginal: true
                    )
                )
            }
        }

        refreshQueuedStatuses()
        persistHistory()
        startNextTranscodeIfNeeded()
    }

    private func applyDownloadedFileSnapshot(
        _ file: CompletedFile,
        to record: inout DownloadRecord,
        request: QueuedDownloadRequest
    ) {
        record.filePath = file.path
        record.fileSizeBytes = file.fileSizeBytes
        record.downloadedBytes = file.fileSizeBytes
        record.totalBytes = file.fileSizeBytes
        record.averageSpeedBytesPerSecond = nil
        record.downloadProgress = 1.0
        if let title = file.title, !title.isEmpty {
            record.title = title
        }
        if let duration = file.durationSeconds {
            record.durationSeconds = duration
        }
        if let ext = file.ext, !ext.isEmpty {
            record.outputFormat = ext.uppercased()
        }
        if let resolution = file.resolution, !resolution.isEmpty {
            record.qualityLabel = resolution
        }
        record.operationType = .download
        record.transcodeSourcePath = nil
        record.originalVideoBitrateBps = file.originalVideoBitrateBps
        record.transcodedVideoBitrateBps = file.transcodedVideoBitrateBps
    }

    private func requiresAppleProcessing(for request: QueuedDownloadRequest) -> Bool {
        request.preferences.smartModeEnabled &&
        request.preferences.appleTranscodeEnabled &&
        request.profile.kind == .video
    }

    private func applyPhaseProgress(
        to record: inout DownloadRecord,
        progress: Double?,
        transfer: DownloadTransferProgress?,
        stage: DownloadProcessingStage?
    ) {
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

        let resolvedStage = stage ?? record.processingStage
        if resolvedStage == .downloading || resolvedStage == .preparing || resolvedStage == nil {
            if let progress {
                let clamped = max(0.0, min(progress, 1.0))
                record.downloadProgress = max(record.downloadProgress ?? 0.0, clamped)
            }
            if let downloaded = record.downloadedBytes,
               let total = record.totalBytes,
               total > 0 {
                let rawFraction = Double(downloaded) / Double(total)
                record.downloadProgress = max(record.downloadProgress ?? 0.0, min(max(rawFraction, 0.0), 1.0))
            }
        } else {
            if record.downloadProgress == nil {
                record.downloadProgress = 1.0
            }
            if record.processingProgress == nil {
                record.processingProgress = 0.0
            }
        }

        syncLegacyProgress(&record)
    }

    private func userFriendlyErrorMessage(_ error: Error, sourceURL: String) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        let isVimeoSource = sourceURL.lowercased().contains("vimeo.com")
        let isYouTubeSource = {
            guard let host = URL(string: sourceURL)?.host?.lowercased() else {
                return sourceURL.lowercased().contains("youtube.com") || sourceURL.lowercased().contains("youtu.be")
            }
            return isYouTubeHost(host)
        }()
        let hasVimeo404Pattern =
            lower.contains("[vimeo]") &&
            (lower.contains("macos api json") || lower.contains("http error 404"))

        if isVimeoSource && hasVimeo404Pattern {
            return settings.t("error.vimeo.linkHint")
        }

        if isAuthenticationRestrictedError(error) {
            return settings.t("error.youtube.authHint")
        }

        if isBrowserCookieExtractionError(error) {
            return settings.t("error.cookies.browserHint")
        }

        if isYouTubeSource && isRequestedFormatUnavailableError(error) {
            return settings.t("error.youtube.formatHint")
        }

        return raw
    }

    private func buildDebugReport() -> String {
        let snapshot = settings.snapshot()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lines: [String] = []
        lines.append("Link2Download Debug Report")
        lines.append("Generated: \(formatter.string(from: Date()))")
        lines.append("App version: \(AppBuildInfo.displayVersion)")
        lines.append("App bundle: \(Bundle.main.bundleURL.path)")
        lines.append("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("App architecture: \(AppDiagnostics.runtimeArchitecture)")
        lines.append("Records: total=\(records.count) active=\(records.filter { $0.status == .downloading }.count) queued=\(records.filter { $0.status == .queued }.count) failed=\(records.filter { $0.status == .failed }.count)")
        lines.append("Queue length: downloads=\(downloadQueue.count) processing=\(transcodeQueue.count)")
        lines.append("Active download id: \(activeDownloadID?.uuidString ?? "-")")
        lines.append("Active transcode id: \(activeTranscodeID?.uuidString ?? "-")")
        lines.append("Save directory: \(snapshot.saveDirectory)")
        lines.append("Settings: smart=\(snapshot.smartModeEnabled) appleTranscode=\(snapshot.appleTranscodeEnabled) kind=\(snapshot.kind.rawValue) quality=\(snapshot.quality.rawValue) videoFormat=\(snapshot.videoFormat.rawValue) audioFormat=\(snapshot.audioFormat.rawValue) speed=\(snapshot.speedLimit.rawValue) transcodeBitrate=\(snapshot.transcodeBitrate.rawValue) subtitles=\(snapshot.includeSubtitles) extraAudio=\(snapshot.includeAdditionalAudioTracks) cookies=\(snapshot.cookieSource.rawValue)")
        lines.append("Diagnostics log file: \(diagnostics.logFileURL.path)")
        lines.append("")
        lines.append("Recent records:")

        let recent = records
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(15)
        if recent.isEmpty {
            lines.append("  (none)")
        } else {
            for record in recent {
                let title = record.title.replacingOccurrences(of: "\n", with: " ")
                let shortID = String(record.id.uuidString.prefix(8))
                let progress = Int((record.progress * 100.0).rounded())
                let downloadProgress = Int(((record.downloadProgress ?? 0.0) * 100.0).rounded())
                let processingProgress = Int(((record.processingProgress ?? 0.0) * 100.0).rounded())
                let stage = record.processingStage?.rawValue ?? "-"
                let fileName = record.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
                lines.append("  [\(record.status.rawValue)] id=\(shortID) progress=\(progress)% download=\(downloadProgress)% processing=\(processingProgress)% stage=\(stage) format=\(record.outputFormat) file=\(fileName) title=\(title)")
                if let error = record.errorMessage, !error.isEmpty {
                    lines.append("    error=\(error.replacingOccurrences(of: "\n", with: " | "))")
                }
            }
        }

        lines.append("")
        lines.append("---- Internal app.log tail ----")
        let tail = diagnostics.readTail(maxBytes: 180_000)
        if tail.isEmpty {
            lines.append("(log is empty)")
        } else {
            lines.append(tail)
        }

        return lines.joined(separator: "\n")
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
        syncLegacyProgress(&records[index])
        scheduleHistoryPersist()
    }

    private func syncLegacyProgress(_ record: inout DownloadRecord) {
        let downloadProgress = min(max(record.downloadProgress ?? 0.0, 0.0), 1.0)
        let processingProgress = min(max(record.processingProgress ?? 0.0, 0.0), 1.0)

        if record.status == .completed {
            record.progress = 1.0
            return
        }

        if record.processingProgress != nil {
            if record.downloadProgress != nil {
                record.progress = 0.5 + (processingProgress * 0.5)
            } else {
                record.progress = processingProgress
            }
            return
        }

        if record.downloadProgress != nil {
            record.progress = downloadProgress
            return
        }

        switch record.status {
        case .queued, .downloading:
            record.progress = 0.0
        case .completed:
            record.progress = 1.0
        case .failed, .cancelled:
            break
        }
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

    private func shouldRetryWithBrowserCookies(after error: Error, preferences: DownloadPreferences) -> Bool {
        guard preferences.cookieSource == .auto else {
            return false
        }
        return isAuthenticationRestrictedError(error)
    }

    private func shouldContinueCookieFallback(after error: Error) -> Bool {
        if case DownloadError.cancelled = error {
            return false
        }
        return isAuthenticationRestrictedError(error) ||
            isBrowserCookieExtractionError(error) ||
            isRequestedFormatUnavailableError(error)
    }

    private func isAuthenticationRestrictedError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return (lower.contains("sign in to confirm your age") ||
                lower.contains("use --cookies-from-browser") ||
                lower.contains("use --cookies for the authentication") ||
                lower.contains("login required")) &&
            lower.contains("[youtube]")
    }

    private func isBrowserCookieExtractionError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("could not find") && lower.contains("cookie") {
            return true
        }
        if lower.contains("browser cookie") &&
            (lower.contains("export") ||
             lower.contains("decrypt") ||
             lower.contains("database") ||
             lower.contains("profile") ||
             lower.contains("key")) {
            return true
        }
        if (lower.contains("operation not permitted") || lower.contains("permission denied")) &&
            (lower.contains("cookies.binarycookies") || lower.contains("/library/cookies/") || lower.contains("cookie")) {
            return true
        }
        if lower.contains("failed to decrypt") && lower.contains("cookie") {
            return true
        }
        if lower.contains("browser") && lower.contains("cookie") && lower.contains("profile") {
            return true
        }
        if lower.contains("keyring") && lower.contains("cookie") {
            return true
        }
        if lower.contains("--cookies-from-browser") {
            return true
        }
        return false
    }

    private func isRequestedFormatUnavailableError(_ error: Error) -> Bool {
        error.localizedDescription.lowercased().contains("requested format is not available")
    }

    private func automaticCookieRetrySources(for urlString: String) -> [BrowserCookieSource] {
        let supportedOrder: [BrowserCookieSource] = [.comet, .chrome, .safari, .edge, .chromium, .firefox]
        var ordered: [BrowserCookieSource] = []

        if let preferred = preferredBrowserCookieSource(for: urlString) {
            ordered.append(preferred)
        }

        for source in supportedOrder where !ordered.contains(source) && browserIsInstalled(source) {
            ordered.append(source)
        }

        if ordered.isEmpty {
            return supportedOrder
        }
        return ordered
    }

    private func preferredBrowserCookieSource(for urlString: String) -> BrowserCookieSource? {
        guard let url = URL(string: urlString),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            return nil
        }

        switch bundleID {
        case "com.apple.Safari":
            return .safari
        case "com.google.Chrome":
            return .chrome
        case "ai.perplexity.comet":
            return .comet
        case "org.chromium.Chromium":
            return .chromium
        case "org.mozilla.firefox":
            return .firefox
        case "com.microsoft.edgemac":
            return .edge
        default:
            return nil
        }
    }

    private func browserIsInstalled(_ source: BrowserCookieSource) -> Bool {
        guard let bundleID = browserBundleIdentifier(for: source) else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func browserBundleIdentifier(for source: BrowserCookieSource) -> String? {
        switch source {
        case .safari:
            return "com.apple.Safari"
        case .chrome:
            return "com.google.Chrome"
        case .comet:
            return "ai.perplexity.comet"
        case .chromium:
            return "org.chromium.Chromium"
        case .firefox:
            return "org.mozilla.firefox"
        case .edge:
            return "com.microsoft.edgemac"
        case .auto, .none:
            return nil
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
        let downloadPositions = Dictionary(uniqueKeysWithValues: downloadQueue.enumerated().map { ($0.element.recordID, $0.offset + 1) })
        let processingPositions = Dictionary(uniqueKeysWithValues: transcodeQueue.enumerated().map { ($0.element.recordID, $0.offset + 1) })
        var changed = false

        for index in records.indices where records[index].status == .queued {
            let statusText: String
            if let position = downloadPositions[records[index].id] {
                statusText = "\(settings.t("row.status.queuedDownload")) #\(position)"
            } else if let position = processingPositions[records[index].id] {
                statusText = "\(settings.t("row.status.queuedProcessing")) #\(position)"
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
        var changed = false
        records = decoded
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { record in
                var normalized = record
                syncLegacyProgress(&normalized)
                if reconcilePersistedInFlightRecord(&normalized) {
                    changed = true
                }
                return normalized
            }

        if changed {
            persistHistory()
        }
    }

    private func reconcilePersistedInFlightRecord(_ record: inout DownloadRecord) -> Bool {
        guard record.status == .queued || record.status == .downloading else {
            return false
        }

        record.status = .failed
        record.statusMessage = settings.t("meta.failed")
        record.errorMessage = settings.t("error.interruptedSession")
        record.processingStage = nil
        record.updatedAt = Date()
        syncLegacyProgress(&record)
        return true
    }

    private func scheduleHistoryPersist(delay: TimeInterval = 0.75) {
        pendingHistoryPersistWorkItem?.cancel()

        let snapshot = records
        let targetURL = historyFileURL
        let workItem = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: targetURL, options: .atomic)
        }

        pendingHistoryPersistWorkItem = workItem
        historyPersistenceQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func persistHistory() {
        pendingHistoryPersistWorkItem?.cancel()

        let snapshot = records
        let targetURL = historyFileURL
        let workItem = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: targetURL, options: .atomic)
        }

        pendingHistoryPersistWorkItem = nil
        historyPersistenceQueue.async(execute: workItem)
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

    private func fileSizeAtPath(_ path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let value = attributes[.size] as? NSNumber else {
            return nil
        }
        return value.int64Value
    }

    private struct QueuedDownloadRequest {
        let recordID: UUID
        let urlString: String
        let preferences: DownloadPreferences
        let profile: ResolvedDownloadProfile
    }

    private struct QueuedTranscodeRequest {
        let recordID: UUID
        let sourcePath: String
        let sourceURL: String
        let preferences: DownloadPreferences
        let replaceOriginal: Bool
    }
}
