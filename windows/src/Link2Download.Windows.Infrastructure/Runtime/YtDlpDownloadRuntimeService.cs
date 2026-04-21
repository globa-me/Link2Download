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
                Arguments = YtDlpArgumentsBuilder.Build(request, cookieSource, tools.Directory),
                WorkingDirectory = request.Preferences.SaveDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                CreateNoWindow = true
            }
        };

        var inheritedPath = process.StartInfo.Environment.TryGetValue("PATH", out var currentPath)
            ? currentPath
            : Environment.GetEnvironmentVariable("PATH");
        process.StartInfo.Environment["PATH"] = string.IsNullOrWhiteSpace(inheritedPath)
            ? tools.Directory
            : $"{tools.Directory}{Path.PathSeparator}{inheritedPath}";
        process.StartInfo.Environment["LC_ALL"] = "en_US.UTF-8";
        process.StartInfo.Environment["LANG"] = "en_US.UTF-8";
        process.StartInfo.Environment["PYTHONIOENCODING"] = "utf-8";
        process.StartInfo.Environment["PYTHONUTF8"] = "1";

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

    private sealed record RuntimeTools(string YtDlpPath, string FfmpegPath, string? FfprobePath, string Directory);
}
