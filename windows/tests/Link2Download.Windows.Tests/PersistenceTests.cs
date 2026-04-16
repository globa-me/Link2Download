using Link2Download.Windows.Core.Models;
using Link2Download.Windows.Infrastructure.Persistence;

namespace Link2Download.Windows.Tests;

public sealed class PersistenceTests
{
    [Fact]
    public async Task SettingsRepositoryRoundTripsPreferences()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var repository = new JsonSettingsRepository(Path.Combine(tempRoot, "settings.json"));
            var settings = DownloadPreferences.CreateDefault();
            settings.Kind = DownloadKind.Audio;
            settings.AudioFormat = AudioFormat.Ogg;
            settings.CookieSource = BrowserCookieSource.Edge;
            settings.IncludeSubtitles = true;

            await repository.SaveAsync(settings);
            var loaded = await repository.LoadAsync();

            Assert.NotNull(loaded);
            Assert.Equal(DownloadKind.Audio, loaded!.Kind);
            Assert.Equal(AudioFormat.Ogg, loaded.AudioFormat);
            Assert.Equal(BrowserCookieSource.Edge, loaded.CookieSource);
            Assert.True(loaded.IncludeSubtitles);
        }
        finally
        {
            Directory.Delete(tempRoot, recursive: true);
        }
    }

    [Fact]
    public async Task HistoryRepositoryRoundTripsDownloadRecords()
    {
        var tempRoot = CreateTempDirectory();
        try
        {
            var repository = new JsonHistoryRepository(Path.Combine(tempRoot, "history.json"));
            var records = new List<DownloadRecord>
            {
                new()
                {
                    Id = Guid.NewGuid(),
                    SourceUrl = "https://example.com/video",
                    ServiceName = "Example",
                    Title = "Test video",
                    Status = DownloadStatus.Completed,
                    StatusMessage = "Completed",
                    Progress = 1,
                    DownloadProgress = 1,
                    Kind = DownloadKind.Video,
                    QualityLabel = "1080p",
                    OutputFormat = "MP4",
                    FilePath = "C:\\temp\\video.mp4",
                    FileSizeBytes = 4096,
                    CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-5),
                    UpdatedAt = DateTimeOffset.UtcNow
                }
            };

            await repository.SaveAsync(records);
            var loaded = await repository.LoadAsync();

            Assert.Single(loaded);
            Assert.Equal("Test video", loaded[0].Title);
            Assert.Equal("C:\\temp\\video.mp4", loaded[0].FilePath);
            Assert.Equal(4096, loaded[0].FileSizeBytes);
        }
        finally
        {
            Directory.Delete(tempRoot, recursive: true);
        }
    }

    private static string CreateTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "Link2Download.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }
}
