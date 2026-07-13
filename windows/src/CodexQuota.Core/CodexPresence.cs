namespace CodexQuota.Core;

public static class CodexPackagePolicy
{
    public const string OfficialFamilyName = "OpenAI.Codex_2p2nqsd0c76g0";

    public static bool IsOfficial(string? packageFamilyName) =>
        string.Equals(packageFamilyName, OfficialFamilyName, StringComparison.Ordinal);
}

public interface IObservedCodexProcess : IDisposable
{
    int ProcessId { get; }
    Task WaitForExitAsync(CancellationToken cancellationToken);
}

public interface ICodexProcessProbe
{
    ValueTask<IObservedCodexProcess?> FindRunningAsync(CancellationToken cancellationToken);
}

public sealed class CodexPresenceMonitor(
    ICodexProcessProbe probe,
    TimeSpan? absencePollInterval = null,
    Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    private readonly TimeSpan _absencePollInterval = absencePollInterval ?? TimeSpan.FromSeconds(2);
    private readonly Func<TimeSpan, CancellationToken, Task> _delay = delay ?? Task.Delay;

    public async Task RunAsync(
        Func<bool, CancellationToken, ValueTask> onPresenceChanged,
        CancellationToken cancellationToken)
    {
        var isPresent = false;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var observed = await probe.FindRunningAsync(cancellationToken).ConfigureAwait(false);
                if (observed is null)
                {
                    if (isPresent)
                    {
                        isPresent = false;
                        await onPresenceChanged(false, cancellationToken).ConfigureAwait(false);
                    }

                    await _delay(_absencePollInterval, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                using (observed)
                {
                    if (!isPresent)
                    {
                        isPresent = true;
                        await onPresenceChanged(true, cancellationToken).ConfigureAwait(false);
                    }

                    await observed.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
                }

                if (isPresent)
                {
                    isPresent = false;
                    await onPresenceChanged(false, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Expected shutdown path.
        }
        finally
        {
            if (isPresent)
            {
                await onPresenceChanged(false, CancellationToken.None).ConfigureAwait(false);
            }
        }
    }
}
