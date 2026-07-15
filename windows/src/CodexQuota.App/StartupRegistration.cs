using System.IO;
using System.Security;
using Microsoft.Win32;

namespace CodexQuota.App;

internal sealed class StartupRegistration
{
    private const string RegistryPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "CodexQuota";
    private const string PreferencePath = @"Software\CodexQuota";
    private const string PreferenceName = "LaunchAtLogin";

    public bool IsEnabled
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.CreateSubKey(RegistryPath, writable: false);
                return run?.GetValue(ValueName) is string value &&
                    string.Equals(value, CurrentCommand(), StringComparison.Ordinal);
            }
            catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
            {
                return false;
            }
        }
    }

    public bool ShouldEnableAtLaunch
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(PreferencePath, writable: false);
                return key?.GetValue(PreferenceName) is not int value || value != 0;
            }
            catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
            {
                return false;
            }
        }
    }

    public StartupMenuPresentation MenuPresentation =>
        StartupMenuPresentation.Create(CanRegisterCurrentExecutable(), IsEnabled);

    public bool CanRegisterCurrentExecutable()
    {
        try
        {
            var executable = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(executable)) return false;
            var full = Path.GetFullPath(executable);
            var allowedRoots = new[]
            {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            }.Where(root => !string.IsNullOrWhiteSpace(root)).Select(CanonicalDirectoryPrefix).ToArray();
            if (!allowedRoots.Any(root => full.StartsWith(root, StringComparison.OrdinalIgnoreCase)) ||
                new FileInfo(full).Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
            for (var directory = Directory.GetParent(full); directory is not null; directory = directory.Parent)
            {
                if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) return false;
            }
            return true;
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException or ArgumentException)
        {
            return false;
        }
    }

    public bool SetEnabled(bool enabled)
    {
        try
        {
            if (enabled && !CanRegisterCurrentExecutable()) return false;
            using var preference = Registry.CurrentUser.CreateSubKey(PreferencePath, writable: true);
            using var run = Registry.CurrentUser.CreateSubKey(RegistryPath, writable: true);
            var previousPreference = preference.GetValue(PreferenceName);
            var previousRun = run.GetValue(ValueName);
            try
            {
                if (enabled) run.SetValue(ValueName, CurrentCommand(), RegistryValueKind.String);
                else run.DeleteValue(ValueName, throwOnMissingValue: false);
                preference.SetValue(PreferenceName, enabled ? 1 : 0, RegistryValueKind.DWord);
            }
            catch
            {
                RestoreValue(run, ValueName, previousRun);
                RestoreValue(preference, PreferenceName, previousPreference);
                throw;
            }
            if (!enabled)
            {
                return true;
            }
            return true;
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    private static string CanonicalDirectoryPrefix(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

    private static string CurrentCommand() =>
        Environment.ProcessPath is { } executable
            ? $"\"{Path.GetFullPath(executable)}\" --background"
            : string.Empty;

    private static void RestoreValue(RegistryKey key, string name, object? value)
    {
        try
        {
            if (value is null) key.DeleteValue(name, throwOnMissingValue: false);
            else key.SetValue(name, value);
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException)
        {
        }
    }
}
