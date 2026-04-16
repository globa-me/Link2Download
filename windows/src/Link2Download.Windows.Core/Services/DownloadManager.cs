using System.Collections.ObjectModel;
using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Core.Services;

public sealed class DownloadManager
{
    private readonly IDownloadRuntimeService _runtimeService;
    private readonly IHistoryRepository _historyRepository;
    private readonly IDiagnosticsLogger _diagnostics;
    private readonly IUiDispatcher _dispatcher;
    private readonly object _sync = new();
    private Queue<QueuedDownload> _pendingDownloads = new();
    private Task? _workerTask;
    private CancellationTokenSource? _activeCancellation;
    private Guid? _activeRecordId;
    private CancellationTokenSource? _saveDebounceCts;

    public DownloadManager(
        IDownloadRuntimeService runtimeService,
        IHistoryRepository historyRepository,
        IDiagnosticsLogger diagnostics,
        IUiDispatcher dispatcher)
    {
        _runtimeService = runtimeService;
        _historyRepository = historyRepository;
        _diagnostics = diagnostics;
        _dispatcher = dispatcher;
    }

    public ObservableCollection<DownloadRecord> Records { get; } = [];

    public event EventHandler? Changed;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        var loaded = await _historyRepository.LoadAsync(cancellationToken);
        var normalized = loaded
            .Select(record =>
            {
                var copy = record.Clone();
                if (copy.Status is DownloadStatus.Queued or DownloadStatus.Downloading)
                {
                    copy.Status = DownloadStatus.Failed;
                    copy.StatusMessage = "Interrupted by previous app session.";
                    copy.ErrorMessage = "This download was interrupted when the app closed. Retry to continue.";
                    copy.ProcessingStage = null;
                }

                return copy;
            })
            .OrderByDescending(record => record.UpdatedAt)
            .ToList();

        await _dispatcher.InvokeAsync(() =>
        {
            Records.Clear();
            foreach (var record in normalized)
            {
                Records.Add(record);
            }
        });

