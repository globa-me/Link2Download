using System.Text.Json.Serialization;

namespace Link2Download.Windows.Core.Models;

public sealed class DownloadRecord : ObservableObject
{
    private Guid _id = Guid.NewGuid();
    private string _sourceUrl = string.Empty;
    private string _serviceName = "web";
    private string _title = string.Empty;
    private double? _durationSeconds;
    private DownloadStatus _status = DownloadStatus.Queued;
    private double _progress;
    private double? _downloadProgress;
    private double? _processingProgress;
    private string _statusMessage = "Queued";
    private DateTimeOffset _createdAt = DateTimeOffset.UtcNow;
    private DateTimeOffset _updatedAt = DateTimeOffset.UtcNow;
    private DownloadKind _kind = DownloadKind.Video;
    private string _qualityLabel = "Best";
    private string _outputFormat = "MP4";
    private string? _filePath;
    private long? _fileSizeBytes;
    private long? _downloadedBytes;
    private long? _totalBytes;
    private double? _averageSpeedBytesPerSecond;
    private string? _uploaderName;
    private string? _errorMessage;
    private DownloadProcessingStage? _processingStage;

    public Guid Id
    {
        get => _id;
        set => SetProperty(ref _id, value);
    }

    public string SourceUrl
    {
        get => _sourceUrl;
        set => SetProperty(ref _sourceUrl, value);
    }

    public string ServiceName
    {
        get => _serviceName;
        set => SetProperty(ref _serviceName, value);
    }

    public string Title
    {
        get => _title;
        set => SetProperty(ref _title, value);
    }

    public double? DurationSeconds
    {
        get => _durationSeconds;
        set => SetProperty(ref _durationSeconds, value);
    }

    public DownloadStatus Status
    {
        get => _status;
        set => SetProperty(ref _status, value);
    }

    public double Progress
    {
        get => _progress;
        set => SetProperty(ref _progress, value);
    }

    public double? DownloadProgress
    {
        get => _downloadProgress;
        set => SetProperty(ref _downloadProgress, value);
    }

    public double? ProcessingProgress
    {
        get => _processingProgress;
        set => SetProperty(ref _processingProgress, value);
    }

    public string StatusMessage
    {
        get => _statusMessage;
        set => SetProperty(ref _statusMessage, value);
    }

    public DateTimeOffset CreatedAt
    {
        get => _createdAt;
        set => SetProperty(ref _createdAt, value);
    }

    public DateTimeOffset UpdatedAt
    {
        get => _updatedAt;
        set => SetProperty(ref _updatedAt, value);
    }

    public DownloadKind Kind
    {
        get => _kind;
        set => SetProperty(ref _kind, value);
    }

    public string QualityLabel
    {
        get => _qualityLabel;
        set => SetProperty(ref _qualityLabel, value);
    }

    public string OutputFormat
    {
        get => _outputFormat;
        set => SetProperty(ref _outputFormat, value);
    }

    public string? FilePath
    {
        get => _filePath;
        set => SetProperty(ref _filePath, value);
    }

    public long? FileSizeBytes
    {
        get => _fileSizeBytes;
        set => SetProperty(ref _fileSizeBytes, value);
    }

    public long? DownloadedBytes
    {
        get => _downloadedBytes;
        set => SetProperty(ref _downloadedBytes, value);
    }

    public long? TotalBytes
    {
        get => _totalBytes;
        set => SetProperty(ref _totalBytes, value);
    }

    public double? AverageSpeedBytesPerSecond
    {
        get => _averageSpeedBytesPerSecond;
        set => SetProperty(ref _averageSpeedBytesPerSecond, value);
    }

    public string? UploaderName
    {
        get => _uploaderName;
        set => SetProperty(ref _uploaderName, value);
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        set => SetProperty(ref _errorMessage, value);
    }

    public DownloadProcessingStage? ProcessingStage
    {
        get => _processingStage;
        set => SetProperty(ref _processingStage, value);
    }

    [JsonIgnore]
    public bool HasLocalFile => !string.IsNullOrWhiteSpace(FilePath) && File.Exists(FilePath);

    public DownloadRecord Clone()
    {
        return new DownloadRecord
        {
            Id = Id,
            SourceUrl = SourceUrl,
            ServiceName = ServiceName,
            Title = Title,
            DurationSeconds = DurationSeconds,
            Status = Status,
            Progress = Progress,
            DownloadProgress = DownloadProgress,
            ProcessingProgress = ProcessingProgress,
            StatusMessage = StatusMessage,
            CreatedAt = CreatedAt,
            UpdatedAt = UpdatedAt,
            Kind = Kind,
            QualityLabel = QualityLabel,
            OutputFormat = OutputFormat,
            FilePath = FilePath,
            FileSizeBytes = FileSizeBytes,
            DownloadedBytes = DownloadedBytes,
            TotalBytes = TotalBytes,
            AverageSpeedBytesPerSecond = AverageSpeedBytesPerSecond,
            UploaderName = UploaderName,
            ErrorMessage = ErrorMessage,
            ProcessingStage = ProcessingStage
        };
    }

    public bool MatchesQuery(string? query)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return true;
        }

        var normalized = query.Trim();
        return Contains(Title, normalized) ||
               Contains(SourceUrl, normalized) ||
               Contains(ServiceName, normalized) ||
               Contains(UploaderName, normalized) ||
               Contains(FilePath, normalized);
    }

    private static bool Contains(string? value, string query)
    {
        return !string.IsNullOrWhiteSpace(value) &&
               value.Contains(query, StringComparison.OrdinalIgnoreCase);
    }
}

public sealed record DownloadTransferProgress(long? DownloadedBytes, long? TotalBytes, double? AverageSpeedBytesPerSecond);

public sealed record DownloadDiscoveredMetadata(
    string? Title,
    double? DurationSeconds,
    string? ServiceName,
    string? UploaderName);

public sealed record ResolvedDownloadProfile(
    DownloadKind Kind,
    VideoFormat VideoFormat,
    AudioFormat AudioFormat,
    QualityPreset Quality,
    bool IncludeSubtitles,
    bool IncludeAdditionalAudioTracks)
{
    public string OutputFormatLabel => Kind == DownloadKind.Video
        ? VideoFormat.ToString().ToUpperInvariant()
        : AudioFormat.ToString().ToUpperInvariant();
}

public sealed record DownloadRuntimeRequest(
    Guid RecordId,
    string Url,
    DownloadPreferences Preferences,
    ResolvedDownloadProfile Profile);

public sealed record DownloadProgressUpdate(
    double? ProgressFraction,
    string StatusMessage,
    DownloadTransferProgress? Transfer,
    DownloadProcessingStage? Stage);

public sealed record CompletedFile(
    string Path,
    string? Title,
    string? Ext,
    double? DurationSeconds,
    string? Resolution,
    long? FileSizeBytes);

public sealed record DownloadExecutionResult(IReadOnlyList<CompletedFile> Files);
