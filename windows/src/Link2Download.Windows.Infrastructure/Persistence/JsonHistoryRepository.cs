using System.Text.Json;
using Link2Download.Windows.Core.Abstractions;
using Link2Download.Windows.Core.Models;

namespace Link2Download.Windows.Infrastructure.Persistence;

public sealed class JsonHistoryRepository : IHistoryRepository
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true
    };

    private readonly string _path;

    public JsonHistoryRepository(string path)
    {
        _path = path;
    }

    public async Task<IReadOnlyList<DownloadRecord>> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_path))
        {
            return [];
        }

        await using var stream = File.OpenRead(_path);
        var records = await JsonSerializer.DeserializeAsync<List<DownloadRecord>>(stream, SerializerOptions, cancellationToken);
        return records ?? [];
    }

    public async Task SaveAsync(IReadOnlyList<DownloadRecord> records, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        await using var stream = File.Create(_path);
        await JsonSerializer.SerializeAsync(stream, records, SerializerOptions, cancellationToken);
    }
}
