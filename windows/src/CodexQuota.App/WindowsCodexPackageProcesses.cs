using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using CodexQuota.Core;
using Microsoft.Win32.SafeHandles;

namespace CodexQuota.App;

internal sealed record OfficialCodexPackageIdentity(
    string FamilyName,
    string FullName,
    string InstallPath);

internal static class WindowsCodexPackageProcesses
{
    internal delegate bool PackageFamilyReader(int processId, out string? familyName);
    internal delegate bool PackageIdentityReader(int processId, out OfficialCodexPackageIdentity? identity);

    internal static IReadOnlyList<string> DiscoveryNames { get; } = Array.AsReadOnly(new[] { "Codex", "ChatGPT" });

    internal static Process[] FindOfficial(CancellationToken cancellationToken) =>
        FindOfficial(cancellationToken, Process.GetProcessesByName, TryGetPackageFamilyName);

    internal static Process[] FindOfficial(
        CancellationToken cancellationToken,
        Func<string, Process[]> findByName,
        PackageFamilyReader readPackageFamily)
    {
        var candidates = new Dictionary<int, Process>();
        var official = new List<Process>();
        try
        {
            foreach (var name in DiscoveryNames)
            {
                cancellationToken.ThrowIfCancellationRequested();
                foreach (var process in findByName(name))
                {
                    int processId;
                    try
                    {
                        processId = process.Id;
                    }
                    catch (InvalidOperationException)
                    {
                        process.Dispose();
                        continue;
                    }

                    if (!candidates.TryAdd(processId, process))
                    {
                        process.Dispose();
                    }
                }
            }

            foreach (var entry in candidates.ToArray())
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!readPackageFamily(entry.Key, out var familyName) ||
                    !CodexPackagePolicy.IsOfficial(familyName))
                {
                    entry.Value.Dispose();
                    candidates.Remove(entry.Key);
                    continue;
                }

                official.Add(entry.Value);
                candidates.Remove(entry.Key);
            }

            official.Sort((left, right) => TryGetStartTime(left).CompareTo(TryGetStartTime(right)));
            return [.. official];
        }
        catch
        {
            foreach (var process in candidates.Values)
            {
                process.Dispose();
            }
            foreach (var process in official)
            {
                process.Dispose();
            }
            throw;
        }
    }

    private static DateTime TryGetStartTime(Process process)
    {
        try
        {
            return process.StartTime;
        }
        catch (Win32Exception)
        {
            return DateTime.MaxValue;
        }
        catch (InvalidOperationException)
        {
            return DateTime.MaxValue;
        }
    }

    internal static bool TryGetPackageFamilyName(int processId, out string? familyName)
    {
        familyName = null;
        using var process = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid)
        {
            return false;
        }

        uint length = 0;
        var first = NativeMethods.GetPackageFamilyName(process, ref length, null);
        if (first != NativeMethods.ErrorInsufficientBuffer || length <= 1)
        {
            return false;
        }

        var buffer = new StringBuilder(checked((int)length));
        var second = NativeMethods.GetPackageFamilyName(process, ref length, buffer);
        if (second != NativeMethods.ErrorSuccess)
        {
            return false;
        }

        familyName = buffer.ToString();
        return true;
    }

    internal static bool TryGetOfficialIdentity(int processId, out OfficialCodexPackageIdentity? identity)
    {
        identity = null;
        using var process = NativeMethods.OpenProcess(
            NativeMethods.ProcessQueryLimitedInformation,
            inheritHandle: false,
            processId);
        if (process.IsInvalid ||
            !TryReadPackageString(process, NativeMethods.GetPackageFamilyName, out var familyName) ||
            !CodexPackagePolicy.IsOfficial(familyName) ||
            !TryReadPackageString(process, NativeMethods.GetPackageFullName, out var fullName) ||
            !TryGetInstallPath(fullName, out var installPath))
        {
            return false;
        }

        identity = new OfficialCodexPackageIdentity(familyName, fullName, installPath);
        return true;
    }

    private delegate int ReadPackageString(
        SafeProcessHandle process,
        ref uint length,
        StringBuilder? buffer);

    private static bool TryReadPackageString(
        SafeProcessHandle process,
        ReadPackageString read,
        out string value)
    {
        value = string.Empty;
        uint length = 0;
        if (read(process, ref length, null) != NativeMethods.ErrorInsufficientBuffer || length <= 1)
        {
            return false;
        }

        var buffer = new StringBuilder(checked((int)length));
        if (read(process, ref length, buffer) != NativeMethods.ErrorSuccess)
        {
            return false;
        }

        value = buffer.ToString();
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryGetInstallPath(string fullName, out string installPath)
    {
        installPath = string.Empty;
        uint length = 0;
        if (NativeMethods.GetPackagePathByFullName2(
                fullName,
                NativeMethods.PackagePathTypeInstall,
                ref length,
                null) != NativeMethods.ErrorInsufficientBuffer || length <= 1)
        {
            return false;
        }

        var buffer = new StringBuilder(checked((int)length));
        if (NativeMethods.GetPackagePathByFullName2(
                fullName,
                NativeMethods.PackagePathTypeInstall,
                ref length,
                buffer) != NativeMethods.ErrorSuccess)
        {
            return false;
        }

        installPath = buffer.ToString();
        return Path.IsPathFullyQualified(installPath) && Directory.Exists(installPath);
    }

    private static class NativeMethods
    {
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const int ErrorSuccess = 0;
        public const int ErrorInsufficientBuffer = 122;
        public const int PackagePathTypeInstall = 0;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern SafeProcessHandle OpenProcess(
            uint processAccess,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
            int processId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetPackageFamilyName(
            SafeProcessHandle process,
            ref uint packageFamilyNameLength,
            StringBuilder? packageFamilyName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetPackageFullName(
            SafeProcessHandle process,
            ref uint packageFullNameLength,
            StringBuilder? packageFullName);

        [DllImport("kernelbase.dll", CharSet = CharSet.Unicode)]
        public static extern int GetPackagePathByFullName2(
            string packageFullName,
            int packagePathType,
            ref uint pathLength,
            StringBuilder? path);
    }
}
