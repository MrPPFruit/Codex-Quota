using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed record CodexExecutableCandidate(string Path, string Signer);

internal sealed class WindowsCodexExecutableLocator
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(3);
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly Func<CancellationToken, Process[]> _findOfficial;

    internal WindowsCodexExecutableLocator(
        BoundedDiagnosticLog diagnostics,
        Func<CancellationToken, Process[]>? findOfficial = null)
    {
        _diagnostics = diagnostics;
        _findOfficial = findOfficial ?? WindowsCodexPackageProcesses.FindOfficial;
    }

    public async Task<CodexExecutableCandidate?> LocateAsync(CancellationToken cancellationToken)
    {
        if (!TryGetRunningCodexIdentity(cancellationToken, out var expectedThumbprint, out var packageRoot, out var identityFailure))
        {
            _diagnostics.Write("locator", identityFailure);
            return null;
        }

        foreach (var candidate in EnumerateCandidates(packageRoot))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsSafeRegularFile(candidate) ||
                !AuthenticodePolicy.TryVerify(candidate, out var signer, out var thumbprint) ||
                !CryptographicOperations.FixedTimeEquals(
                    Convert.FromHexString(expectedThumbprint),
                    Convert.FromHexString(thumbprint)))
            {
                continue;
            }

            if (await SupportsAppServerAsync(candidate, cancellationToken).ConfigureAwait(false))
            {
                _diagnostics.Write("locator", $"Trusted OpenAI helper accepted ({signer})");
                return new CodexExecutableCandidate(candidate, signer);
            }
        }

        _diagnostics.Write("locator", "No trusted OpenAI helper available");
        return null;
    }

    private static bool TryGetRunningCodexIdentity(
        CancellationToken cancellationToken,
        out string thumbprint,
        out string packageRoot,
        out string failure)
    {
        thumbprint = string.Empty;
        packageRoot = string.Empty;
        failure = "Official OpenAI desktop package process unavailable";
        var processes = _findOfficial(cancellationToken);
        try
        {
            if (processes.Length == 0) return false;
            failure = "Official OpenAI package executable unavailable";
            foreach (var process in processes)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try
                {
                    var executable = process.MainModule?.FileName;
                    if (string.IsNullOrWhiteSpace(executable) ||
                        !AuthenticodePolicy.TryVerify(executable, out _, out thumbprint)) continue;
                    failure = "Official OpenAI package root unavailable";
                    if (!TryResolveProtectedPackageRoot(executable, out packageRoot)) continue;
                    return true;
                }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException)
                {
                }
            }
        }
        finally
        {
            foreach (var process in processes) process.Dispose();
        }
        return false;
    }

    private static bool TryResolveProtectedPackageRoot(string processExecutable, out string packageRoot)
    {
        packageRoot = string.Empty;
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles)) return false;
        var windowsApps = Path.GetFullPath(Path.Combine(programFiles, "WindowsApps"))
            .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var executable = Path.GetFullPath(processExecutable);
        if (!executable.StartsWith(windowsApps, StringComparison.OrdinalIgnoreCase)) return false;
        var relative = executable[windowsApps.Length..];
        var separator = relative.IndexOf(Path.DirectorySeparatorChar);
        if (separator <= 0) return false;
        var packageDirectory = relative[..separator];
        if (!packageDirectory.StartsWith("OpenAI.Codex_", StringComparison.Ordinal)) return false;
        packageRoot = Path.Combine(windowsApps, packageDirectory);
        return Directory.Exists(packageRoot) && !IsReparsePoint(packageRoot);
    }

    private static IEnumerable<string> EnumerateCandidates(string packageRoot)
    {
        var candidates = new[]
        {
            Path.Combine(packageRoot, "app", "resources", "codex.exe"),
            Path.Combine(packageRoot, "resources", "codex.exe"),
        };
        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            yield return candidate;
        }
    }

    private static bool IsSafeRegularFile(string path)
    {
        try
        {
            var fullPath = Path.GetFullPath(path);
            if (!File.Exists(fullPath) || IsReparsePoint(fullPath))
            {
                return false;
            }

            for (var current = Directory.GetParent(fullPath); current is not null; current = current.Parent)
            {
                if (IsReparsePoint(current.FullName))
                {
                    return false;
                }
            }

            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static async Task<bool> SupportsAppServerAsync(string executable, CancellationToken cancellationToken)
    {
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        process.StartInfo.ArgumentList.Add("app-server");
        process.StartInfo.ArgumentList.Add("--help");

        try
        {
            if (!process.Start())
            {
                return false;
            }

            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(ProbeTimeout);
            var stdoutTask = DrainBoundedAsync(process.StandardOutput.BaseStream, deadline.Token);
            var stderrTask = DrainBoundedAsync(process.StandardError.BaseStream, deadline.Token);
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            var output = (await stdoutTask.ConfigureAwait(false)) + (await stderrTask.ConfigureAwait(false));
            return process.ExitCode == 0 && output.Contains("stdio", StringComparison.OrdinalIgnoreCase);
        }
        catch (OperationCanceledException)
        {
            if (!process.HasExited)
            {
                _ = await StopOwnedProcessAsync(process).ConfigureAwait(false);
            }
            return false;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException)
        {
            return false;
        }
    }

    private static async Task<string> DrainBoundedAsync(Stream stream, CancellationToken cancellationToken)
    {
        const int retainedLimit = 65_536;
        var retained = new MemoryStream(retainedLimit);
        var buffer = new byte[4096];
        int count;
        while ((count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) > 0)
        {
            var retain = Math.Min(count, retainedLimit - checked((int)retained.Length));
            if (retain > 0) retained.Write(buffer, 0, retain);
        }
        return Encoding.UTF8.GetString(retained.GetBuffer(), 0, checked((int)retained.Length));
    }

    private static async Task<bool> StopOwnedProcessAsync(Process process)
    {
        try
        {
            if (process.HasExited) return true;
            process.Kill(entireProcessTree: true);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            return process.HasExited;
        }
        catch (InvalidOperationException) when (process.HasExited)
        {
            return true;
        }
        catch (Exception error) when (error is Win32Exception or OperationCanceledException)
        {
            return false;
        }
    }
}

internal static class AuthenticodePolicy
{
    public static bool TryVerify(string path, out string signer, out string thumbprint)
    {
        signer = "signed publisher";
        thumbprint = string.Empty;
        var fileInfo = new WinTrustFileInfo(path);
        var data = new WinTrustData(fileInfo);
        try
        {
            if (NativeMethods.WinVerifyTrust(IntPtr.Zero, NativeMethods.WinTrustActionGenericVerifyV2, ref data) != 0)
            {
                return false;
            }

#pragma warning disable SYSLIB0057
            using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            signer = certificate.GetNameInfo(X509NameType.SimpleName, false);
            thumbprint = certificate.Thumbprint;
            return !string.IsNullOrWhiteSpace(thumbprint);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or FormatException)
        {
            return false;
        }
        finally
        {
            data.Dispose();
            fileInfo.Dispose();
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo : IDisposable
    {
        private readonly uint StructSize;
        private readonly IntPtr FilePath;
        private readonly IntPtr FileHandle;
        private readonly IntPtr KnownSubject;

        public WinTrustFileInfo(string path)
        {
            StructSize = (uint)Marshal.SizeOf<WinTrustFileInfo>();
            FilePath = Marshal.StringToCoTaskMemUni(path);
            FileHandle = IntPtr.Zero;
            KnownSubject = IntPtr.Zero;
        }

        public void Dispose() => Marshal.FreeCoTaskMem(FilePath);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustData : IDisposable
    {
        private readonly uint StructSize;
        private readonly IntPtr PolicyCallbackData;
        private readonly IntPtr SIPClientData;
        private readonly uint UIChoice;
        private readonly uint RevocationChecks;
        private readonly uint UnionChoice;
        private readonly IntPtr FileInfo;
        private readonly uint StateAction;
        private readonly IntPtr StateData;
        private readonly IntPtr URLReference;
        private readonly uint ProviderFlags;
        private readonly uint UIContext;

        public WinTrustData(WinTrustFileInfo fileInfo)
        {
            StructSize = (uint)Marshal.SizeOf<WinTrustData>();
            PolicyCallbackData = IntPtr.Zero;
            SIPClientData = IntPtr.Zero;
            UIChoice = 2;
            RevocationChecks = 0;
            UnionChoice = 1;
            FileInfo = Marshal.AllocCoTaskMem(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, FileInfo, false);
            StateAction = 0;
            StateData = IntPtr.Zero;
            URLReference = IntPtr.Zero;
            ProviderFlags = 0x00000010;
            UIContext = 0;
        }

        public void Dispose() => Marshal.FreeCoTaskMem(FileInfo);
    }

    private static class NativeMethods
    {
        public static readonly Guid WinTrustActionGenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

        [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
        internal static extern int WinVerifyTrust(IntPtr window, [MarshalAs(UnmanagedType.LPStruct)] Guid action, ref WinTrustData data);
    }
}
