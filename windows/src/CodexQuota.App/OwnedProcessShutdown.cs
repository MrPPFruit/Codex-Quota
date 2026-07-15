using System.ComponentModel;
using System.Diagnostics;
using System.IO;

namespace CodexQuota.App;

internal static class OwnedProcessShutdown
{
    private static readonly TimeSpan GracefulExitTimeout = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan ForcedExitTimeout = TimeSpan.FromSeconds(1);

    public static async Task<bool> StopAsync(Process process, bool closeStandardInput)
    {
        if (closeStandardInput)
        {
            try { process.StandardInput.Close(); }
            catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
        }

        if (HasExited(process))
        {
            return true;
        }

        if (await WaitForExitAsync(process, GracefulExitTimeout).ConfigureAwait(false))
        {
            return true;
        }

        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) when (HasExited(process))
        {
            return true;
        }
        catch (Win32Exception)
        {
            return HasExited(process);
        }

        return await WaitForExitAsync(process, ForcedExitTimeout).ConfigureAwait(false);
    }

    private static bool HasExited(Process process)
    {
        try { return process.HasExited; }
        catch (InvalidOperationException) { return false; }
        catch (Win32Exception) { return false; }
    }

    private static async Task<bool> WaitForExitAsync(Process process, TimeSpan timeout)
    {
        using var deadline = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
            return HasExited(process);
        }
        catch (OperationCanceledException) when (deadline.IsCancellationRequested)
        {
            return HasExited(process);
        }
        catch (InvalidOperationException) when (HasExited(process))
        {
            return true;
        }
        catch (Win32Exception)
        {
            return HasExited(process);
        }
    }
}

internal sealed class SessionCleanupUnconfirmedException(string message) : IOException(message);
