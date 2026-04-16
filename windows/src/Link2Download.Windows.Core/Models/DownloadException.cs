namespace Link2Download.Windows.Core.Models;

public sealed class DownloadException : Exception
{
    public DownloadException(
        DownloadFailureKind kind,
        string message,
        IReadOnlyList<string>? missingTools = null,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        MissingTools = missingTools;
    }

    public DownloadFailureKind Kind { get; }

    public IReadOnlyList<string>? MissingTools { get; }
}
