using System.Text;
using Link2Download.Windows.Core.Abstractions;

namespace Link2Download.Windows.Infrastructure.Diagnostics;

public sealed class FileDiagnosticsLogger : IDiagnosticsLogger
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly long _maxBytes;
    private readonly long _retainBytes;

    public FileDiagnosticsLogger(string logFilePath, long maxBytes = 2_000_000, long retainBytes = 1_200_000)
    {
        LogFilePath = logFilePath;
        _maxBytes = maxBytes;
        _retainBytes = retainBytes;

        var directory = Path.GetDirectoryName(logFilePath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        if (!File.Exists(logFilePath))
        {
            File.WriteAllText(logFilePath, string.Empty, Encoding.UTF8);
        }

        Info($"Diagnostics started on {Environment.OSVersion} at {AppContext.BaseDirectory}");
    }

    public string LogFilePath { get; }

    public void Info(string message) => Write("INFO", message);

    public void Warning(string message) => Write("WARN", message);

    public void Error(string message) => Write("ERROR", message);

    private void Write(string level, string message)
    {
        var normalized = message
            .Replace("\r\n", " | ", StringComparison.Ordinal)
            .Replace('\n', ' ')
            .Trim();

        if (string.IsNullOrWhiteSpace(normalized))
        {
            return;
        }

        var line = $"[{DateTimeOffset.UtcNow:O}] [{level}] {normalized}{Environment.NewLine}";
        _ = Task.Run(async () =>
        {
            await _gate.WaitAsync();
            try
            {
                await File.AppendAllTextAsync(LogFilePath, line, Encoding.UTF8);
                await TruncateIfNeededAsync();
            }
            finally
            {
                _gate.Release();
            }
        });
    }

    private async Task TruncateIfNeededAsync()
    {
        var info = new FileInfo(LogFilePath);
        if (!info.Exists || info.Length <= _maxBytes)
        {
            return;
        }

        await using var stream = new FileStream(LogFilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (stream.Length <= _retainBytes)
        {
            return;
        }

        stream.Seek(-_retainBytes, SeekOrigin.End);
        using var memory = new MemoryStream();
        await stream.CopyToAsync(memory);
        await File.WriteAllBytesAsync(LogFilePath, memory.ToArray());
    }
}
