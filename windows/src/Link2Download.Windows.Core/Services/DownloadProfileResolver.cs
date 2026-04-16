using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Core.Services;

public static class DownloadProfileResolver
{
    public static ResolvedDownloadProfile Resolve(string url, DownloadPreferences settings)
    {
        if (!settings.SmartModeEnabled)
        {
            return new ResolvedDownloadProfile(
                settings.Kind,
                settings.VideoFormat,
                settings.AudioFormat,
                settings.Quality,
                settings.IncludeSubtitles,
                settings.IncludeAdditionalAudioTracks);
        }

        var host = TryGetHost(url);
        if (host.Contains("youtube", StringComparison.OrdinalIgnoreCase) ||
            host.Contains("youtu.be", StringComparison.OrdinalIgnoreCase) ||
            host.Contains("vimeo", StringComparison.OrdinalIgnoreCase) ||
            host.Contains("tiktok", StringComparison.OrdinalIgnoreCase) ||
            host.Contains("instagram", StringComparison.OrdinalIgnoreCase))
        {
            return new ResolvedDownloadProfile(
                DownloadKind.Video,
                VideoFormat.Mp4,
                AudioFormat.M4a,
                QualityPreset.Best,
                false,
                false);
        }

        return new ResolvedDownloadProfile(
            settings.Kind,
            settings.VideoFormat,
            settings.AudioFormat,
            settings.Quality,
            settings.IncludeSubtitles,
            settings.IncludeAdditionalAudioTracks);
    }

    private static string TryGetHost(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return uri.Host.ToLowerInvariant();
        }

        return string.Empty;
    }
}
