using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using CodexQuota.Core;
using Microsoft.Win32.SafeHandles;

namespace CodexQuota.App;

internal sealed class WindowsCodexProcessProbe(BoundedDiagnosticLog diagnostics) : ICodexProcessProbe
{
    public ValueTask<IObservedCodexProcess?> FindRunningAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var processes = Process.GetProcessesByName("Codex")
            .OrderBy(process => TryGetStartTime(process))
            .ToArray();
        Process? selectedProcess = null;
        try
        {
            foreach (var process in processes)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (TryGetPackageFamilyName(process.Id, out var familyName) &&
                    CodexPackagePolicy.IsOfficial(familyName))
                {
                    selectedProcess = process;
                    diagnostics.Write("presence", "Official Codex package process detected");
                    return ValueTask.FromResult<IObservedCodexProcess?>(new ObservedCodexProcess(process));
                }
            }
        }
        finally
        {
            foreach (var process in processes)
            {
                if (!ReferenceEquals(process, selectedProcess))
                {
                    process.Dispose();
                }
            }
        }

        return ValueTask.FromResult<IObservedCodexProcess?>(null);
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

    private sealed class ObservedCodexProcess(Process process) : IObservedCodexProcess
    {
        public int ProcessId => process.Id;

        public Task WaitForExitAsync(CancellationToken cancellationToken) =>
            process.WaitForExitAsync(cancellationToken);

        public void Dispose() => process.Dispose();
    }

    private static class NativeMethods
    {
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const int ErrorSuccess = 0;
        public const int ErrorInsufficientBuffer = 122;

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
    }
}
