using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Core.Abstractions;

public interface ISettingsRepository
{
    Task<DownloadPreferences?> LoadAsync(CancellationToken cancellationToken = default);

    Task SaveAsync(DownloadPreferences settings, CancellationToken cancellationToken = default);
}
