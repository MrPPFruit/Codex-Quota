using System.ComponentModel;
using System.IO;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class UsageSessionCoordinator : IAsyncDisposable
{
    private readonly WindowsCodexExecutableLocator _locator;
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly Action<bool, UsageSnapshot> _publish;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private CancellationTokenSource? _sessionCancellation;
    private Task? _sessionTask;

    public UsageSessionCoordinator(
        WindowsCodexExecutableLocator locator,
        BoundedDiagnosticLog diagnostics,
        Action<bool, UsageSnapshot> publish)
    {
        _locator = locator;
        _diagnostics = diagnostics;
        _publish = publish;
    }

    public async ValueTask PresenceChangedAsync(bool present, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StopSessionAsync().ConfigureAwait(false);
            if (!present)
            {
                _publish(false, UsageSnapshot.Unavailable);
                return;
            }

            _publish(true, UsageSnapshot.Unavailable);
            _sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _sessionTask = RunSessionLoopAsync(_sessionCancellation.Token);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task RunSessionLoopAsync(CancellationToken cancellationToken)
    {
        var delay = TimeSpan.FromSeconds(1);
        while (!cancellationToken.IsCancellationRequested)
        {
            CodexAppServerClient? client = null;
            try
            {
                var candidate = await _locator.LocateAsync(cancellationToken).ConfigureAwait(false);
                if (candidate is null)
                {
                    throw new InvalidOperationException("Trusted helper unavailable");
                }

                client = new CodexAppServerClient(candidate.Path, _diagnostics);
                client.SnapshotChanged += OnSnapshotChanged;
                _ = await client.StartAsync(cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(1);
                await client.Completion.WaitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error) when (error is IOException or InvalidOperationException or TimeoutException or Win32Exception)
            {
                _diagnostics.Write("session", error.GetType().Name);
                _publish(true, UsageSnapshot.Unavailable);
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 30));
            }
            finally
            {
                if (client is not null)
                {
                    client.SnapshotChanged -= OnSnapshotChanged;
                    try { await client.DisposeAsync().ConfigureAwait(false); }
                    catch (Exception error) when (error is IOException or InvalidOperationException or OperationCanceledException or Win32Exception)
                    {
                        _diagnostics.Write("cleanup", error.GetType().Name);
                    }
                }
            }
        }
    }

    private void OnSnapshotChanged(UsageSnapshot snapshot) => _publish(true, snapshot);

    private async Task StopSessionAsync()
    {
        var cancellation = _sessionCancellation;
        var task = _sessionTask;
        _sessionCancellation = null;
        _sessionTask = null;
        if (cancellation is null)
        {
            return;
        }
        cancellation.Cancel();
        if (task is not null)
        {
            try { await task.ConfigureAwait(false); }
            catch (OperationCanceledException) { }
            catch (Exception error) when (error is IOException or InvalidOperationException or TimeoutException or Win32Exception)
            {
                _diagnostics.Write("session", error.GetType().Name);
            }
        }
        cancellation.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try { await StopSessionAsync().ConfigureAwait(false); }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }
}
