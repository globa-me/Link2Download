using Link2Download.Windows.Core.Models;
using Link2Download.Windows.Core.Services;

namespace Link2Download.Windows.Tests;

public sealed class DiagnosticLogSanitizerTests
{
    [Fact]
    public void RedactUrlsRemovesQueryAndFragmentValues()
    {
        var message = "Downloading https://example.com/watch/video?id=123&token=secret#private";

        var redacted = DiagnosticLogSanitizer.RedactUrls(message);

        Assert.Equal("Downloading https://example.com/watch/video?[redacted]#[redacted]", redacted);
        Assert.DoesNotContain("secret", redacted);
        Assert.DoesNotContain("123", redacted);
        Assert.DoesNotContain("private", redacted);
    }

    [Fact]
    public void DefaultPreferencesDoNotUseBrowserCookiesAutomatically()
    {
        var preferences = DownloadPreferences.CreateDefault();

        Assert.Equal(BrowserCookieSource.None, preferences.CookieSource);
    }
}
