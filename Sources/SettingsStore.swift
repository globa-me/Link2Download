import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var language: AppLanguage
    @Published var smartModeEnabled: Bool
    @Published var kind: DownloadKind
    @Published var quality: QualityPreset
    @Published var videoFormat: VideoFormat
    @Published var audioFormat: AudioFormat
    @Published var saveDirectory: String
    @Published var speedLimit: SpeedLimitPreset
    @Published var cookieSource: BrowserCookieSource
    @Published var includeSubtitles: Bool
    @Published var includeAdditionalAudioTracks: Bool

    private let defaultsKey = "link2download.preferences"
    private var cancellables = Set<AnyCancellable>()
    private var isProgrammaticSettingsUpdate = false

    init() {
        let loaded = SettingsStore.loadFromDefaults(key: defaultsKey) ?? .default()
        self.language = loaded.language
        self.smartModeEnabled = loaded.smartModeEnabled
        self.kind = loaded.kind
        self.quality = loaded.quality
        self.videoFormat = loaded.videoFormat
        self.audioFormat = loaded.audioFormat
        self.saveDirectory = loaded.saveDirectory
        self.speedLimit = loaded.speedLimit
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
            kind: kind,
            quality: quality,
            videoFormat: videoFormat,
            audioFormat: audioFormat,
            saveDirectory: saveDirectory,
            speedLimit: speedLimit,
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
            kind = defaults.kind
            quality = defaults.quality
            videoFormat = defaults.videoFormat
            audioFormat = defaults.audioFormat
            saveDirectory = defaults.saveDirectory
            speedLimit = defaults.speedLimit
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
            kind = defaults.kind
            quality = defaults.quality
            videoFormat = defaults.videoFormat
            audioFormat = defaults.audioFormat
            speedLimit = defaults.speedLimit
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
        case .none: return t("cookies.none")
        case .safari: return "Safari"
        case .chrome: return "Chrome"
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
        Publishers.CombineLatest4($language, $smartModeEnabled, $kind, $quality)
            .combineLatest(Publishers.CombineLatest4($videoFormat, $audioFormat, $saveDirectory, $speedLimit))
            .combineLatest(
                Publishers.CombineLatest3(
                    $cookieSource,
                    $includeSubtitles,
                    $includeAdditionalAudioTracks
                )
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