        OnChanged();
        await PersistNowAsync(cancellationToken);
    }

    public async Task EnqueueAsync(string url, DownloadPreferences preferences, CancellationToken cancellationToken = default)
    {
        var normalizedUrl = _runtimeService.NormalizeUrl(url);
        if (!_runtimeService.ValidateUrl(normalizedUrl))
        {
            throw new DownloadException(
                DownloadFailureKind.InvalidUrl,
                "Paste a valid http(s) link before starting the download.");
        }

        var profile = DownloadProfileResolver.Resolve(normalizedUrl, preferences);
        var qualityLabel = GetQualityLabel(profile.Quality);
        var formatLabel = profile.OutputFormatLabel;

        var isDuplicate = await _dispatcher.InvokeAsync(() =>
            Records.Any(record =>
                string.Equals(record.SourceUrl, normalizedUrl, StringComparison.OrdinalIgnoreCase) &&
                record.Status is DownloadStatus.Queued or DownloadStatus.Downloading &&
                record.Kind == profile.Kind &&
                string.Equals(record.QualityLabel, qualityLabel, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(record.OutputFormat, formatLabel, StringComparison.OrdinalIgnoreCase)));

        if (isDuplicate)
        {
            throw new InvalidOperationException("This link is already downloading or queued.");
        }

        var createdAt = DateTimeOffset.UtcNow;
        var record = new DownloadRecord
        {
            Id = Guid.NewGuid(),
            SourceUrl = normalizedUrl,
            ServiceName = _runtimeService.InferServiceName(normalizedUrl),
            Title = normalizedUrl,
            Status = DownloadStatus.Queued,
            StatusMessage = "Queued",
            Progress = 0,
            DownloadProgress = 0,
            Kind = profile.Kind,
            QualityLabel = qualityLabel,
            OutputFormat = formatLabel,
            CreatedAt = createdAt,
            UpdatedAt = createdAt
        };

        await _dispatcher.InvokeAsync(() => Records.Insert(0, record));

        lock (_sync)
        {
            _pendingDownloads.Enqueue(new QueuedDownload(record.Id, normalizedUrl, preferences.Clone(), profile));
        }

        await RefreshQueuedStatusesAsync();
        _diagnostics.Info($"Enqueued download {record.Id} for {normalizedUrl}");
        SchedulePersist();
        EnsureWorker();
        OnChanged();
    }

    public async Task RetryAsync(Guid recordId, DownloadPreferences preferences, CancellationToken cancellationToken = default)
    {
        var sourceUrl = await _dispatcher.InvokeAsync(() =>
            Records.FirstOrDefault(record => record.Id == recordId)?.SourceUrl);

        if (string.IsNullOrWhiteSpace(sourceUrl))
        {
            return;
        }

        await EnqueueAsync(sourceUrl, preferences, cancellationToken);
    }

    public async Task CancelAsync(Guid recordId)
    {
        bool cancelActive = false;
        bool removedFromQueue = false;

        lock (_sync)
        {
            if (_activeRecordId == recordId && _activeCancellation is not null)
            {
                cancelActive = true;
                _activeCancellation.Cancel();
            }
            else if (_pendingDownloads.Count > 0)
            {
                var items = _pendingDownloads.ToList();
                removedFromQueue = items.RemoveAll(item => item.RecordId == recordId) > 0;
                if (removedFromQueue)
                {
                    _pendingDownloads = new Queue<QueuedDownload>(items);
                }
            }
        }

        if (removedFromQueue)
        {
            await UpdateRecordAsync(recordId, record =>
            {
                record.Status = DownloadStatus.Cancelled;
                record.StatusMessage = "Cancelled";
                record.ErrorMessage = null;
                record.ProcessingStage = null;
                record.DownloadProgress = record.DownloadProgress ?? 0;
                record.UpdatedAt = DateTimeOffset.UtcNow;
            });
            await RefreshQueuedStatusesAsync();
        }

        if (cancelActive)
        {
            _diagnostics.Warning($"Cancellation requested for active download {recordId}");
        }
    }

    public async Task RemoveAsync(Guid recordId)
    {
        await CancelAsync(recordId);
        await _dispatcher.InvokeAsync(() =>
        {
            var item = Records.FirstOrDefault(record => record.Id == recordId);
            if (item is not null)
            {
                Records.Remove(item);
            }
        });

        SchedulePersist(immediate: true);
        OnChanged();
    }

    public Task FlushAsync(CancellationToken cancellationToken = default) => PersistNowAsync(cancellationToken);

    private void EnsureWorker()
    {
        lock (_sync)
        {
            if (_workerTask is { IsCompleted: false })
            {
                return;
            }

            _workerTask = Task.Run(ProcessQueueAsync);
        }
    }

    private async Task ProcessQueueAsync()
    {
        while (true)
        {
            QueuedDownload? next = null;
            CancellationTokenSource? activeCts = null;

            lock (_sync)
            {
                if (_activeCancellation is null && _pendingDownloads.Count > 0)
                {
                    next = _pendingDownloads.Dequeue();
                    activeCts = new CancellationTokenSource();
                    _activeCancellation = activeCts;
                    _activeRecordId = next.RecordId;
                }
                else if (_pendingDownloads.Count == 0)
                {
                    _workerTask = null;
                    return;
                }
            }

            if (next is null || activeCts is null)
            {
                await Task.Delay(100);
                continue;
            }

            try
            {
                await RunDownloadAsync(next, activeCts.Token);
            }
            finally
            {
                lock (_sync)
                {
                    _activeCancellation?.Dispose();
                    _activeCancellation = null;
                    _activeRecordId = null;
                }

                await RefreshQueuedStatusesAsync();
                SchedulePersist();
                OnChanged();
            }
        }
    }

    private async Task RunDownloadAsync(QueuedDownload request, CancellationToken cancellationToken)
    {
        await UpdateRecordAsync(request.RecordId, record =>
        {
            record.Status = DownloadStatus.Downloading;
            record.StatusMessage = "Preparing download...";
            record.Progress = 0.01;
            record.DownloadProgress = 0.01;
            record.ErrorMessage = null;
            record.ProcessingStage = DownloadProcessingStage.Preparing;
            record.DownloadedBytes = null;
            record.TotalBytes = null;
            record.AverageSpeedBytesPerSecond = null;
            record.FileSizeBytes = null;
            record.UpdatedAt = DateTimeOffset.UtcNow;
        });

        _diagnostics.Info($"Starting download {request.RecordId} for {request.Url}");

        try
        {
            var result = await _runtimeService.DownloadAsync(
                new DownloadRuntimeRequest(request.RecordId, request.Url, request.Preferences.Clone(), request.Profile),
                new Progress<DownloadProgressUpdate>(update =>
                {
                    _ = UpdateRecordAsync(request.RecordId, record =>
                    {
                        if (!string.IsNullOrWhiteSpace(update.StatusMessage))
                        {
                            record.StatusMessage = update.StatusMessage;
                        }

                        if (update.Stage is not null)
                        {
                            record.ProcessingStage = update.Stage;
                        }

                        if (update.ProgressFraction is { } progress)
                        {
                            var normalized = Math.Clamp(progress, 0, 1);
                            record.DownloadProgress = Math.Max(record.DownloadProgress ?? 0, normalized);
                            record.Progress = Math.Max(record.Progress, normalized);
                        }

                        if (update.Transfer is not null)
                        {
                            if (update.Transfer.DownloadedBytes is { } downloaded)
                            {
                                record.DownloadedBytes = Math.Max(record.DownloadedBytes ?? 0, downloaded);
                            }

                            if (update.Transfer.TotalBytes is { } total)
                            {
                                record.TotalBytes = total;
                                record.FileSizeBytes = total;
                            }

                            if (update.Transfer.AverageSpeedBytesPerSecond is { } speed)
                            {
                                record.AverageSpeedBytesPerSecond = Math.Max(speed, 0);
                            }
                        }

                        record.UpdatedAt = DateTimeOffset.UtcNow;
                    });
                }),
                metadata =>
                {
                    _ = UpdateRecordAsync(request.RecordId, record =>
                    {
                        if (!string.IsNullOrWhiteSpace(metadata.Title))
                        {
                            record.Title = metadata.Title;
                        }

                        if (metadata.DurationSeconds is not null)
                        {
                            record.DurationSeconds = metadata.DurationSeconds;
                        }

                        if (!string.IsNullOrWhiteSpace(metadata.ServiceName))
                        {
                            record.ServiceName = metadata.ServiceName;
                        }

                        if (!string.IsNullOrWhiteSpace(metadata.UploaderName))
                        {
                            record.UploaderName = metadata.UploaderName;
                        }

                        record.UpdatedAt = DateTimeOffset.UtcNow;
                    });
                },
                cancellationToken);

            await HandleCompletedFilesAsync(request, result.Files);
            _diagnostics.Info($"Completed download {request.RecordId} with {result.Files.Count} file(s)");
        }
        catch (OperationCanceledException)
        {
            await MarkCancelledAsync(request.RecordId);
        }
        catch (DownloadException ex) when (ex.Kind == DownloadFailureKind.Cancelled)
        {
            await MarkCancelledAsync(request.RecordId);
        }
        catch (Exception ex)
        {
            _diagnostics.Error($"Download {request.RecordId} failed: {ex.Message}");
            await UpdateRecordAsync(request.RecordId, record =>
            {
                record.Status = DownloadStatus.Failed;
                record.StatusMessage = "Download failed";
                record.ErrorMessage = ex.Message;
                record.ProcessingStage = null;
                record.UpdatedAt = DateTimeOffset.UtcNow;
            });
        }
    }

    private async Task MarkCancelledAsync(Guid recordId)
    {
        _diagnostics.Warning($"Download {recordId} was cancelled");
        await UpdateRecordAsync(recordId, record =>
        {
            record.Status = DownloadStatus.Cancelled;
            record.StatusMessage = "Cancelled";
            record.ErrorMessage = null;
            record.ProcessingStage = null;
            record.UpdatedAt = DateTimeOffset.UtcNow;
        });
    }

    private async Task HandleCompletedFilesAsync(QueuedDownload request, IReadOnlyList<CompletedFile> files)
    {
        var primaryFile = files.FirstOrDefault();
        await UpdateRecordAsync(request.RecordId, record =>
        {
            record.Status = DownloadStatus.Completed;
            record.StatusMessage = "Completed";
            record.Progress = 1;
            record.DownloadProgress = 1;
            record.ProcessingStage = null;
            record.ErrorMessage = null;
            record.UpdatedAt = DateTimeOffset.UtcNow;
            if (primaryFile is not null)
            {
                record.FilePath = primaryFile.Path;
                record.FileSizeBytes = primaryFile.FileSizeBytes;
                record.DownloadedBytes = primaryFile.FileSizeBytes;
                record.TotalBytes = primaryFile.FileSizeBytes;
                record.AverageSpeedBytesPerSecond = null;
                if (!string.IsNullOrWhiteSpace(primaryFile.Title))
                {
                    record.Title = primaryFile.Title;
                }

                if (primaryFile.DurationSeconds is not null)
                {
                    record.DurationSeconds = primaryFile.DurationSeconds;
                }

                if (!string.IsNullOrWhiteSpace(primaryFile.Ext))
                {
                    record.OutputFormat = primaryFile.Ext.ToUpperInvariant();
                }

                if (!string.IsNullOrWhiteSpace(primaryFile.Resolution))
                {
                    record.QualityLabel = primaryFile.Resolution;
                }
            }
        });

        if (files.Count <= 1)
        {
            return;
        }

        var extras = files.Skip(1).Select(file => new DownloadRecord
        {
            Id = Guid.NewGuid(),
            SourceUrl = request.Url,
            ServiceName = _runtimeService.InferServiceName(request.Url),
            Title = string.IsNullOrWhiteSpace(file.Title)
                ? Path.GetFileNameWithoutExtension(file.Path)
                : file.Title,
            DurationSeconds = file.DurationSeconds,
            Status = DownloadStatus.Completed,
            StatusMessage = "Completed",
            Progress = 1,
            DownloadProgress = 1,
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
            Kind = request.Profile.Kind,
            QualityLabel = string.IsNullOrWhiteSpace(file.Resolution) ? GetQualityLabel(request.Profile.Quality) : file.Resolution,
            OutputFormat = string.IsNullOrWhiteSpace(file.Ext) ? request.Profile.OutputFormatLabel : file.Ext.ToUpperInvariant(),
            FilePath = file.Path,
            FileSizeBytes = file.FileSizeBytes,
            DownloadedBytes = file.FileSizeBytes,
            TotalBytes = file.FileSizeBytes
        }).ToList();

        await _dispatcher.InvokeAsync(() =>
        {
            foreach (var extra in extras)
            {
                Records.Insert(0, extra);
            }
        });
    }

    private async Task UpdateRecordAsync(Guid recordId, Action<DownloadRecord> mutate)
    {
        await _dispatcher.InvokeAsync(() =>
        {
            var record = Records.FirstOrDefault(item => item.Id == recordId);
            if (record is null)
            {
                return;
            }

            mutate(record);
        });

        SchedulePersist();
        OnChanged();
    }

    private async Task RefreshQueuedStatusesAsync()
    {
        Dictionary<Guid, int> positions;
        lock (_sync)
        {
            positions = _pendingDownloads
                .Select((item, index) => new { item.RecordId, Position = index + 1 })
                .ToDictionary(item => item.RecordId, item => item.Position);
        }

        await _dispatcher.InvokeAsync(() =>
        {
            foreach (var record in Records.Where(item => item.Status == DownloadStatus.Queued))
            {
                record.StatusMessage = positions.TryGetValue(record.Id, out var position)
                    ? $"Queued #{position}"
                    : "Queued";
                record.UpdatedAt = DateTimeOffset.UtcNow;
            }
        });

        OnChanged();
    }

    private void SchedulePersist(bool immediate = false)
    {
        CancellationTokenSource? previous;
        CancellationTokenSource current;
        lock (_sync)
        {
            previous = _saveDebounceCts;
            current = new CancellationTokenSource();
            _saveDebounceCts = current;
        }

        previous?.Cancel();
        previous?.Dispose();

        _ = Task.Run(async () =>
        {
            try
            {
                if (!immediate)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(500), current.Token);
                }

                await PersistNowAsync(current.Token);
            }
            catch (OperationCanceledException)
            {
            }
        });
    }

    private async Task PersistNowAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await _dispatcher.InvokeAsync(() =>
            Records
                .OrderByDescending(record => record.UpdatedAt)
                .Select(record => record.Clone())
                .ToList());

        await _historyRepository.SaveAsync(snapshot, cancellationToken);
    }

    private void OnChanged()
    {
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private static string GetQualityLabel(QualityPreset quality) => quality switch
    {
        QualityPreset.P720 => "720p",
        QualityPreset.P1080 => "1080p",
        QualityPreset.P4K => "4K",
        QualityPreset.P8K => "8K",
        _ => "Best"
    };

    private sealed record QueuedDownload(
        Guid RecordId,
        string Url,
        DownloadPreferences Preferences,
        ResolvedDownloadProfile Profile);
}
