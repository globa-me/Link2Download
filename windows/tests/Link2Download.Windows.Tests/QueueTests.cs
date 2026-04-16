using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;
using Link2Download.Windows.Core.Services;

namespace Link2Download.Windows.Tests;

public sealed class QueueTests
{
    [Fact]
    public async Task ManagerProcessesOnlyOneActiveDownloadAtATime()
    {
        var runtime = new ControlledRuntimeService();
        var history = new InMemoryHistoryRepository();
        var manager = new DownloadManager(runtime, history, new NullLogger(), new InlineDispatcher());
        await manager.InitializeAsync();

        var settings = DownloadPreferences.CreateDefault();
        await manager.EnqueueAsync("https://example.com/video-1", settings.Clone());
        await manager.EnqueueAsync("https://example.com/video-2", settings.Clone());

        await WaitUntilAsync(() => runtime.Pending.Count == 1);
        Assert.Equal(1, manager.Records.Count(record => record.Status == DownloadStatus.Downloading));
        Assert.Equal(1, manager.Records.Count(record => record.Status == DownloadStatus.Queued));
        Assert.Equal(1, runtime.MaxConcurrentCalls);

        runtime.Pending[0].TrySetResult(new DownloadExecutionResult(
        [
            new CompletedFile("C:\\temp\\video-1.mp4", "Video 1", "mp4", 60, "1080p", 1024)
        ]));

        await WaitUntilAsync(() => runtime.Pending.Count == 2);
        Assert.Equal(2, runtime.StartedIds.Count);
        Assert.Equal(1, runtime.MaxConcurrentCalls);

        runtime.Pending[1].TrySetResult(new DownloadExecutionResult(
        [
            new CompletedFile("C:\\temp\\video-2.mp4", "Video 2", "mp4", 120, "720p", 2048)
        ]));

        await WaitUntilAsync(() => manager.Records.Count(record => record.Status == DownloadStatus.Completed) == 2);
        Assert.All(manager.Records, record => Assert.Equal(DownloadStatus.Completed, record.Status));
        Assert.Equal(1, runtime.MaxConcurrentCalls);
    }

    private static async Task WaitUntilAsync(Func<bool> predicate, int timeoutMs = 5000)
    {
        var started = DateTimeOffset.UtcNow;
        while (!predicate())
        {
            if ((DateTimeOffset.UtcNow - started).TotalMilliseconds > timeoutMs)
            {
                throw new TimeoutException("Condition was not met in time.");
            }

            await Task.Delay(25);
        }
    }

    private sealed class ControlledRuntimeService : IDownloadRuntimeService
    {
        private int _activeCalls;

        public List<Guid> StartedIds { get; } = [];

        public List<TaskCompletionSource<DownloadExecutionResult>> Pending { get; } = [];

        public int MaxConcurrentCalls { get; private set; }

        public bool ValidateUrl(string url) => true;

        public string NormalizeUrl(string url) => url;

        public string InferServiceName(string url) => "Example";

        public async Task<DownloadExecutionResult> DownloadAsync(
            DownloadRuntimeRequest request,
            IProgress<DownloadProgressUpdate> progress,
            Action<DownloadDiscoveredMetadata>? onMetadata,
            CancellationToken cancellationToken)
        {
            var tcs = new TaskCompletionSource<DownloadExecutionResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (Pending)
            {
                Pending.Add(tcs);
                StartedIds.Add(request.RecordId);
                _activeCalls++;
                MaxConcurrentCalls = Math.Max(MaxConcurrentCalls, _activeCalls);
            }

            onMetadata?.Invoke(new DownloadDiscoveredMetadata("Queued item", 42, "Example", "Tester"));
            progress.Report(new DownloadProgressUpdate(0.2, "Downloading...", null, DownloadProcessingStage.Downloading));

            using var registration = cancellationToken.Register(() => tcs.TrySetCanceled(cancellationToken));
            try
            {
                return await tcs.Task;
            }
            finally
            {
                lock (Pending)
                {
                    _activeCalls--;
                }
            }
        }
    }

    private sealed class InMemoryHistoryRepository : IHistoryRepository
    {
        public List<DownloadRecord> Records { get; private set; } = [];

        public Task<IReadOnlyList<DownloadRecord>> LoadAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<DownloadRecord>>(Records.Select(record => record.Clone()).ToList());
        }

        public Task SaveAsync(IReadOnlyList<DownloadRecord> records, CancellationToken cancellationToken = default)
        {
            Records = records.Select(record => record.Clone()).ToList();
            return Task.CompletedTask;
        }
    }

    private sealed class InlineDispatcher : IUiDispatcher
    {
        public Task InvokeAsync(Action action)
        {
            action();
            return Task.CompletedTask;
        }

        public Task<T> InvokeAsync<T>(Func<T> action)
        {
            return Task.FromResult(action());
        }
    }

    private sealed class NullLogger : IDiagnosticsLogger
    {
        public string LogFilePath => "test.log";

        public void Error(string message)
        {
        }

        public void Info(string message)
        {
        }

        public void Warning(string message)
        {
        }
    }
}
