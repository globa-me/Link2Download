namespace Link2Download.Windows.Core.Abstractions;

public interface IDiagnosticsLogger
{
    string LogFilePath { get; }

    void Info(string message);

    void Warning(string message);

    void Error(string message);
}
