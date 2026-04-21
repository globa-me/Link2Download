using Link2Download.Windows.Core.Models;
using Link2Download.Windows.Infrastructure.Runtime;

namespace Link2Download.Windows.Tests;

public sealed class YtDlpArgumentsBuilderTests
{
    [Fact]
    public void BuildForVideoIncludesUtf8AndSingleVideoFlags()
    {
        var preferences = new DownloadPreferences
        {
            SaveDirectory = @"C:\Temp\Link2Download"
        };
        var profile = new ResolvedDownloadProfile(
            DownloadKind.Video,
            VideoFormat.Mp4,
            AudioFormat.M4a,
            QualityPreset.Best,
            IncludeSubtitles: false,
            IncludeAdditionalAudioTracks: false);
        var request = new DownloadRuntimeRequest(
            Guid.NewGuid(),
            "https://www.youtube.com/watch?v=abc123&list=def456",
            preferences,
            profile);

        var arguments = YtDlpArgumentsBuilder.Build(request, BrowserCookieSource.None, @"C:\Tools");

        Assert.Contains("--no-playlist", arguments);
        Assert.Contains("--encoding utf-8", arguments);
        Assert.Contains("--merge-output-format mp4", arguments);
        Assert.Contains("--ffmpeg-location C:\\Tools", arguments);
    }

    [Fact]
    public void BuildAddsBrowserCookiesWhenRequested()
    {
        var preferences = new DownloadPreferences
        {
            SaveDirectory = @"C:\Temp\Link2Download"
        };
        var profile = new ResolvedDownloadProfile(
            DownloadKind.Audio,
            VideoFormat.Mp4,
            AudioFormat.Mp3,
            QualityPreset.Best,
            IncludeSubtitles: false,
            IncludeAdditionalAudioTracks: false);
        var request = new DownloadRuntimeRequest(
            Guid.NewGuid(),
            "https://example.com/media",
            preferences,
            profile);

        var arguments = YtDlpArgumentsBuilder.Build(request, BrowserCookieSource.Firefox, @"C:\Tools");

        Assert.Contains("--cookies-from-browser firefox", arguments);
        Assert.Contains("--audio-format mp3", arguments);
    }
}
