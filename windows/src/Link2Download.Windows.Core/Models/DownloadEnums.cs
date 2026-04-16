namespace Link2Download.Windows.Core.Models;

public enum AppLanguage
{
    System,
    English,
    Russian,
    Hindi,
    Chinese
}

public enum DownloadKind
{
    Video,
    Audio
}

public enum QualityPreset
{
    Best,
    P720,
    P1080,
    P4K,
    P8K
}

public enum VideoFormat
{
    Mp4,
    Mkv
}

public enum AudioFormat
{
    Mp3,
    M4a,
    Ogg
}

public enum SpeedLimitPreset
{
    Unlimited,
    Mbps50,
    Mbps25,
    Mbps10,
    Mbps4
}

public enum BrowserCookieSource
{
    Auto,
    None,
    Chrome,
    Chromium,
    Firefox,
    Edge
}

public enum ListFilter
{
    All,
    Video,
    Audio
}

public enum DownloadStatus
{
    Queued,
    Downloading,
    Completed,
    Failed,
    Cancelled
}

public enum DownloadProcessingStage
{
    Preparing,
    Downloading,
    Finalizing
}

public enum DownloadFailureKind
{
    InvalidUrl,
    ToolsMissing,
    ProcessFailed,
    Cancelled
}
