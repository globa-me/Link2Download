import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case english
    case russian
    case hindi
    case chinese

    var id: String { rawValue }

    var code: String {
        switch self {
        case .system: return "system"
        case .english: return "en"
        case .russian: return "ru"
        case .hindi: return "hi"
        case .chinese: return "zh"
        }
    }
}

enum DownloadKind: String, CaseIterable, Codable, Identifiable {
    case video
    case audio

    var id: String { rawValue }
}

enum QualityPreset: String, CaseIterable, Codable, Identifiable {
    case smart
    case best
    case p720
    case p1080
    case p4k
    case p8k

    var id: String { rawValue }

    static var userSelectableCases: [QualityPreset] {
        [.best, .p720, .p1080, .p4k, .p8k]
    }

    var maxHeight: Int? {
        switch self {
        case .smart, .best:
            return nil
        case .p720:
            return 720
        case .p1080:
            return 1080
        case .p4k:
            return 2160
        case .p8k:
            return 4320
        }
    }
}

enum VideoFormat: String, CaseIterable, Codable, Identifiable {
    case mp4
    case mkv

    var id: String { rawValue }
}

enum AudioFormat: String, CaseIterable, Codable, Identifiable {
    case mp3
    case m4a
    case ogg

    var id: String { rawValue }
}

enum SpeedLimitPreset: String, CaseIterable, Codable, Identifiable {
    case unlimited
    case mbps50
    case mbps25
    case mbps10
    case mbps4

    var id: String { rawValue }

    var megabitsPerSecond: Double? {
        switch self {
        case .unlimited:
            return nil
        case .mbps50:
            return 50
        case .mbps25:
            return 25
        case .mbps10:
            return 10
        case .mbps4:
            return 4
        }
    }

    var ytdlpRateValue: String? {
        guard let mbps = megabitsPerSecond else { return nil }
        let kiloBytesPerSecond = Int((mbps * 1_000_000 / 8) / 1_000)
        return "\(kiloBytesPerSecond)K"
    }
}

enum BrowserCookieSource: String, CaseIterable, Codable, Identifiable {
    case none
    case safari
    case chrome
    case chromium
    case firefox
    case edge

    var id: String { rawValue }

    var ytdlpValue: String? {
        switch self {
        case .none:
            return nil
        default:
            return rawValue
        }
    }
}

enum ListFilter: String, CaseIterable, Identifiable {
    case all
    case video
    case audio

    var id: String { rawValue }
}

enum DownloadStatus: String, Codable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
}

enum DownloadProcessingStage: String, Codable {
    case preparing
    case downloading
    case remuxing
    case hardwareTranscode
    case softwareTranscode
}

struct DownloadPreferences: Codable {
    var language: AppLanguage
    var smartModeEnabled: Bool
    var kind: DownloadKind
    var quality: QualityPreset
    var videoFormat: VideoFormat
    var audioFormat: AudioFormat
    var saveDirectory: String
    var speedLimit: SpeedLimitPreset
    var cookieSource: BrowserCookieSource
    var includeSubtitles: Bool
    var includeAdditionalAudioTracks: Bool

    static func `default`() -> DownloadPreferences {
        DownloadPreferences(
            language: .system,
            smartModeEnabled: true,
            kind: .video,
            quality: .best,
            videoFormat: .mp4,
            audioFormat: .m4a,
            saveDirectory: Self.defaultSaveDirectory().path,
            speedLimit: .unlimited,
            cookieSource: .none,
            includeSubtitles: false,
            includeAdditionalAudioTracks: false
        )
    }

    static func defaultSaveDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return docs.appendingPathComponent("Link2Download", isDirectory: true)
    }
}

struct DownloadRecord: Identifiable, Codable {
    var id: UUID
    var sourceURL: String
    var serviceName: String
    var title: String
    var durationSeconds: Double?
    var status: DownloadStatus
    var progress: Double
    var statusMessage: String
    var createdAt: Date
    var updatedAt: Date
    var kind: DownloadKind
    var qualityLabel: String
    var outputFormat: String
    var filePath: String?
    var fileSizeBytes: Int64?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var averageSpeedBytesPerSecond: Double?
    var uploaderName: String?
    var thumbnailPath: String?
    var errorMessage: String?
    var processingStage: DownloadProcessingStage?

    init(
        id: UUID = UUID(),
        sourceURL: String,
        serviceName: String,
        title: String,
        durationSeconds: Double?,
        status: DownloadStatus,
        progress: Double,
        statusMessage: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        kind: DownloadKind,
        qualityLabel: String,
        outputFormat: String,
        filePath: String? = nil,
        fileSizeBytes: Int64? = nil,
        downloadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        averageSpeedBytesPerSecond: Double? = nil,
        uploaderName: String? = nil,
        thumbnailPath: String? = nil,
        errorMessage: String? = nil,
        processingStage: DownloadProcessingStage? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.serviceName = serviceName
        self.title = title
        self.durationSeconds = durationSeconds
        self.status = status
        self.progress = progress
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.kind = kind
        self.qualityLabel = qualityLabel
        self.outputFormat = outputFormat
        self.filePath = filePath
        self.fileSizeBytes = fileSizeBytes
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.averageSpeedBytesPerSecond = averageSpeedBytesPerSecond
        self.uploaderName = uploaderName
        self.thumbnailPath = thumbnailPath
        self.errorMessage = errorMessage
        self.processingStage = processingStage
    }
}

struct DownloadTransferProgress {
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let averageSpeedBytesPerSecond: Double?
}

struct DownloadDiscoveredMetadata {
    let title: String?
    let durationSeconds: Double?
    let serviceName: String?
    let uploaderName: String?
    let thumbnailURL: String?
}

struct ResolvedDownloadProfile {
    let kind: DownloadKind
    let videoFormat: VideoFormat
    let audioFormat: AudioFormat
    let quality: QualityPreset
    let includeSubtitles: Bool
    let includeAdditionalAudioTracks: Bool

    var outputFormatLabel: String {
        switch kind {
        case .video:
            return videoFormat.rawValue.uppercased()
        case .audio:
            return audioFormat.rawValue.uppercased()
        }
    }
}

struct MediaMetadata {
    let title: String
    let durationSeconds: Double?
    let extractor: String
    let uploaderName: String?
    let thumbnailURL: String?
}

struct CompletedFile {
    let path: String
    let title: String?
    let ext: String?
    let durationSeconds: Double?
    let resolution: String?
    let fileSizeBytes: Int64?
}

enum DownloadError: Error, LocalizedError {
    case invalidURL
    case toolsMissing([String])
    case processFailed(String)
    case metadataFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .toolsMissing(let tools):
            return "Missing bundled tools: \(tools.joined(separator: ", "))"
        case .processFailed(let details):
            return details
        case .metadataFailed(let details):
            return details
        case .cancelled:
            return "Download cancelled"
        }
    }
}
