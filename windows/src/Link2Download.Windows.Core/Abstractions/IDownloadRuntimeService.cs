using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Core.Abstractions;

public interface IDownloadRuntimeService
{
    bool ValidateUrl(string url);

    string NormalizeUrl(string url);

    string InferServiceName(string url);

    Task<DownloadExecutionResult> DownloadAsync(
        DownloadRuntimeRequest request,
        IProgress<DownloadProgressUpdate> progress,
        Action<DownloadDiscoveredMetadata>? onMetadata,
        CancellationToken cancellationToken);
}
