using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Core.Abstractions;

public interface IHistoryRepository
{
    Task<IReadOnlyList<DownloadRecord>> LoadAsync(CancellationToken cancellationToken = default);

    Task SaveAsync(IReadOnlyList<DownloadRecord> records, CancellationToken cancellationToken = default);
}
