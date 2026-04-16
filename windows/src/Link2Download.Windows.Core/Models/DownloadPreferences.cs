using System.Text.Json.Serialization;

namespace Link2Download.Windows.Core.Models;

public sealed class DownloadPreferences : ObservableObject
{
    private AppLanguage _language = AppLanguage.System;
    private bool _smartModeEnabled = true;
    private DownloadKind _kind = DownloadKind.Video;
    private QualityPreset _quality = QualityPreset.Best;
    private VideoFormat _videoFormat = VideoFormat.Mp4;
    private AudioFormat _audioFormat = AudioFormat.M4a;
    private string _saveDirectory = GetDefaultSaveDirectory();
    private SpeedLimitPreset _speedLimit = SpeedLimitPreset.Unlimited;
    private BrowserCookieSource _cookieSource = BrowserCookieSource.Auto;
    private bool _includeSubtitles;
    private bool _includeAdditionalAudioTracks;

    public AppLanguage Language
    {
        get => _language;
        set => SetProperty(ref _language, value);
    }

    public bool SmartModeEnabled
    {
        get => _smartModeEnabled;
        set => SetProperty(ref _smartModeEnabled, value);
    }

    public DownloadKind Kind
    {
        get => _kind;
        set => SetProperty(ref _kind, value);
    }

    public QualityPreset Quality
    {
        get => _quality;
        set => SetProperty(ref _quality, value);
    }

    public VideoFormat VideoFormat
    {
        get => _videoFormat;
        set => SetProperty(ref _videoFormat, value);
    }

    public AudioFormat AudioFormat
    {
        get => _audioFormat;
        set => SetProperty(ref _audioFormat, value);
    }

    public string SaveDirectory
    {
        get => _saveDirectory;
        set => SetProperty(ref _saveDirectory, value);
    }

    public SpeedLimitPreset SpeedLimit
    {
        get => _speedLimit;
        set => SetProperty(ref _speedLimit, value);
    }

    public BrowserCookieSource CookieSource
    {
        get => _cookieSource;
        set => SetProperty(ref _cookieSource, value);
    }

    public bool IncludeSubtitles
    {
        get => _includeSubtitles;
        set => SetProperty(ref _includeSubtitles, value);
    }

    public bool IncludeAdditionalAudioTracks
    {
        get => _includeAdditionalAudioTracks;
        set => SetProperty(ref _includeAdditionalAudioTracks, value);
    }

    [JsonIgnore]
    public string SpeedLimitArgument => SpeedLimit switch
    {
        SpeedLimitPreset.Mbps50 => "6250K",
        SpeedLimitPreset.Mbps25 => "3125K",
        SpeedLimitPreset.Mbps10 => "1250K",
        SpeedLimitPreset.Mbps4 => "500K",
        _ => string.Empty
    };

    public static DownloadPreferences CreateDefault()
    {
        var settings = new DownloadPreferences();
        settings.EnsureSaveDirectoryExists();
        return settings;
    }

    public static string GetDefaultSaveDirectory()
    {
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        if (string.IsNullOrWhiteSpace(documents))
        {
            documents = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        return Path.Combine(documents, "Link2Download");
    }

    public DownloadPreferences Clone()
    {
        return new DownloadPreferences
        {
            Language = Language,
            SmartModeEnabled = SmartModeEnabled,
            Kind = Kind,
            Quality = Quality,
            VideoFormat = VideoFormat,
            AudioFormat = AudioFormat,
            SaveDirectory = SaveDirectory,
            SpeedLimit = SpeedLimit,
            CookieSource = CookieSource,
            IncludeSubtitles = IncludeSubtitles,
            IncludeAdditionalAudioTracks = IncludeAdditionalAudioTracks
        };
    }

    public void ApplyFrom(DownloadPreferences other)
    {
        Language = other.Language;
        SmartModeEnabled = other.SmartModeEnabled;
        Kind = other.Kind;
        Quality = other.Quality;
        VideoFormat = other.VideoFormat;
        AudioFormat = other.AudioFormat;
        SaveDirectory = other.SaveDirectory;
        SpeedLimit = other.SpeedLimit;
        CookieSource = other.CookieSource;
        IncludeSubtitles = other.IncludeSubtitles;
        IncludeAdditionalAudioTracks = other.IncludeAdditionalAudioTracks;
    }

    public void EnsureSaveDirectoryExists()
    {
        if (!string.IsNullOrWhiteSpace(SaveDirectory))
        {
            Directory.CreateDirectory(SaveDirectory);
        }
    }
}
