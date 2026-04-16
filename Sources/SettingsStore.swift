import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var language: AppLanguage
    @Published var smartModeEnabled: Bool
    @Published var appleTranscodeEnabled: Bool
    @Published var kind: DownloadKind
    @Published var quality: QualityPreset
    @Published var videoFormat: VideoFormat
    @Published var audioFormat: AudioFormat
    @Published var saveDirectory: String
    @Published var speedLimit: SpeedLimitPreset
    @Published var transcodeBitrate: TranscodeBitratePreset
    @Published var cookieSource: BrowserCookieSource
    @Published var includeSubtitles: Bool
    @Published var includeAdditionalAudioTracks: Bool

    private let defaultsKey = "link2download.preferences"
    private let cookieAutoMigrationKey = "link2download.preferences.cookiesAutoMigration.v1"
    private var cancellables = Set<AnyCancellable>()
    private var isProgrammaticSettingsUpdate = false

    init() {
        var loaded = SettingsStore.loadFromDefaults(key: defaultsKey) ?? .default()
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: cookieAutoMigrationKey), loaded.cookieSource == .none {
            loaded.cookieSource = .auto
            defaults.set(true, forKey: cookieAutoMigrationKey)
        }
        self.language = loaded.language
        self.smartModeEnabled = loaded.smartModeEnabled
        self.appleTranscodeEnabled = loaded.appleTranscodeEnabled
        self.kind = loaded.kind
        self.quality = loaded.quality
        self.videoFormat = loaded.videoFormat
        self.audioFormat = loaded.audioFormat
        self.saveDirectory = loaded.saveDirectory
        self.speedLimit = loaded.speedLimit
        self.transcodeBitrate = loaded.transcodeBitrate
        self.cookieSource = loaded.cookieSource
        self.includeSubtitles = loaded.includeSubtitles
        self.includeAdditionalAudioTracks = loaded.includeAdditionalAudioTracks

        if self.quality == .smart {
            self.quality = .best
        }

        ensureSaveDirectoryExists()
        bindPersistence()
        bindSmartModeAutoDisable()
    }

    func snapshot() -> DownloadPreferences {
        DownloadPreferences(
            language: language,
            smartModeEnabled: smartModeEnabled,
            appleTranscodeEnabled: appleTranscodeEnabled,
            kind: kind,
            quality: quality,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            saveDirectory: saveDirectory,
            speedLimit: speedLimit,
            transcodeBitrate: transcodeBitrate,
            cookieSource: cookieSource,
            includeSubtitles: includeSubtitles,
            includeAdditionalAudioTracks: includeAdditionalAudioTracks
        )
    }

    func resetDefaults() {
        let defaults = DownloadPreferences.default()
        withProgrammaticSettingsUpdate {
            language = defaults.language
            smartModeEnabled = defaults.smartModeEnabled
            appleTranscodeEnabled = defaults.appleTranscodeEnabled
            kind = defaults.kind
            quality = defaults.quality
            videoFormat = defaults.videoFormat
            audioFormat = defaults.audioFormat
            saveDirectory = defaults.saveDirectory
            speedLimit = defaults.speedLimit
            transcodeBitrate = defaults.transcodeBitrate
            cookieSource = defaults.cookieSource
            includeSubtitles = defaults.includeSubtitles
            includeAdditionalAudioTracks = defaults.includeAdditionalAudioTracks
        }
        ensureSaveDirectoryExists()
    }

    func setSmartMode(_ enabled: Bool) {
        if enabled {
            enableSmartModeAndReset()
        } else {
            smartModeEnabled = false
        }
    }

    func enableSmartModeAndReset() {
        let defaults = DownloadPreferences.default()
        withProgrammaticSettingsUpdate {
            smartModeEnabled = true
            appleTranscodeEnabled = defaults.appleTranscodeEnabled
            kind = defaults.kind
            quality = defaults.quality
            videoFormat = defaults.videoFormat
            audioFormat = defaults.audioFormat
            speedLimit = defaults.speedLimit
            transcodeBitrate = defaults.transcodeBitrate
            cookieSource = defaults.cookieSource
            includeSubtitles = defaults.includeSubtitles
            includeAdditionalAudioTracks = defaults.includeAdditionalAudioTracks
        }
    }

    func resolveProfile(for urlString: String) -> ResolvedDownloadProfile {
        let current = snapshot()
        let safeManualQuality: QualityPreset = current.quality == .smart ? .best : current.quality
        guard current.smartModeEnabled else {
            return ResolvedDownloadProfile(
                kind: current.kind,
                videoFormat: current.videoFormat,
                audioFormat: current.audioFormat,
                quality: safeManualQuality,
                includeSubtitles: current.includeSubtitles,
                includeAdditionalAudioTracks: current.includeAdditionalAudioTracks
            )
        }

        guard let host = URL(string: urlString)?.host?.lowercased() else {
            return ResolvedDownloadProfile(
                kind: .video,
                videoFormat: .mp4,
                audioFormat: .m4a,
                quality: .best,
                includeSubtitles: false,
                includeAdditionalAudioTracks: false
            )
        }

        if host.contains("tiktok") || host.contains("instagram") {
            return ResolvedDownloadProfile(
                kind: .video,
                videoFormat: .mp4,
                audioFormat: .m4a,
                quality: .best,
                includeSubtitles: false,
                includeAdditionalAudioTracks: false
            )
        }

        if host.contains("youtube") || host.contains("youtu.be") || host.contains("vimeo") {
            return ResolvedDownloadProfile(
                kind: .video,
                videoFormat: .mp4,
                audioFormat: .m4a,
                quality: .best,
                includeSubtitles: false,
                includeAdditionalAudioTracks: false
            )
        }

        return ResolvedDownloadProfile(
            kind: current.kind,
            videoFormat: current.videoFormat,
            audioFormat: current.audioFormat,
            quality: safeManualQuality,
            includeSubtitles: current.includeSubtitles,
            includeAdditionalAudioTracks: current.includeAdditionalAudioTracks
        )
    }

    func t(_ key: String) -> String {
        AppLocalization.localize(key, language: language)
    }

    func label(for language: AppLanguage) -> String {
        switch language {
        case .system: return t("settings.system")
        case .english: return t("settings.english")
        case .russian: return t("settings.russian")
        case .hindi: return t("settings.hindi")
        case .chinese: return t("settings.chinese")
        }
    }

    func label(for kind: DownloadKind) -> String {
        switch kind {
        case .video: return t("settings.kind.video")
        case .audio: return t("settings.kind.audio")
        }
    }

    func label(for quality: QualityPreset) -> String {
        switch quality {
        case .smart: return t("quality.smart")
        case .best: return t("quality.best")
        case .p720: return t("quality.720")
        case .p1080: return t("quality.1080")
        case .p4k: return t("quality.4k")
        case .p8k: return t("quality.8k")
        }
    }

    func label(for speed: SpeedLimitPreset) -> String {
        switch speed {
        case .unlimited: return t("speed.unlimited")
        case .mbps50: return t("speed.50")
        case .mbps25: return t("speed.25")
        case .mbps10: return t("speed.10")
        case .mbps4: return t("speed.4")
        }
    }

    func label(for transcodeBitrate: TranscodeBitratePreset) -> String {
        switch transcodeBitrate {
        case .autoHigh:
            return t("transcode.bitrate.auto")
        case .mbps6:
            return "6 Mbps"
        case .mbps10:
            return "10 Mbps"
        case .mbps16:
            return "16 Mbps"
        case .mbps24:
            return "24 Mbps"
        case .mbps35:
            return "35 Mbps"
        case .mbps50:
            return "50 Mbps"
        case .mbps80:
            return "80 Mbps"
        }
    }

    func label(for stage: DownloadProcessingStage) -> String {
        switch stage {
        case .preparing: return t("stage.preparing")
        case .downloading: return t("stage.downloading")
        case .remuxing: return t("stage.remuxing")
        case .hardwareTranscode: return t("stage.hardwareTranscode")
        case .softwareTranscode: return t("stage.softwareTranscode")
        }
    }

    func label(for cookieSource: BrowserCookieSource) -> String {
        switch cookieSource {
        case .auto: return t("cookies.auto")
        case .none: return t("cookies.none")
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .comet: return "Comet"
        case .chromium: return "Chromium"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        }
    }

    func displaySaveDirectory() -> String {
        let url = URL(fileURLWithPath: saveDirectory)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if url.path.hasPrefix(home.path) {
            return "~" + url.path.replacingOccurrences(of: home.path, with: "")
        }
        return saveDirectory
    }

    func ensureSaveDirectoryExists() {
        let url = URL(fileURLWithPath: saveDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func bindPersistence() {
        Publishers.MergeMany(
            $language.map { _ in () }.eraseToAnyPublisher(),
            $smartModeEnabled.map { _ in () }.eraseToAnyPublisher(),
            $appleTranscodeEnabled.map { _ in () }.eraseToAnyPublisher(),
            $kind.map { _ in () }.eraseToAnyPublisher(),
            $quality.map { _ in () }.eraseToAnyPublisher(),
            $videoFormat.map { _ in () }.eraseToAnyPublisher(),
            $audioFormat.map { _ in () }.eraseToAnyPublisher(),
            $saveDirectory.map { _ in () }.eraseToAnyPublisher(),
            $speedLimit.map { _ in () }.eraseToAnyPublisher(),
            $transcodeBitrate.map { _ in () }.eraseToAnyPublisher(),
            $cookieSource.map { _ in () }.eraseToAnyPublisher(),
            $includeSubtitles.map { _ in () }.eraseToAnyPublisher(),
            $includeAdditionalAudioTracks.map { _ in () }.eraseToAnyPublisher()
        )
            .sink { [weak self] _ in
                guard let self else { return }
                self.persist()
            }
            .store(in: &cancellables)
    }

    private func bindSmartModeAutoDisable() {
        Publishers.MergeMany(
            $kind.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $quality.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $videoFormat.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $audioFormat.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $speedLimit.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $cookieSource.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $includeSubtitles.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $includeAdditionalAudioTracks.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            guard let self else { return }
            guard !self.isProgrammaticSettingsUpdate else { return }
            if self.smartModeEnabled {
                self.smartModeEnabled = false
            }
        }
        .store(in: &cancellables)
    }

    private func persist() {
        ensureSaveDirectoryExists()
        guard let data = try? JSONEncoder().encode(snapshot()) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func loadFromDefaults(key: String) -> DownloadPreferences? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DownloadPreferences.self, from: data)
    }

    private func withProgrammaticSettingsUpdate(_ body: () -> Void) {
        isProgrammaticSettingsUpdate = true
        body()
        isProgrammaticSettingsUpdate = false
    }
}
