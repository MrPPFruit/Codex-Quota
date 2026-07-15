using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed record AuthenticodeIdentity(string Signer, string Thumbprint);

internal sealed class CodexExecutableCandidate : IDisposable
{
    private IDisposable? _executionLease;

    internal CodexExecutableCandidate(string path, string signer, IDisposable? executionLease = null)
    {
        Path = path;
        Signer = signer;
        _executionLease = executionLease;
    }

    public string Path { get; }
    public string Signer { get; }

    public void Dispose() => Interlocked.Exchange(ref _executionLease, null)?.Dispose();
}

internal sealed class WindowsCodexExecutableLocator
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(3);
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly Func<CancellationToken, Process[]> _findOfficial;
    private readonly WindowsCodexPackageProcesses.PackageIdentityReader _readPackageIdentity;
    private readonly Func<Process, string?> _readExecutablePath;
    private readonly Func<string, AuthenticodeIdentity?> _verifyAuthenticode;
    private readonly Func<string, CancellationToken, Task<bool>> _supportsAppServer;
    private readonly string _localAppData;

    internal WindowsCodexExecutableLocator(
        BoundedDiagnosticLog diagnostics,
        Func<CancellationToken, Process[]>? findOfficial = null)
        : this(
            diagnostics,
            findOfficial ?? WindowsCodexPackageProcesses.FindOfficial,
            WindowsCodexPackageProcesses.TryGetOfficialIdentity,
            process => process.MainModule?.FileName,
            AuthenticodePolicy.Verify,
            supportsAppServer: null,
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData))
    {
    }

    internal WindowsCodexExecutableLocator(
        BoundedDiagnosticLog diagnostics,
        Func<CancellationToken, Process[]> findOfficial,
        WindowsCodexPackageProcesses.PackageIdentityReader readPackageIdentity,
        Func<Process, string?> readExecutablePath,
        Func<string, AuthenticodeIdentity?> verifyAuthenticode,
        Func<string, CancellationToken, Task<bool>>? supportsAppServer,
        string localAppData)
    {
        _diagnostics = diagnostics;
        _findOfficial = findOfficial;
        _readPackageIdentity = readPackageIdentity;
        _readExecutablePath = readExecutablePath;
        _verifyAuthenticode = verifyAuthenticode;
        _supportsAppServer = supportsAppServer ?? SupportsAppServerAsync;
        _localAppData = localAppData;
    }

    public async Task<CodexExecutableCandidate?> LocateAsync(CancellationToken cancellationToken)
    {
        if (!TryGetRunningCodexIdentity(cancellationToken, out var identity, out var identityFailure))
        {
            _diagnostics.Write("locator", identityFailure);
            return null;
        }

        if (!TryGetPackageHelperBaseline(identity!.InstallPath, out var baseline))
        {
            _diagnostics.Write("locator", "Official OpenAI package helper baseline unavailable");
            return null;
        }

        foreach (var candidate in EnumerateRuntimeCandidates())
        {
            cancellationToken.ThrowIfCancellationRequested();
            FileStream? lease = null;
            try
            {
                lease = new FileStream(
                    candidate,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize: 65_536,
                    FileOptions.SequentialScan);
                if (!IsSafeRegularFileWithinRoot(GetRuntimeRoot(), candidate) ||
                    !MatchesBaseline(lease, baseline.Hash))
                {
                    continue;
                }

                if (await _supportsAppServer(candidate, cancellationToken).ConfigureAwait(false))
                {
                    _diagnostics.Write("locator", $"Trusted OpenAI runtime accepted ({baseline.Signer})");
                    var accepted = new CodexExecutableCandidate(candidate, baseline.Signer, lease);
                    lease = null;
                    return accepted;
                }
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
            }
            finally
            {
                lease?.Dispose();
            }
        }

        _diagnostics.Write("locator", "No trusted OpenAI helper available");
        return null;
    }

    private bool TryGetRunningCodexIdentity(
        CancellationToken cancellationToken,
        out OfficialCodexPackageIdentity? identity,
        out string failure)
    {
        identity = null;
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
                    var executable = _readExecutablePath(process);
                    if (string.IsNullOrWhiteSpace(executable) ||
                        !_readPackageIdentity(process.Id, out var candidateIdentity) ||
                        candidateIdentity is null ||
                        !IsPathWithinRoot(candidateIdentity.InstallPath, executable))
                    {
                        failure = "Official OpenAI package identity or install path unavailable";
                        continue;
                    }

                    identity = candidateIdentity;
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

    private sealed record PackageHelperBaseline(string Signer, byte[] Hash);

    private bool TryGetPackageHelperBaseline(string packageRoot, out PackageHelperBaseline baseline)
    {
        baseline = null!;
        foreach (var helper in EnumeratePackageHelpers(packageRoot))
        {
            if (!IsSafeRegularFileWithinRoot(packageRoot, helper)) continue;
            var signature = _verifyAuthenticode(helper);
            if (signature is null) continue;
            try
            {
                using var stream = new FileStream(
                    helper,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read,
                    bufferSize: 65_536,
                    FileOptions.SequentialScan);
                baseline = new PackageHelperBaseline(signature.Signer, SHA256.HashData(stream));
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
            }
        }
        return false;
    }

    private static IEnumerable<string> EnumeratePackageHelpers(string packageRoot)
    {
        yield return Path.Combine(packageRoot, "app", "resources", "codex.exe");
        yield return Path.Combine(packageRoot, "resources", "codex.exe");
    }

    private IEnumerable<string> EnumerateRuntimeCandidates()
    {
        var root = GetRuntimeRoot();
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root) || IsReparsePoint(root))
        {
            yield break;
        }

        IEnumerable<string> directories;
        try
        {
            directories = Directory.EnumerateDirectories(root, "*", SearchOption.TopDirectoryOnly)
                .Order(StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            yield break;
        }

        foreach (var directory in directories)
        {
            yield return Path.Combine(directory, "codex.exe");
        }
    }

    private string GetRuntimeRoot() => Path.Combine(_localAppData, "OpenAI", "Codex", "bin");

    internal static bool IsPathWithinRoot(string root, string path)
    {
        try
        {
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var fullPath = Path.GetFullPath(path);
            if (fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase)) return true;
            return fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private static bool IsSafeRegularFileWithinRoot(string root, string path)
    {
        try
        {
            var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var fullPath = Path.GetFullPath(path);
            if (!IsPathWithinRoot(fullRoot, fullPath) || !File.Exists(fullPath) || IsReparsePoint(fullPath))
            {
                return false;
            }

            for (var current = Directory.GetParent(fullPath); current is not null; current = current.Parent)
            {
                if (IsReparsePoint(current.FullName))
                {
                    return false;
                }
                if (current.FullName.Equals(fullRoot, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return false;
        }
    }

    private static bool IsReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static bool MatchesBaseline(FileStream candidate, byte[] baselineHash)
    {
        candidate.Position = 0;
        var candidateHash = SHA256.HashData(candidate);
        candidate.Position = 0;
        return CryptographicOperations.FixedTimeEquals(candidateHash, baselineHash);
    }

    private async Task<bool> SupportsAppServerAsync(string executable, CancellationToken cancellationToken)
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

        var started = false;
        Task<string>? stdoutTask = null;
        Task<string>? stderrTask = null;
        try
        {
            if (!process.Start())
            {
                return false;
            }
            started = true;

            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(ProbeTimeout);
            stdoutTask = DrainBoundedAsync(process.StandardOutput.BaseStream, deadline.Token);
            stderrTask = DrainBoundedAsync(process.StandardError.BaseStream, deadline.Token);
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            var output = (await stdoutTask.ConfigureAwait(false)) + (await stderrTask.ConfigureAwait(false));
            return process.ExitCode == 0 && output.Contains("stdio", StringComparison.OrdinalIgnoreCase);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or IOException)
        {
            return false;
        }
        finally
        {
            if (started && !await OwnedProcessShutdown.StopAsync(process, closeStandardInput: false).ConfigureAwait(false))
            {
                _diagnostics.Write("cleanup", "Capability probe exit unconfirmed");
            }
            await ObserveProbeDrainAsync(stdoutTask).ConfigureAwait(false);
            await ObserveProbeDrainAsync(stderrTask).ConfigureAwait(false);
        }
    }

    private static async Task ObserveProbeDrainAsync(Task<string>? task)
    {
        if (task is null) return;
        try { _ = await task.ConfigureAwait(false); }
        catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException) { }
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

}

internal static class AuthenticodePolicy
{
    public static AuthenticodeIdentity? Verify(string path) =>
        TryVerify(path, out var signer, out var thumbprint)
            ? new AuthenticodeIdentity(signer, thumbprint)
            : null;

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
