using System.Text.RegularExpressions;

namespace Link2Download.Windows.Core.Services;

public static class DiagnosticLogSanitizer
{
    private static readonly Regex HttpUrlPattern = new(
        @"https?://[^\s""'<>]+",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static string RedactUrls(string message)
    {
        return HttpUrlPattern.Replace(message, match => RedactUrl(match.Value));
    }

    public static string RedactUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps))
        {
            return url;
        }

        var builder = new UriBuilder(uri)
        {
            Query = string.Empty,
            Fragment = string.Empty
        };

        var redacted = builder.Uri.GetLeftPart(UriPartial.Path);
        if (!string.IsNullOrEmpty(uri.Query))
        {
            redacted += "?[redacted]";
        }

        if (!string.IsNullOrEmpty(uri.Fragment))
        {
            redacted += "#[redacted]";
        }

        return redacted;
    }
}
