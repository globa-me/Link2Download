using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Infrastructure.Runtime;

public sealed class YtDlpDownloadRuntimeService : IDownloadRuntimeService
{
    private readonly IDiagnosticsLogger _diagnostics;

    public YtDlpDownloadRuntimeService(IDiagnosticsLogger diagnostics)
    {
        _diagnostics = diagnostics;
    }

    public bool ValidateUrl(string url)
    {
        return Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) &&
               (uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) ||
                uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) &&
               !string.IsNullOrWhiteSpace(uri.Host);
    }

    public string NormalizeUrl(string url) => url.Trim();

    public string InferServiceName(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return "web";
        }

        var host = uri.Host.ToLowerInvariant();
        if (host.Contains("youtube", StringComparison.Ordinal) || host.Contains("youtu.be", StringComparison.Ordinal))
        {
            return "YouTube";
        }

        if (host.Contains("vimeo", StringComparison.Ordinal))
        {
            return "Vimeo";
        }

        if (host.Contains("tiktok", StringComparison.Ordinal))
        {
            return "TikTok";
        }

        if (host.Contains("instagram", StringComparison.Ordinal))
        {
            return "Instagram";
        }

        return host.Replace("www.", string.Empty, StringComparison.Ordinal);
    }

    public async Task<DownloadExecutionResult> DownloadAsync(
        DownloadRuntimeRequest request,
        IProgress<DownloadProgressUpdate> progress,
        Action<DownloadDiscoveredMetadata>? onMetadata,
        CancellationToken cancellationToken)
    {
        request.Preferences.EnsureSaveDirectoryExists();
        var runtime = LocateTools();

        if (request.Preferences.CookieSource == BrowserCookieSource.Auto)
        {
            try
            {
                return await RunAttemptAsync(request, BrowserCookieSource.None, runtime, progress, onMetadata, cancellationToken);
            }
            catch (DownloadException ex) when (ShouldRetryWithBrowserCookies(ex))
            {
                foreach (var browser in GetCookieRetryOrder())
                {
                    progress.Report(new DownloadProgressUpdate(0.02, $"Retrying with browser cookies: {browser}", null, DownloadProcessingStage.Preparing));
                    try
                    {
                        return await RunAttemptAsync(request, browser, runtime, progress, onMetadata, cancellationToken);
                    }
                    catch (DownloadException retryEx) when (ShouldContinueCookieFallback(retryEx))
                    {
                        _diagnostics.Warning($"Cookie retry with {browser} failed: {retryEx.Message}");
                    }
                }

                throw;
            }
        }

        return await RunAttemptAsync(request, request.Preferences.CookieSource, runtime, progress, onMetadata, cancellationToken);
    }

    private async Task<DownloadExecutionResult> RunAttemptAsync(
        DownloadRuntimeRequest request,
        BrowserCookieSource cookieSource,
        RuntimeTools tools,
        IProgress<DownloadProgressUpdate> progress,
        Action<DownloadDiscoveredMetadata>? onMetadata,
        CancellationToken cancellationToken)
    {
        var parser = new YtDlpOutputParser();
        var completedFiles = new List<CompletedFile>();
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var parserLock = new object();

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = tools.YtDlpPath,
                Arguments = BuildArguments(request, cookieSource, tools),
                WorkingDirectory = request.Preferences.SaveDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                CreateNoWindow = true
            }
        };

        process.StartInfo.Environment["LC_ALL"] = "en_US.UTF-8";
        process.StartInfo.Environment["LANG"] = "en_US.UTF-8";

        using var registration = cancellationToken.Register(() => TryKill(process));

        try
        {
            if (!process.Start())
            {
                throw new DownloadException(DownloadFailureKind.ProcessFailed, "Failed to start yt-dlp.");
            }
        }
        catch (Win32Exception ex)
        {
            throw new DownloadException(DownloadFailureKind.ProcessFailed, ex.Message, innerException: ex);
        }

        _diagnostics.Info($"Process start: {process.StartInfo.FileName} {process.StartInfo.Arguments}");

        var stdoutTask = ReadLinesAsync(process.StandardOutput, line =>
        {
            AppendBounded(stdout, line);
            HandleParsedLine(line, parser, parserLock, completedFiles, progress, onMetadata);
        });

        var stderrTask = ReadLinesAsync(process.StandardError, line =>
        {
            AppendBounded(stderr, line);
            HandleParsedLine(line, parser, parserLock, completedFiles, progress, onMetadata);
        });

        await process.WaitForExitAsync(cancellationToken);
        await Task.WhenAll(stdoutTask, stderrTask);

        if (cancellationToken.IsCancellationRequested)
        {
            throw new DownloadException(DownloadFailureKind.Cancelled, "Download cancelled.");
        }

        if (process.ExitCode != 0)
        {
            var combined = stderr.Length > 0 ? stderr.ToString() : stdout.ToString();
            throw new DownloadException(
                DownloadFailureKind.ProcessFailed,
                string.IsNullOrWhiteSpace(combined) ? "yt-dlp failed." : combined.Trim());
        }

        if (completedFiles.Count == 0)
        {
            throw new DownloadException(DownloadFailureKind.ProcessFailed, "yt-dlp completed without producing a file.");
        }

        return new DownloadExecutionResult(completedFiles);
    }

    private void HandleParsedLine(
        string line,
        YtDlpOutputParser parser,
        object parserLock,
        List<CompletedFile> completedFiles,
        IProgress<DownloadProgressUpdate> progress,
        Action<DownloadDiscoveredMetadata>? onMetadata)
    {
        YtDlpOutputParseResult parsed;
        lock (parserLock)
        {
            parsed = parser.ParseLine(line);
        }

        if (parsed.Metadata is not null)
        {
            onMetadata?.Invoke(parsed.Metadata);
        }

        if (parsed.Progress is not null)
        {
            progress.Report(parsed.Progress);
        }

        if (parsed.CompletedFile is not null)
        {
            completedFiles.Add(parsed.CompletedFile);
        }
    }

    private RuntimeTools LocateTools()
    {
        foreach (var candidate in EnumerateRuntimeCandidates())
        {
            var ytdlp = Path.Combine(candidate, "yt-dlp.exe");
            var ffmpeg = Path.Combine(candidate, "ffmpeg.exe");
            var ffprobe = Path.Combine(candidate, "ffprobe.exe");

            if (File.Exists(ytdlp) && File.Exists(ffmpeg))
            {
                return new RuntimeTools(ytdlp, ffmpeg, File.Exists(ffprobe) ? ffprobe : null, candidate);
            }
        }

        throw new DownloadException(
            DownloadFailureKind.ToolsMissing,
            "Missing runtime tools. Place yt-dlp.exe and ffmpeg.exe into windows/runtime/win-x64/.",
            ["yt-dlp.exe", "ffmpeg.exe"]);
    }

    private IEnumerable<string> EnumerateRuntimeCandidates()
    {
        var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var explicitRuntime = Environment.GetEnvironmentVariable("L2D_WINDOWS_RUNTIME_DIR");
        if (!string.IsNullOrWhiteSpace(explicitRuntime))
        {
            roots.Add(explicitRuntime);
        }

        roots.Add(Directory.GetCurrentDirectory());
        roots.Add(AppContext.BaseDirectory);

        foreach (var root in roots)
        {
            var info = new DirectoryInfo(root);
            while (info is not null)
            {
                yield return Path.Combine(info.FullName, "windows", "runtime", "win-x64");
                yield return Path.Combine(info.FullName, "runtime", "win-x64");
                info = info.Parent;
            }
        }
    }

    private string BuildArguments(DownloadRuntimeRequest request, BrowserCookieSource cookieSource, RuntimeTools tools)
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
            "--progress-template",
            "download:__L2D_PROGRESS__:%(progress._percent_str)s\t%(progress.downloaded_bytes)s\t%(progress.total_bytes)s\t%(progress.total_bytes_estimate)s\t%(progress.speed)s\t%(progress.eta)s",
            "--paths",
            request.Preferences.SaveDirectory,
            "--output",
            BuildOutputTemplate(request.Profile),
            "--ffmpeg-location",
            tools.Directory,
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

    private static IEnumerable<BrowserCookieSource> GetCookieRetryOrder()
    {
        yield return BrowserCookieSource.Edge;
        yield return BrowserCookieSource.Chrome;
        yield return BrowserCookieSource.Firefox;
        yield return BrowserCookieSource.Chromium;
    }

    private static bool ShouldRetryWithBrowserCookies(DownloadException exception)
    {
        var lower = exception.Message.ToLowerInvariant();
        return lower.Contains("use --cookies-from-browser", StringComparison.Ordinal) ||
               lower.Contains("login required", StringComparison.Ordinal) ||
               lower.Contains("sign in to confirm", StringComparison.Ordinal) ||
               lower.Contains("authentication", StringComparison.Ordinal);
    }

    private static bool ShouldContinueCookieFallback(DownloadException exception)
    {
        if (exception.Kind == DownloadFailureKind.Cancelled)
        {
            return false;
        }

        var lower = exception.Message.ToLowerInvariant();
        return lower.Contains("cookies", StringComparison.Ordinal) ||
               lower.Contains("browser", StringComparison.Ordinal) ||
               lower.Contains("login required", StringComparison.Ordinal) ||
               lower.Contains("sign in", StringComparison.Ordinal);
    }

    private static async Task ReadLinesAsync(StreamReader reader, Action<string> onLine)
    {
        while (true)
        {
            var line = await reader.ReadLineAsync();
            if (line is null)
            {
                break;
            }

            onLine(line);
        }
    }

    private static void AppendBounded(StringBuilder builder, string line, int maxLength = 12_000)
    {
        if (builder.Length < maxLength)
        {
            builder.AppendLine(line);
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
        }
    }

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

    private sealed record RuntimeTools(string YtDlpPath, string FfmpegPath, string? FfprobePath, string Directory);
}
