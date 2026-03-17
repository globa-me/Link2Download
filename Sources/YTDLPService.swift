import Foundation

final class YTDLPService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let processLock = NSLock()
    private var activeProcesses: [UUID: Process] = [:]
    private var cancelledTaskIDs: Set<UUID> = []

    struct RuntimeTools {
        let ytdlp: URL
        let ffmpeg: URL
        let ffprobe: URL?
        let ffmpegDir: URL
    }

    func validate(urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return false
        }
        return true
    }

    func normalize(urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else {
            return trimmed
        }

        if host.contains("vimeo.com") {
            return normalizedVimeoURL(from: components) ?? trimmed
        }

        return trimmed
    }

    func locateTools() throws -> RuntimeTools {
        let ytdlpCandidates = resourceCandidates(name: "yt-dlp") + [
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp")
        ]

        let ffmpegCandidates = resourceCandidates(name: "ffmpeg") + [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]

        let ffprobeCandidates = resourceCandidates(name: "ffprobe") + [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/local/bin/ffprobe")
        ]

        guard let ytdlp = firstExecutable(from: ytdlpCandidates) else {
            throw DownloadError.toolsMissing(["yt-dlp"])
        }

        guard let ffmpeg = firstExecutable(from: ffmpegCandidates) else {
            throw DownloadError.toolsMissing(["ffmpeg"])
        }

        let ffprobe = firstExecutable(from: ffprobeCandidates)
        let ffmpegDir = ffmpeg.deletingLastPathComponent()

        return RuntimeTools(ytdlp: ytdlp, ffmpeg: ffmpeg, ffprobe: ffprobe, ffmpegDir: ffmpegDir)
    }

    func fetchMetadata(urlString: String, tools: RuntimeTools, taskID: UUID? = nil) throws -> MediaMetadata {
        let args = [
            "--dump-single-json",
            "--skip-download",
            "--no-warnings",
            urlString
        ]

        let result = try runProcess(executable: tools.ytdlp, arguments: args, taskID: taskID)
        guard result.exitCode == 0 else {
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw DownloadError.metadataFailed(message)
        }

        guard let data = result.stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.metadataFailed("Failed to parse metadata JSON")
        }

        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = json["duration"] as? Double
        let extractor = (json["extractor_key"] as? String)
            ?? (json["extractor"] as? String)
            ?? inferServiceName(from: urlString)
        let uploader = (json["uploader"] as? String)
            ?? (json["channel"] as? String)
            ?? (json["creator"] as? String)
        let thumbnailURL = json["thumbnail"] as? String

        return MediaMetadata(
            title: title?.isEmpty == false ? title! : urlString,
            durationSeconds: duration,
            extractor: normalizedServiceName(from: extractor, fallbackURL: urlString),
            uploaderName: uploader,
            thumbnailURL: thumbnailURL
        )
    }

    func cancel(taskID: UUID) {
        processLock.lock()
        cancelledTaskIDs.insert(taskID)
        let process = activeProcesses[taskID]
        processLock.unlock()

        process?.terminate()
    }

    func fetchThumbnailData(urlString: String) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            resultData = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return resultData
    }

    func download(
        urlString: String,
        profile: ResolvedDownloadProfile,
        preferences: DownloadPreferences,
        tools: RuntimeTools,
        taskID: UUID,
        onProgress: @escaping (_ percent: Double?, _ message: String, _ transfer: DownloadTransferProgress?) -> Void,
        onMetadata: ((DownloadDiscoveredMetadata) -> Void)? = nil
    ) throws -> [CompletedFile] {
        var args: [String] = [
            "--newline",
            "--no-warnings",
            "--ignore-config",
            "--force-overwrites",
            "--no-continue",
            "--paths", preferences.saveDirectory,
            "--output", outputTemplate(for: profile),
            "--ffmpeg-location", tools.ffmpegDir.path,
            "--print", "before_dl:__L2D_META__:%(title)s\t%(duration)s\t%(extractor_key)s\t%(uploader)s\t%(thumbnail)s",
            "--print", "before_dl:__L2D_ITEM__:%(title)s\t%(duration)s\t%(ext)s\t%(resolution)s",
            "--print", "after_move:__L2D_FILE__:%(filepath)s"
        ]

        if let limit = preferences.speedLimit.ytdlpRateValue {
            args += ["--limit-rate", limit]
        }

        if let cookieSource = preferences.cookieSource.ytdlpValue {
            args += ["--cookies-from-browser", cookieSource]
        }

        switch profile.kind {
        case .video:
            args += ["-f", formatSelector(for: profile.quality)]
            args += ["--merge-output-format", profile.videoFormat.rawValue]
            if profile.includeAdditionalAudioTracks {
                args += ["--audio-multistreams"]
            }
        case .audio:
            args += ["-x", "--audio-format", profile.audioFormat.rawValue, "--audio-quality", "0"]
        }

        args.append(urlString)

        let expectsAppleNormalization = preferences.smartModeEnabled && profile.kind == .video
        var pendingItemData: [(String?, Double?, String?, String?)] = []
        var completedFiles: [CompletedFile] = []
        var lastProgress = 0.0
        var firstTransferTimestamp: Date?

        let progressRegex = try NSRegularExpression(pattern: #"\[download\]\s+([0-9]+(?:\.[0-9]+)?)%"#)

        func emitProgress(_ percent: Double?, _ message: String, transfer: DownloadTransferProgress? = nil) {
            onProgress(percent, message, transfer)
        }

        func handleProgressLine(_ line: String) {
            let lower = line.lowercased()

            if lower.contains("extracting url") ||
                lower.contains("downloading webpage") ||
                lower.contains("downloading player") ||
                lower.contains("downloading m3u8 information") ||
                lower.contains("extracting information") {
                lastProgress = max(lastProgress, 0.02)
                emitProgress(lastProgress, "__L2D_STATUS_PREPARING__")
                return
            }

            if line.contains("[download]") {
                let range = NSRange(location: 0, length: line.utf16.count)
                if let match = progressRegex.firstMatch(in: line, range: range),
                   let pRange = Range(match.range(at: 1), in: line),
                   let value = Double(line[pRange]) {
                    let normalized = value / 100.0
                    let mapped = expectsAppleNormalization ? (normalized * 0.78) : normalized
                    lastProgress = max(lastProgress, mapped)
                    let transfer = self.transferProgress(from: line, rawPercent: value, firstTransferTimestamp: &firstTransferTimestamp)
                    emitProgress(lastProgress, "__L2D_STATUS_DOWNLOADING__", transfer: transfer)
                } else {
                    let transfer = self.transferProgress(from: line, rawPercent: nil, firstTransferTimestamp: &firstTransferTimestamp)
                    if lower.contains("destination") {
                        lastProgress = max(lastProgress, 0.01)
                        emitProgress(lastProgress, "__L2D_STATUS_DOWNLOADING__", transfer: transfer)
                    } else {
                        emitProgress(nil, "__L2D_STATUS_DOWNLOADING__", transfer: transfer)
                    }
                }
                return
            }

            if lower.contains("[merger]") ||
                lower.contains("[extractaudio]") ||
                lower.contains("[videoremuxer]") ||
                lower.contains("[ffmpeg]") ||
                lower.contains("correcting container") ||
                lower.contains("fixing") {
                let finalizeFloor = expectsAppleNormalization ? 0.82 : 0.95
                lastProgress = max(lastProgress, finalizeFloor)
                emitProgress(lastProgress, "__L2D_STATUS_FINALIZING__")
                return
            }

            if line.contains("ERROR:") {
                emitProgress(nil, "__L2D_STATUS_ERROR__:\(line)")
            }
        }

        let result = try runProcess(
            executable: tools.ytdlp,
            arguments: args,
            taskID: taskID,
            onStdoutLine: { line in
                if line.hasPrefix("__L2D_META__:") {
                    let payload = String(line.dropFirst("__L2D_META__:".count))
                    let parts = payload.components(separatedBy: "\t")
                    let rawTitle = parts.indices.contains(0) ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let rawDuration = parts.indices.contains(1) ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let rawExtractor = parts.indices.contains(2) ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let rawUploader = parts.indices.contains(3) ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let rawThumbnail = parts.indices.contains(4) ? parts[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""

                    let duration = Double(rawDuration)
                    let serviceName = rawExtractor.isEmpty ? nil : self.normalizedServiceName(from: rawExtractor, fallbackURL: urlString)

                    onMetadata?(
                        DownloadDiscoveredMetadata(
                            title: rawTitle.isEmpty ? nil : rawTitle,
                            durationSeconds: duration,
                            serviceName: serviceName,
                            uploaderName: rawUploader.isEmpty ? nil : rawUploader,
                            thumbnailURL: rawThumbnail.isEmpty ? nil : rawThumbnail
                        )
                    )
                    return
                }

                if line.hasPrefix("__L2D_ITEM__:") {
                    let payload = String(line.dropFirst("__L2D_ITEM__:".count))
                    let parts = payload.components(separatedBy: "\t")
                    let title = parts.indices.contains(0) ? parts[0] : nil
                    let duration = parts.indices.contains(1) ? Double(parts[1]) : nil
                    let ext = parts.indices.contains(2) ? parts[2] : nil
                    let resolution = parts.indices.contains(3) ? parts[3] : nil
                    pendingItemData.append((title, duration, ext, resolution))
                    return
                }

                if line.hasPrefix("__L2D_FILE__:") {
                    let rawPath = String(line.dropFirst("__L2D_FILE__:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if rawPath.isEmpty {
                        return
                    }

                    let item = pendingItemData.isEmpty ? (nil, nil, nil, nil) : pendingItemData.removeFirst()
                    let fileSize = self.fileSizeInBytes(atPath: rawPath)
                    completedFiles.append(
                        CompletedFile(
                            path: rawPath,
                            title: item.0,
                            ext: item.2,
                            durationSeconds: item.1,
                            resolution: item.3,
                            fileSizeBytes: fileSize
                        )
                    )
                    if expectsAppleNormalization {
                        lastProgress = max(lastProgress, 0.86)
                        emitProgress(lastProgress, "__L2D_STATUS_APPLE_OPTIMIZE__")
                    } else {
                        emitProgress(1.0, "Saved \(URL(fileURLWithPath: rawPath).lastPathComponent)")
                    }
                    return
                }

                handleProgressLine(line)
            },
            onStderrLine: { line in
                handleProgressLine(line)
            }
        )

        guard result.exitCode == 0 else {
            let message = [result.stderr, result.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            throw DownloadError.processFailed(message.isEmpty ? "yt-dlp failed" : message)
        }

        if completedFiles.isEmpty {
            throw DownloadError.processFailed("No output file detected for completed download.")
        }

        return try normalizeForAppleSmartModeIfNeeded(
            files: completedFiles,
            profile: profile,
            preferences: preferences,
            tools: tools,
            taskID: taskID,
            onProgress: { percent, message in
                emitProgress(percent, message)
            }
        )
    }

    func downloadSubtitlesOptional(
        urlString: String,
        preferences: DownloadPreferences,
        tools: RuntimeTools,
        taskID: UUID
    ) -> String? {
        var args: [String] = [
            "--no-warnings",
            "--ignore-config",
            "--skip-download",
            "--paths", preferences.saveDirectory,
            "--ffmpeg-location", tools.ffmpegDir.path,
            "--ignore-errors",
            "--write-subs",
            "--write-auto-subs",
            "--sub-langs", subtitleLanguageSelector(for: preferences.language),
            "--convert-subs", "srt",
            urlString
        ]

        if let cookieSource = preferences.cookieSource.ytdlpValue {
            args.insert(contentsOf: ["--cookies-from-browser", cookieSource], at: 6)
        }

        do {
            let result = try runProcess(executable: tools.ytdlp, arguments: args, taskID: taskID)
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 {
                return stderr.isEmpty ? "Subtitle download failed" : stderr
            }
            if stderr.contains("ERROR:") {
                return stderr
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func inferServiceName(from urlString: String) -> String {
        guard let host = URL(string: urlString)?.host?.lowercased() else {
            return "web"
        }
        if host.contains("youtube") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("vimeo") { return "Vimeo" }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("instagram") { return "Instagram" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func normalizedServiceName(from extractor: String, fallbackURL: String) -> String {
        let normalized = extractor.lowercased()
        if normalized.contains("youtube") || normalized.contains("youtu") { return "YouTube" }
        if normalized.contains("vimeo") { return "Vimeo" }
        if normalized.contains("tiktok") { return "TikTok" }
        if normalized.contains("instagram") { return "Instagram" }
        return inferServiceName(from: fallbackURL)
    }

    private func outputTemplate(for profile: ResolvedDownloadProfile) -> String {
        let profileKey = profileOutputKey(for: profile)
        return "%(title).180B [%(id)s] [\(profileKey)].%(ext)s"
    }

    private func profileOutputKey(for profile: ResolvedDownloadProfile) -> String {
        let qualityKey: String
        switch profile.quality {
        case .smart, .best:
            qualityKey = "best"
        case .p720:
            qualityKey = "720p"
        case .p1080:
            qualityKey = "1080p"
        case .p4k:
            qualityKey = "4k"
        case .p8k:
            qualityKey = "8k"
        }

        switch profile.kind {
        case .video:
            return "video_\(profile.videoFormat.rawValue)_\(qualityKey)"
        case .audio:
            return "audio_\(profile.audioFormat.rawValue)_\(qualityKey)"
        }
    }

    private func formatSelector(for quality: QualityPreset) -> String {
        guard let maxHeight = quality.maxHeight else {
            return "bestvideo*+bestaudio/best"
        }
        // Some extractors (notably Instagram) expose streams without height metadata.
        // Fall back to unrestricted selectors to avoid hard "Requested format is not available" failures.
        return "bestvideo*[height<=\(maxHeight)]+bestaudio/best[height<=\(maxHeight)]/bestvideo*+bestaudio/best"
    }

    private func subtitleLanguageSelector(for language: AppLanguage) -> String {
        switch language {
        case .russian:
            return "ru.*,en.*"
        case .hindi:
            return "hi.*,en.*"
        case .chinese:
            return "zh.*,zh-Hans,zh-Hant,en.*"
        case .english:
            return "en.*"
        case .system:
            let code = Locale.preferredLanguages.first ?? "en"
            if code.hasPrefix("ru") { return "ru.*,en.*" }
            if code.hasPrefix("hi") { return "hi.*,en.*" }
            if code.hasPrefix("zh") { return "zh.*,zh-Hans,zh-Hant,en.*" }
            return "en.*"
        }
    }

    private enum AppleVideoConversionMode: Equatable {
        case copy
        case h264VideoToolbox
        case libx264
    }

    private func normalizeForAppleSmartModeIfNeeded(
        files: [CompletedFile],
        profile: ResolvedDownloadProfile,
        preferences: DownloadPreferences,
        tools: RuntimeTools,
        taskID: UUID,
        onProgress: @escaping (_ percent: Double?, _ message: String) -> Void
    ) throws -> [CompletedFile] {
        guard preferences.smartModeEnabled, profile.kind == .video else {
            return files
        }

        let conversionStart = 0.86
        let conversionSpan = 0.13
        var converted: [CompletedFile] = []
        converted.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            let batchCount = Double(max(files.count, 1))
            let fileStart = conversionStart + (Double(index) / batchCount) * conversionSpan
            let fileEnd = conversionStart + (Double(index + 1) / batchCount) * conversionSpan

            var fileProgressPoint = fileStart
            var stageToken = "__L2D_STATUS_APPLE_OPTIMIZE__"
            onProgress(min(fileProgressPoint, 0.995), stageToken)

            let durationSeconds = file.durationSeconds ?? probeDurationSeconds(for: URL(fileURLWithPath: file.path), tools: tools, taskID: taskID)
            let convertedPath = try convertToAppleCompatibleMOV(
                sourcePath: file.path,
                durationSeconds: durationSeconds,
                tools: tools,
                taskID: taskID,
                onProgressFraction: { fraction in
                    let clamped = min(max(fraction, 0.0), 1.0)
                    fileProgressPoint = fileStart + (fileEnd - fileStart) * clamped
                    onProgress(min(fileProgressPoint, 0.995), stageToken)
                },
                onStageToken: { token in
                    stageToken = token
                    onProgress(min(fileProgressPoint, 0.995), stageToken)
                }
            )

            let fileSize = fileSizeInBytes(atPath: convertedPath)
            converted.append(
                CompletedFile(
                    path: convertedPath,
                    title: file.title,
                    ext: "mov",
                    durationSeconds: durationSeconds ?? file.durationSeconds,
                    resolution: file.resolution,
                    fileSizeBytes: fileSize
                )
            )

            onProgress(min(fileEnd, 0.995), "__L2D_STATUS_APPLE_OPTIMIZE__")
        }

        return converted
    }

    private func convertToAppleCompatibleMOV(
        sourcePath: String,
        durationSeconds: Double?,
        tools: RuntimeTools,
        taskID: UUID,
        onProgressFraction: @escaping (Double) -> Void,
        onStageToken: @escaping (String) -> Void
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw DownloadError.processFailed("Source file not found before Apple conversion: \(sourceURL.lastPathComponent)")
        }

        let outputURL = appleCompatibleOutputURL(for: sourceURL)
        let tempURL = temporaryMOVURL(nextTo: outputURL)

        let sourceVideoCodec = probeCodecName(for: sourceURL, streamSpecifier: "v:0", tools: tools, taskID: taskID)
        let sourceAudioCodec = probeCodecName(for: sourceURL, streamSpecifier: "a:0", tools: tools, taskID: taskID)
        let sourceVideoBitrate = probeVideoBitrateInBps(for: sourceURL, tools: tools, taskID: taskID)
        let sourceAudioBitrate = probeStreamBitrateInBps(for: sourceURL, streamSpecifier: "a:0", tools: tools, taskID: taskID)
        let sourceDimensions = probeVideoDimensions(for: sourceURL, tools: tools, taskID: taskID)

        let videoMode: AppleVideoConversionMode = isAppleNativeVideoCodec(sourceVideoCodec) ? .copy : .h264VideoToolbox
        let copyAudio = isAppleNativeAudioCodec(sourceAudioCodec)
        onStageToken(appleStageStatusToken(for: videoMode))

        do {
            try runAppleMOVConversion(
                sourceURL: sourceURL,
                tempURL: tempURL,
                tools: tools,
                taskID: taskID,
                videoMode: videoMode,
                copyAudio: copyAudio,
                sourceVideoBitrate: sourceVideoBitrate,
                sourceAudioBitrate: sourceAudioBitrate,
                sourceDimensions: sourceDimensions,
                durationSeconds: durationSeconds,
                onProgressFraction: onProgressFraction
            )
        } catch {
            guard videoMode == .h264VideoToolbox else {
                throw error
            }
            try? fileManager.removeItem(at: tempURL)
            onStageToken(appleStageStatusToken(for: .libx264))
            try runAppleMOVConversion(
                sourceURL: sourceURL,
                tempURL: tempURL,
                tools: tools,
                taskID: taskID,
                videoMode: .libx264,
                copyAudio: copyAudio,
                sourceVideoBitrate: sourceVideoBitrate,
                sourceAudioBitrate: sourceAudioBitrate,
                sourceDimensions: sourceDimensions,
                durationSeconds: durationSeconds,
                onProgressFraction: onProgressFraction
            )
        }

        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: tempURL, to: outputURL)

        if sourceURL.path != outputURL.path {
            try? fileManager.removeItem(at: sourceURL)
        }

        return outputURL.path
    }

    private func appleStageStatusToken(for mode: AppleVideoConversionMode) -> String {
        switch mode {
        case .copy:
            return "__L2D_STATUS_APPLE_COPY__"
        case .h264VideoToolbox:
            return "__L2D_STATUS_APPLE_HW_TRANSCODE__"
        case .libx264:
            return "__L2D_STATUS_APPLE_SW_TRANSCODE__"
        }
    }

    private func runAppleMOVConversion(
        sourceURL: URL,
        tempURL: URL,
        tools: RuntimeTools,
        taskID: UUID,
        videoMode: AppleVideoConversionMode,
        copyAudio: Bool,
        sourceVideoBitrate: Int64?,
        sourceAudioBitrate: Int64?,
        sourceDimensions: (width: Int, height: Int)?,
        durationSeconds: Double?,
        onProgressFraction: @escaping (Double) -> Void
    ) throws {
        let targetVideoBitrate = normalizedTargetVideoBitrate(sourceBitrate: sourceVideoBitrate, sourceDimensions: sourceDimensions)
        let targetAudioBitrate = normalizedTargetAudioBitrate(from: sourceAudioBitrate)

        var args: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostats",
            "-progress", "pipe:1",
            "-y",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map_metadata", "0",
            "-movflags", "+faststart+use_metadata_tags"
        ]

        switch videoMode {
        case .copy:
            args += ["-c:v", "copy"]
        case .h264VideoToolbox:
            args += [
                "-c:v", "h264_videotoolbox",
                "-allow_sw", "0",
                "-profile:v", "high",
                "-prio_speed", "1",
                "-power_efficient", "1",
                "-pix_fmt", "yuv420p",
                "-tag:v", "avc1",
                "-b:v", "\(targetVideoBitrate)",
                "-maxrate", "\(targetVideoBitrate)",
                "-bufsize", "\(max(targetVideoBitrate * 2, 1_000_000))"
            ]
        case .libx264:
            args += [
                "-c:v", "libx264",
                "-preset", "medium",
                "-profile:v", "high",
                "-pix_fmt", "yuv420p",
                "-tag:v", "avc1",
                "-b:v", "\(targetVideoBitrate)",
                "-maxrate", "\(targetVideoBitrate)",
                "-bufsize", "\(max(targetVideoBitrate * 2, 1_000_000))"
            ]
        }

        if copyAudio {
            args += ["-c:a", "copy"]
        } else {
            args += ["-c:a", "aac", "-b:a", "\(targetAudioBitrate)", "-ar", "48000"]
        }

        args.append(tempURL.path)

        var ffmpegFraction = 0.0
        let result = try runProcess(
            executable: tools.ffmpeg,
            arguments: args,
            taskID: taskID,
            onStdoutLine: { [weak self] line in
                guard let self else { return }
                guard let fraction = self.ffmpegFraction(from: line, durationSeconds: durationSeconds) else { return }
                ffmpegFraction = max(ffmpegFraction, fraction)
                onProgressFraction(min(ffmpegFraction, 0.995))
            }
        )

        guard result.exitCode == 0 else {
            let message = [result.stderr, result.stdout]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            try? fileManager.removeItem(at: tempURL)
            throw DownloadError.processFailed(message.isEmpty ? "ffmpeg conversion failed" : message)
        }

        onProgressFraction(1.0)
    }

    private func isAppleNativeVideoCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec == "h264" || codec == "hevc" || codec == "prores"
    }

    private func isAppleNativeAudioCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec == "aac" || codec == "alac" || codec == "mp3" || codec.hasPrefix("pcm_")
    }

    private func normalizedTargetVideoBitrate(
        sourceBitrate: Int64?,
        sourceDimensions: (width: Int, height: Int)?
    ) -> Int64 {
        if let sourceBitrate, sourceBitrate > 0 {
            return max(sourceBitrate, 400_000)
        }

        guard let sourceDimensions else {
            return 8_000_000
        }
        let maxSide = max(sourceDimensions.width, sourceDimensions.height)
        if maxSide >= 7680 { return 40_000_000 }
        if maxSide >= 3840 { return 22_000_000 }
        if maxSide >= 2560 { return 14_000_000 }
        if maxSide >= 1920 { return 10_000_000 }
        if maxSide >= 1280 { return 6_000_000 }
        return 3_000_000
    }

    private func normalizedTargetAudioBitrate(from sourceBitrate: Int64?) -> Int64 {
        guard let sourceBitrate, sourceBitrate > 0 else {
            return 192_000
        }
        return min(max(sourceBitrate, 96_000), 512_000)
    }

    private func ffmpegFraction(from line: String, durationSeconds: Double?) -> Double? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }

        if line == "progress=end" {
            return 1.0
        }

        if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
            guard let value = Double(line.split(separator: "=", maxSplits: 1).last ?? "") else { return nil }
            let seconds = value / 1_000_000.0
            return min(max(seconds / durationSeconds, 0.0), 1.0)
        }

        if line.hasPrefix("out_time=") {
            let raw = String(line.dropFirst("out_time=".count))
            guard let seconds = parseTimestampSeconds(raw) else { return nil }
            return min(max(seconds / durationSeconds, 0.0), 1.0)
        }

        return nil
    }

    private func parseTimestampSeconds(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private func probeCodecName(
        for fileURL: URL,
        streamSpecifier: String,
        tools: RuntimeTools,
        taskID: UUID
    ) -> String? {
        guard let ffprobe = tools.ffprobe else { return nil }
        let args = [
            "-v", "error",
            "-select_streams", streamSpecifier,
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        return parseSingleValue(from: try? runProcess(executable: ffprobe, arguments: args, taskID: taskID).stdout)?
            .lowercased()
    }

    private func probeDurationSeconds(for fileURL: URL, tools: RuntimeTools, taskID: UUID) -> Double? {
        guard let ffprobe = tools.ffprobe else { return nil }
        let args = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        guard let raw = parseSingleValue(from: try? runProcess(executable: ffprobe, arguments: args, taskID: taskID).stdout) else {
            return nil
        }
        return Double(raw)
    }

    private func probeVideoDimensions(
        for fileURL: URL,
        tools: RuntimeTools,
        taskID: UUID
    ) -> (width: Int, height: Int)? {
        guard let ffprobe = tools.ffprobe else { return nil }
        let args = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0:s=x",
            fileURL.path
        ]
        guard let raw = parseSingleValue(from: try? runProcess(executable: ffprobe, arguments: args, taskID: taskID).stdout) else {
            return nil
        }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private func probeVideoBitrateInBps(for fileURL: URL, tools: RuntimeTools, taskID: UUID) -> Int64? {
        if let value = probeStreamBitrateInBps(
            for: fileURL,
            streamSpecifier: "v:0",
            tools: tools,
            taskID: taskID
        ) {
            return value
        }

        guard let ffprobe = tools.ffprobe else { return nil }
        let formatArgs = [
            "-v", "error",
            "-show_entries", "format=bit_rate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]

        return parseBitrate(from: try? runProcess(executable: ffprobe, arguments: formatArgs, taskID: taskID).stdout)
    }

    private func probeStreamBitrateInBps(
        for fileURL: URL,
        streamSpecifier: String,
        tools: RuntimeTools,
        taskID: UUID
    ) -> Int64? {
        guard let ffprobe = tools.ffprobe else { return nil }
        let streamArgs = [
            "-v", "error",
            "-select_streams", streamSpecifier,
            "-show_entries", "stream=bit_rate",
            "-of", "default=noprint_wrappers=1:nokey=1",
            fileURL.path
        ]
        return parseBitrate(from: try? runProcess(executable: ffprobe, arguments: streamArgs, taskID: taskID).stdout)
    }

    private func parseBitrate(from raw: String?) -> Int64? {
        guard let line = parseSingleValue(from: raw) else { return nil }
        return Int64(line)
    }

    private func parseSingleValue(from raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)
            ?? ""
        guard !line.isEmpty else { return nil }
        return line
    }

    private func transferProgress(
        from line: String,
        rawPercent: Double?,
        firstTransferTimestamp: inout Date?
    ) -> DownloadTransferProgress? {
        let downloadedRaw = firstMatch(
            in: line,
            pattern: #"\[download\]\s+~?([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)(?:\s+of\b|\s+at\b)"#
        )
        let totalRaw = firstMatch(in: line, pattern: #"of\s+~?([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)"#)
        let speedRaw = firstMatch(in: line, pattern: #"at\s+([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)/s"#)

        let downloadedFromLine = downloadedRaw.flatMap(parseByteCount)
        let totalBytes = totalRaw.flatMap(parseByteCount)
        let instantSpeed = speedRaw.flatMap(parseByteCount).map(Double.init)

        let downloadedBytes: Int64?
        if let downloadedFromLine {
            downloadedBytes = downloadedFromLine
        } else if let totalBytes, let rawPercent {
            let clamped = min(max(rawPercent, 0.0), 100.0) / 100.0
            downloadedBytes = Int64(Double(totalBytes) * clamped)
        } else {
            downloadedBytes = nil
        }

        var averageSpeed = instantSpeed
        if let downloadedBytes, downloadedBytes > 0 {
            let now = Date()
            if firstTransferTimestamp == nil {
                firstTransferTimestamp = now
            }
            if let firstTransferTimestamp {
                let elapsed = max(now.timeIntervalSince(firstTransferTimestamp), 0.5)
                averageSpeed = Double(downloadedBytes) / elapsed
            }
        }

        guard downloadedBytes != nil || totalBytes != nil || averageSpeed != nil else {
            return nil
        }

        return DownloadTransferProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            averageSpeedBytesPerSecond: averageSpeed
        )
    }

    private func firstMatch(in line: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseByteCount(from raw: String) -> Int64? {
        let pattern = #"^\s*~?([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?i?B|B)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: raw.utf16.count)
        guard let match = regex.firstMatch(in: raw, range: range),
              let numberRange = Range(match.range(at: 1), in: raw),
              let unitRange = Range(match.range(at: 2), in: raw),
              let value = Double(raw[numberRange]) else {
            return nil
        }

        let unit = String(raw[unitRange]).uppercased()
        let base: Double = unit.contains("IB") ? 1024.0 : 1000.0
        let exponent: Int
        switch unit.first {
        case "K": exponent = 1
        case "M": exponent = 2
        case "G": exponent = 3
        case "T": exponent = 4
        case "P": exponent = 5
        case "E": exponent = 6
        default: exponent = 0
        }

        let bytes = value * pow(base, Double(exponent))
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return Int64(bytes)
    }

    private func normalizedVimeoURL(from components: URLComponents) -> String? {
        guard let host = components.host?.lowercased() else { return nil }
        var pathParts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if pathParts.count >= 2, pathParts[0].lowercased() == "video" {
            pathParts.removeFirst()
        }

        let videoID = pathParts.first(where: { $0.allSatisfy(\.isNumber) })
        guard let videoID else { return nil }

        let queryItems = components.queryItems ?? []
        var hashToken = queryItems.first(where: { $0.name.lowercased() == "h" })?.value
        if hashToken == nil, pathParts.count >= 2 {
            let maybeToken = pathParts[1]
            if maybeToken.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
                hashToken = maybeToken
            }
        }

        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = "player.vimeo.com"
        normalized.path = "/video/\(videoID)"
        if let hashToken, !hashToken.isEmpty {
            normalized.queryItems = [URLQueryItem(name: "h", value: hashToken)]
        }

        if host == "player.vimeo.com",
           components.path == normalized.path,
           (components.queryItems ?? []).contains(where: { $0.name.lowercased() == "h" }) == (normalized.queryItems != nil) {
            return components.url?.absoluteString
        }

        return normalized.url?.absoluteString
    }

    private func appleCompatibleOutputURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let sourceExt = sourceURL.pathExtension.lowercased()
        var baseName = sourceURL.deletingPathExtension().lastPathComponent
        if sourceExt == "mov" {
            baseName += " [apple]"
        }

        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("mov")
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) && candidate.path != sourceURL.path {
            candidate = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("mov")
            suffix += 1
        }

        return candidate
    }

    private func temporaryMOVURL(nextTo outputURL: URL) -> URL {
        let directory = outputURL.deletingLastPathComponent()
        let stem = outputURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent(".\(stem).\(UUID().uuidString).tmp")
            .appendingPathExtension("mov")
    }

    private func resourceCandidates(name: String) -> [URL] {
        var candidates: [URL] = []
        if let resourcesURL = Bundle.main.resourceURL {
            candidates.append(resourcesURL.appendingPathComponent("bin/\(name)"))
            candidates.append(resourcesURL.appendingPathComponent(name))
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/bin/\(name)"))

        return candidates
    }

    private func firstExecutable(from candidates: [URL]) -> URL? {
        for url in candidates {
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func fileSizeInBytes(atPath path: String) -> Int64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let value = attrs[.size] as? NSNumber else {
            return nil
        }
        return value.int64Value
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        taskID: UUID? = nil,
        onStdoutLine: ((String) -> Void)? = nil,
        onStderrLine: ((String) -> Void)? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        if let taskID, isCancelled(taskID: taskID) {
            clearCancellation(taskID: taskID)
            throw DownloadError.cancelled
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutRemainder = ""
        var stderrRemainder = ""
        let lock = NSLock()

        func consumeLines(data: Data, remainder: inout String, lineHandler: ((String) -> Void)?) {
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            remainder += chunk

            while let index = remainder.firstIndex(of: "\n") {
                let line = String(remainder[..<index]).trimmingCharacters(in: .newlines)
                remainder.removeSubrange(...index)
                if !line.isEmpty {
                    lineHandler?(line)
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            lock.lock()
            stdoutData.append(data)
            consumeLines(data: data, remainder: &stdoutRemainder, lineHandler: onStdoutLine)
            lock.unlock()
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            lock.lock()
            stderrData.append(data)
            consumeLines(data: data, remainder: &stderrRemainder, lineHandler: onStderrLine)
            lock.unlock()
        }

        do {
            register(process: process, taskID: taskID)
            try process.run()
        } catch {
            unregister(taskID: taskID)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        unregister(taskID: taskID)

        let trailingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let trailingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        stdoutData.append(trailingOut)
        stderrData.append(trailingErr)

        if let outTail = String(data: trailingOut, encoding: .utf8), !outTail.isEmpty {
            stdoutRemainder += outTail
        }
        if let errTail = String(data: trailingErr, encoding: .utf8), !errTail.isEmpty {
            stderrRemainder += errTail
        }

        if !stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onStdoutLine?(stdoutRemainder.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !stderrRemainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onStderrLine?(stderrRemainder.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let taskID, isCancelled(taskID: taskID) {
            clearCancellation(taskID: taskID)
            throw DownloadError.cancelled
        }

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func register(process: Process, taskID: UUID?) {
        guard let taskID else { return }
        processLock.lock()
        activeProcesses[taskID] = process
        processLock.unlock()
    }

    private func unregister(taskID: UUID?) {
        guard let taskID else { return }
        processLock.lock()
        activeProcesses.removeValue(forKey: taskID)
        processLock.unlock()
    }

    private func isCancelled(taskID: UUID) -> Bool {
        processLock.lock()
        let cancelled = cancelledTaskIDs.contains(taskID)
        processLock.unlock()
        return cancelled
    }

    private func clearCancellation(taskID: UUID) {
        processLock.lock()
        cancelledTaskIDs.remove(taskID)
        processLock.unlock()
    }
}
