using System.Text.Json;
using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Infrastructure.Persistence;

public sealed class JsonSettingsRepository : ISettingsRepository
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _path;

    public JsonSettingsRepository(string path)
    {
        _path = path;
    }

    public async Task<DownloadPreferences?> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_path))
        {
            return null;
        }

        await using var stream = File.OpenRead(_path);
        return await JsonSerializer.DeserializeAsync<DownloadPreferences>(stream, SerializerOptions, cancellationToken);
    }

    public async Task SaveAsync(DownloadPreferences settings, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        await using var stream = File.Create(_path);
        await JsonSerializer.SerializeAsync(stream, settings, SerializerOptions, cancellationToken);
    }
}
