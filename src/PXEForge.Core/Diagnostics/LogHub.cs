using System.Collections.Concurrent;
using System.Text;

namespace PXEForge.Core.Diagnostics;

public enum LogLevel
{
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3
}

public sealed record LogEntry(DateTimeOffset Timestamp, LogLevel Level, string Component, string Message)
{
    public override string ToString() =>
        $"{Timestamp:HH:mm:ss.fff} [{Level.ToString().ToUpperInvariant(),-5}] {Component,-8} {Message}";
}

/// <summary>
/// In-memory ring buffer plus optional file sink. Thread safe.
/// </summary>
public sealed class LogHub
{
    private readonly ConcurrentQueue<LogEntry> _entries = new();
    private readonly int _capacity;
    private readonly object _fileLock = new();
    private string? _logFilePath;

    public LogHub(int capacity = 4000)
    {
        _capacity = capacity;
    }

    public event Action<LogEntry>? EntryWritten;

    public void AttachFile(string directory, string prefix = "pxeforge")
    {
        Directory.CreateDirectory(directory);
        _logFilePath = Path.Combine(directory, $"{prefix}-{DateTime.Now:yyyyMMdd}.log");
    }

    public void Debug(string component, string message) => Write(LogLevel.Debug, component, message);
    public void Info(string component, string message) => Write(LogLevel.Info, component, message);
    public void Warn(string component, string message) => Write(LogLevel.Warn, component, message);
    public void Error(string component, string message) => Write(LogLevel.Error, component, message);

    public void Write(LogLevel level, string component, string message)
    {
        var entry = new LogEntry(DateTimeOffset.Now, level, component, message);
        _entries.Enqueue(entry);
        while (_entries.Count > _capacity && _entries.TryDequeue(out _)) { }

        try
        {
            EntryWritten?.Invoke(entry);
        }
        catch
        {
            // A subscriber must never break logging.
        }

        if (_logFilePath is not null)
        {
            try
            {
                lock (_fileLock)
                {
                    File.AppendAllText(_logFilePath, entry + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch
            {
                // Logging to file is best effort.
            }
        }
    }

    public IReadOnlyList<LogEntry> Snapshot() => _entries.ToArray();

    public IReadOnlyList<LogEntry> Recent(int maxLines = 100)
    {
        var all = _entries.ToArray();
        if (all.Length <= maxLines) return all;
        return all.TakeLast(maxLines).ToArray();
    }

    public string AsText(int maxLines = 500) =>
        string.Join(Environment.NewLine, _entries.ToArray().TakeLast(maxLines).Select(e => e.ToString()));

    public void Clear()
    {
        while (_entries.TryDequeue(out _)) { }
    }
}
