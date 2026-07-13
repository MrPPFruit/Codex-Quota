using System.Globalization;
using System.IO;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class BoundedDiagnosticLog
{
    private const long MaximumBytes = 262_144;
    private readonly object _gate = new();
    private readonly string? _path;

    public BoundedDiagnosticLog()
    {
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localData))
        {
            return;
        }

        var directory = Path.Combine(localData, "CodexQuota", "Logs");
        try
        {
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
            {
                return;
            }

            _path = Path.Combine(directory, "current.log");
        }
        catch (IOException)
        {
            _path = null;
        }
        catch (UnauthorizedAccessException)
        {
            _path = null;
        }
    }

    public string? DirectoryPath => _path is null ? null : Path.GetDirectoryName(_path);

    public void Write(string category, string message)
    {
        if (_path is null)
        {
            return;
        }

        var sanitized = DiagnosticRedactor.Sanitize(
            message,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Path.GetTempPath());
        var line = string.Create(
            CultureInfo.InvariantCulture,
            $"{DateTimeOffset.UtcNow:O} [{category}] {sanitized}{Environment.NewLine}");

        lock (_gate)
        {
            try
            {
                if (File.Exists(_path) &&
                    ((File.GetAttributes(_path) & FileAttributes.ReparsePoint) != 0 ||
                     new FileInfo(_path).Length >= MaximumBytes))
                {
                    File.Delete(_path);
                }

                File.AppendAllText(_path, line);
            }
            catch (IOException)
            {
                // Diagnostics must never change product behavior.
            }
            catch (UnauthorizedAccessException)
            {
                // A managed machine may forbid local diagnostics.
            }
        }
    }
}
