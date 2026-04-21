using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Infrastructure.Runtime;

internal static class YtDlpArgumentsBuilder
{
    internal static string Build(
        DownloadRuntimeRequest request,
        BrowserCookieSource cookieSource,
        string toolsDirectory)
    {
        var args = new List<string>
        {
            "--progress",
            "--newline",
            "--no-warnings",
            "--ignore-config",
            "--force-overwrites",
            "--no-continue",
            "--windows-filenames",
            "--no-playlist",
            "--encoding",
            "utf-8",
            "--progress-template",
            "download:__L2D_PROGRESS__:%(progress._percent_str)s\t%(progress.downloaded_bytes)s\t%(progress.total_bytes)s\t%(progress.total_bytes_estimate)s\t%(progress.speed)s\t%(progress.eta)s",
            "--paths",
            request.Preferences.SaveDirectory,
            "--output",
            BuildOutputTemplate(request.Profile),
            "--ffmpeg-location",
            toolsDirectory,
            "--print",
            "before_dl:__L2D_META__:%(title)s\t%(duration)s\t%(extractor_key)s\t%(uploader)s",
            "--print",
            "before_dl:__L2D_ITEM__:%(title)s\t%(duration)s\t%(ext)s\t%(resolution)s",
            "--print",
            "after_move:__L2D_FILE__:%(filepath)s"
        };

        if (!string.IsNullOrWhiteSpace(request.Preferences.SpeedLimitArgument))
        {
            args.Add("--limit-rate");
            args.Add(request.Preferences.SpeedLimitArgument);
        }

        if (cookieSource is not BrowserCookieSource.None and not BrowserCookieSource.Auto)
        {
            args.Add("--cookies-from-browser");
            args.Add(cookieSource.ToString().ToLowerInvariant());
        }

        if (request.Profile.Kind == DownloadKind.Video)
        {
            args.Add("-f");
            args.Add(BuildFormatSelector(request.Profile));
            args.Add("--merge-output-format");
            args.Add(request.Profile.VideoFormat.ToString().ToLowerInvariant());

            if (request.Profile.IncludeAdditionalAudioTracks)
            {
                args.Add("--audio-multistreams");
            }

            if (request.Profile.IncludeSubtitles)
            {
                args.Add("--write-subs");
                args.Add("--write-auto-subs");
                args.Add("--sub-langs");
                args.Add(GetSubtitleLanguages(request.Preferences.Language));
                args.Add("--convert-subs");
                args.Add("srt");
            }
        }
        else
        {
            args.Add("-x");
            args.Add("--audio-format");
            args.Add(request.Profile.AudioFormat.ToString().ToLowerInvariant());
            args.Add("--audio-quality");
            args.Add("0");
        }

        args.Add(request.Url);
        return string.Join(" ", args.Select(Quote));
    }

    private static string BuildOutputTemplate(ResolvedDownloadProfile profile)
    {
        var quality = profile.Quality switch
        {
            QualityPreset.P720 => "720p",
            QualityPreset.P1080 => "1080p",
            QualityPreset.P4K => "4k",
            QualityPreset.P8K => "8k",
            _ => "best"
        };

        var profileKey = profile.Kind == DownloadKind.Video
            ? $"video_{profile.VideoFormat.ToString().ToLowerInvariant()}_{quality}"
            : $"audio_{profile.AudioFormat.ToString().ToLowerInvariant()}_{quality}";

        return $"%(title).180B [%(id)s] [{profileKey}].%(ext)s";
    }

    private static string BuildFormatSelector(ResolvedDownloadProfile profile)
    {
        var unrestrictedBest = "bestvideo*+bestaudio/best";
        string filtered = unrestrictedBest;
        var maxHeight = profile.Quality switch
        {
            QualityPreset.P720 => 720,
            QualityPreset.P1080 => 1080,
            QualityPreset.P4K => 2160,
            QualityPreset.P8K => 4320,
            _ => (int?)null
        };

        if (maxHeight is not null)
        {
            filtered = $"bestvideo*[height<={maxHeight}]+bestaudio/best[height<={maxHeight}]/{unrestrictedBest}";
        }

        if (profile.VideoFormat != VideoFormat.Mp4)
        {
            return filtered;
        }

        return maxHeight is not null
            ? $"bestvideo*[ext=mp4][height<={maxHeight}]+bestaudio[ext=m4a]/best[ext=mp4][height<={maxHeight}]/bestvideo*[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/{filtered}"
            : $"bestvideo*[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/{unrestrictedBest}";
    }

    private static string GetSubtitleLanguages(AppLanguage language) => language switch
    {
        AppLanguage.Russian => "ru.*,en.*",
        AppLanguage.Hindi => "hi.*,en.*",
        AppLanguage.Chinese => "zh.*,zh-Hans,zh-Hant,en.*",
        _ => "en.*"
    };

    private static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        if (value.Any(char.IsWhiteSpace) || value.Contains('"', StringComparison.Ordinal))
        {
            return $"\"{value.Replace("\"", "\\\"", StringComparison.Ordinal)}\"";
        }

        return value;
    }
}
