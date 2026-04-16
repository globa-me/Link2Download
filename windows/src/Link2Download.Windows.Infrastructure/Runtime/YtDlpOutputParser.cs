using System.Globalization;
using System.Text.RegularExpressions;
using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Infrastructure.Runtime;

public sealed class YtDlpOutputParser
{
    private static readonly Regex PercentRegex = new(@"([0-9]+(?:\.[0-9]+)?)\s*%", RegexOptions.Compiled);
    private static readonly Regex DownloadedRegex = new(@"\[download\]\s+~?([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)(?:\s+of\b|\s+at\b)", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex TotalRegex = new(@"of\s+~?([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex SpeedRegex = new(@"at\s+([0-9]+(?:\.[0-9]+)?\s*[KMGTPE]?i?B|[0-9]+(?:\.[0-9]+)?\s*B)/s", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private readonly Queue<(string? Title, double? Duration, string? Ext, string? Resolution)> _pendingItems = new();
    private DateTimeOffset? _firstTransferAt;

    public YtDlpOutputParseResult ParseLine(string rawLine)
    {
        var line = rawLine.Trim();
        if (string.IsNullOrWhiteSpace(line))
        {
            return YtDlpOutputParseResult.Empty;
        }

        if (line.StartsWith("__L2D_META__:", StringComparison.Ordinal))
        {
            var parts = line["__L2D_META__:".Length..].Split('\t');
            return new YtDlpOutputParseResult(
                Metadata: new DownloadDiscoveredMetadata(
                    Title: GetPart(parts, 0),
                    DurationSeconds: TryParseDouble(GetPart(parts, 1)),
                    ServiceName: NormalizeServiceName(GetPart(parts, 2)),
                    UploaderName: GetPart(parts, 3)),
                Progress: null,
                CompletedFile: null,
                ErrorText: null);
        }

        if (line.StartsWith("__L2D_ITEM__:", StringComparison.Ordinal))
        {
            var parts = line["__L2D_ITEM__:".Length..].Split('\t');
            _pendingItems.Enqueue((GetPart(parts, 0), TryParseDouble(GetPart(parts, 1)), GetPart(parts, 2), GetPart(parts, 3)));
            return YtDlpOutputParseResult.Empty;
        }

        if (line.StartsWith("__L2D_FILE__:", StringComparison.Ordinal))
        {
            var path = line["__L2D_FILE__:".Length..].Trim();
            var item = _pendingItems.Count > 0 ? _pendingItems.Dequeue() : default;
            return new YtDlpOutputParseResult(
                Metadata: null,
                Progress: new DownloadProgressUpdate(1, "Saved file", null, DownloadProcessingStage.Finalizing),
                CompletedFile: new CompletedFile(
                    Path: path,
                    Title: item.Title,
                    Ext: item.Ext,
                    DurationSeconds: item.Duration,
                    Resolution: item.Resolution,
                    FileSizeBytes: File.Exists(path) ? new FileInfo(path).Length : null),
                ErrorText: null);
        }

        if (line.StartsWith("__L2D_PROGRESS__:", StringComparison.Ordinal))
        {
            var parsed = ParseStructuredProgressPayload(line["__L2D_PROGRESS__:".Length..]);
            return new YtDlpOutputParseResult(
                Metadata: null,
                Progress: new DownloadProgressUpdate(ToFraction(parsed.RawPercent, parsed.Transfer), "Downloading...", parsed.Transfer, DownloadProcessingStage.Downloading),
                CompletedFile: null,
                ErrorText: null);
        }

        var lower = line.ToLowerInvariant();
        if (lower.Contains("extracting url", StringComparison.Ordinal) ||
            lower.Contains("downloading webpage", StringComparison.Ordinal) ||
            lower.Contains("extracting information", StringComparison.Ordinal))
        {
            return new YtDlpOutputParseResult(
                null,
                new DownloadProgressUpdate(0.02, "Preparing download...", null, DownloadProcessingStage.Preparing),
                null,
                null);
        }

        if (line.Contains("[download]", StringComparison.Ordinal))
        {
            var rawPercent = ParsePercent(line);
            var transfer = ParseTextProgress(line, rawPercent);
            return new YtDlpOutputParseResult(
                null,
                new DownloadProgressUpdate(ToFraction(rawPercent, transfer), "Downloading...", transfer, DownloadProcessingStage.Downloading),
                null,
                null);
        }

        if (lower.Contains("[merger]", StringComparison.Ordinal) ||
            lower.Contains("[extractaudio]", StringComparison.Ordinal) ||
            lower.Contains("[videoremuxer]", StringComparison.Ordinal) ||
            lower.Contains("[ffmpeg]", StringComparison.Ordinal))
        {
            return new YtDlpOutputParseResult(
                null,
                new DownloadProgressUpdate(0.95, "Finalizing file...", null, DownloadProcessingStage.Finalizing),
                null,
                null);
        }

        if (line.Contains("ERROR:", StringComparison.Ordinal))
        {
            return new YtDlpOutputParseResult(null, null, null, line);
        }

        return YtDlpOutputParseResult.Empty;
    }

    public StructuredProgressResult ParseStructuredProgressPayload(string payload)
    {
        var parts = payload.Split('\t');
        var rawPercent = ParsePercent(GetPart(parts, 0));
        var downloaded = TryParseLong(GetPart(parts, 1));
        var total = TryParseLong(GetPart(parts, 2));
        var estimate = TryParseLong(GetPart(parts, 3));
        var speed = TryParseDouble(GetPart(parts, 4));
        var resolvedTotal = total ?? estimate;

        long? resolvedDownloaded = downloaded;
        if (resolvedDownloaded is null && resolvedTotal is not null && rawPercent is not null)
        {
            resolvedDownloaded = (long)(resolvedTotal.Value * Math.Clamp(rawPercent.Value / 100d, 0, 1));
        }

        double? averageSpeed = speed;
        if (resolvedDownloaded is not null && averageSpeed is null)
        {
            var now = DateTimeOffset.UtcNow;
            _firstTransferAt ??= now;
            var elapsed = Math.Max((now - _firstTransferAt.Value).TotalSeconds, 0.5d);
            averageSpeed = resolvedDownloaded.Value / elapsed;
        }

        var transfer = resolvedDownloaded is null && resolvedTotal is null && averageSpeed is null
            ? null
            : new DownloadTransferProgress(resolvedDownloaded, resolvedTotal, averageSpeed);

        return new StructuredProgressResult(rawPercent, transfer);
    }

    private DownloadTransferProgress? ParseTextProgress(string line, double? rawPercent)
    {
        var downloaded = DownloadedRegex.Match(line);
        var total = TotalRegex.Match(line);
        var speed = SpeedRegex.Match(line);

        var downloadedBytes = downloaded.Success ? ParseByteCount(downloaded.Groups[1].Value) : null;
        var totalBytes = total.Success ? ParseByteCount(total.Groups[1].Value) : null;
        var speedBytes = speed.Success ? ParseByteCount(speed.Groups[1].Value) : null;

        if (downloadedBytes is null && totalBytes is not null && rawPercent is not null)
        {
            downloadedBytes = (long)(totalBytes.Value * Math.Clamp(rawPercent.Value / 100d, 0, 1));
        }

        double? averageSpeed = speedBytes;
        if (downloadedBytes is not null && averageSpeed is null)
        {
            var now = DateTimeOffset.UtcNow;
            _firstTransferAt ??= now;
            var elapsed = Math.Max((now - _firstTransferAt.Value).TotalSeconds, 0.5d);
            averageSpeed = downloadedBytes.Value / elapsed;
        }

        if (downloadedBytes is null && totalBytes is null && averageSpeed is null)
        {
            return null;
        }

        return new DownloadTransferProgress(downloadedBytes, totalBytes, averageSpeed);
    }

    private static string? NormalizeServiceName(string? extractor)
    {
        if (string.IsNullOrWhiteSpace(extractor))
        {
            return null;
        }

        var lower = extractor.ToLowerInvariant();
        if (lower.Contains("youtube", StringComparison.Ordinal) || lower.Contains("youtu", StringComparison.Ordinal))
        {
            return "YouTube";
        }

        if (lower.Contains("vimeo", StringComparison.Ordinal))
        {
            return "Vimeo";
        }

        if (lower.Contains("tiktok", StringComparison.Ordinal))
        {
            return "TikTok";
        }

        if (lower.Contains("instagram", StringComparison.Ordinal))
        {
            return "Instagram";
        }

        return extractor;
    }

    private static string? GetPart(string[] parts, int index)
    {
        if (index >= 0 && index < parts.Length && !string.IsNullOrWhiteSpace(parts[index]))
        {
            return parts[index].Trim();
        }

        return null;
    }

    private static double? ParsePercent(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        var match = PercentRegex.Match(raw);
        return match.Success ? TryParseDouble(match.Groups[1].Value) : null;
    }

    private static double? TryParseDouble(string? raw)
    {
        return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    private static long? TryParseLong(string? raw)
    {
        return long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    private static long? ParseByteCount(string raw)
    {
        var parts = raw.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || !double.TryParse(parts[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
        {
            return null;
        }

        var unit = parts.Length > 1 ? parts[1].ToUpperInvariant() : "B";
        var baseValue = unit.Contains("IB", StringComparison.Ordinal) ? 1024d : 1000d;
        var exponent = unit.StartsWith('K') ? 1 :
            unit.StartsWith('M') ? 2 :
            unit.StartsWith('G') ? 3 :
            unit.StartsWith('T') ? 4 :
            unit.StartsWith('P') ? 5 :
            unit.StartsWith('E') ? 6 : 0;

        var bytes = value * Math.Pow(baseValue, exponent);
        return double.IsFinite(bytes) && bytes >= 0 ? (long)bytes : null;
    }

    private static double? ToFraction(double? rawPercent, DownloadTransferProgress? transfer)
    {
        double? percentFraction = rawPercent.HasValue
            ? Math.Clamp(rawPercent.Value / 100d, 0, 1)
            : null;
        if (transfer?.DownloadedBytes is not null && transfer.TotalBytes is > 0)
        {
            var byteFraction = Math.Clamp((double)transfer.DownloadedBytes.Value / transfer.TotalBytes.Value, 0, 1);
            return Math.Max(percentFraction ?? 0, byteFraction);
        }

        return percentFraction;
    }
}

public sealed record StructuredProgressResult(double? RawPercent, DownloadTransferProgress? Transfer);

public sealed record YtDlpOutputParseResult(
    DownloadDiscoveredMetadata? Metadata,
    DownloadProgressUpdate? Progress,
    CompletedFile? CompletedFile,
    string? ErrorText)
{
    public static YtDlpOutputParseResult Empty { get; } = new(null, null, null, null);
}
