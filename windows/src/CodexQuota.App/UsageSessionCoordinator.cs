using System.ComponentModel;
using System.IO;
using CodexQuota.Core;

namespace CodexQuota.App;

internal interface IUsageSession : IAsyncDisposable
{
    event Action<UsageSnapshot>? SnapshotChanged;
    Task Completion { get; }
    Task<UsageSnapshot> StartAsync(CancellationToken cancellationToken);
}

internal sealed class UsageSessionCoordinator : IAsyncDisposable
{
    private readonly Func<CancellationToken, Task<CodexExecutableCandidate?>> _locateAsync;
    private readonly Func<CodexExecutableCandidate, IUsageSession> _createSession;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly Action<bool, UsageSnapshot> _publish;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _disposeGate = new();
    private readonly object _publicationGate = new();
    private CancellationTokenSource? _sessionCancellation;
    private Task? _sessionTask;
    private Task? _disposeTask;
    private long _nextGeneration;
    private long _activeGeneration;
    private int _restartBlocked;

    public UsageSessionCoordinator(
        WindowsCodexExecutableLocator locator,
        BoundedDiagnosticLog diagnostics,
        Action<bool, UsageSnapshot> publish)
        : this(
            locator.LocateAsync,
            candidate => new CodexAppServerClient(candidate, diagnostics),
            diagnostics,
            publish)
    {
    }

    internal UsageSessionCoordinator(
        Func<CancellationToken, Task<CodexExecutableCandidate?>> locateAsync,
        Func<CodexExecutableCandidate, IUsageSession> createSession,
        BoundedDiagnosticLog diagnostics,
        Action<bool, UsageSnapshot> publish,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _locateAsync = locateAsync;
        _createSession = createSession;
        _diagnostics = diagnostics;
        _publish = publish;
        _delay = delay ?? Task.Delay;
    }

    public async ValueTask PresenceChangedAsync(bool present, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            InvalidateGeneration();
            await StopSessionAsync().ConfigureAwait(false);
            if (!present)
            {
                PublishPresenceWithoutSession(false);
                return;
            }

            if (Volatile.Read(ref _restartBlocked) != 0)
            {
                PublishPresenceWithoutSession(true);
                return;
            }

            var generation = BeginGeneration();
            _sessionCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _sessionTask = RunSessionLoopAsync(generation, _sessionCancellation.Token);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task RunSessionLoopAsync(long generation, CancellationToken cancellationToken)
    {
        var delay = TimeSpan.FromSeconds(1);
        while (!cancellationToken.IsCancellationRequested && Volatile.Read(ref _restartBlocked) == 0)
        {
            IUsageSession? session = null;
            Action<UsageSnapshot>? snapshotHandler = null;
            var cleanupUnconfirmed = false;
            var retryWithBackoff = false;
            try
            {
                var candidate = await _locateAsync(cancellationToken).ConfigureAwait(false);
                if (candidate is null)
                {
                    throw new FileNotFoundException("Trusted helper unavailable");
                }

                try
                {
                    session = _createSession(candidate);
                }
                catch
                {
                    candidate.Dispose();
                    throw;
                }
                snapshotHandler = snapshot => PublishForGeneration(generation, snapshot);
                session.SnapshotChanged += snapshotHandler;
                _ = await session.StartAsync(cancellationToken).ConfigureAwait(false);
                delay = TimeSpan.FromSeconds(1);
                await session.Completion.WaitAsync(cancellationToken).ConfigureAwait(false);
                PublishForGeneration(generation, UsageSnapshot.Unavailable);
                retryWithBackoff = true;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error) when (IsRecoverableSessionFailure(error))
            {
                _diagnostics.Write("session", error.GetType().Name);
                PublishForGeneration(generation, UsageSnapshot.Unavailable);
                retryWithBackoff = true;
            }
            catch (Exception error)
            {
                _diagnostics.Write("session-fatal", error.GetType().Name);
                PublishForGeneration(generation, UsageSnapshot.Unavailable);
                break;
            }
            finally
            {
                if (session is not null)
                {
                    if (snapshotHandler is not null)
                    {
                        session.SnapshotChanged -= snapshotHandler;
                    }

                    try
                    {
                        await session.DisposeAsync().ConfigureAwait(false);
                    }
                    catch (SessionCleanupUnconfirmedException error)
                    {
                        cleanupUnconfirmed = true;
                        Interlocked.Exchange(ref _restartBlocked, 1);
                        _diagnostics.Write("cleanup", error.GetType().Name);
                    }
                    catch (Exception error)
                    {
                        _diagnostics.Write("cleanup", error.GetType().Name);
                    }
                }
            }

            if (cleanupUnconfirmed)
            {
                PublishForGeneration(generation, UsageSnapshot.Unavailable);
                break;
            }

            if (retryWithBackoff)
            {
                try
                {
                    await _delay(delay, cancellationToken).ConfigureAwait(false);
                    delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 30));
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
            }
        }
    }

    private static bool IsRecoverableSessionFailure(Exception error) =>
        error is IOException or Win32Exception or TimeoutException or UnauthorizedAccessException or OperationCanceledException;

    private void PublishForGeneration(long generation, UsageSnapshot snapshot)
    {
        lock (_publicationGate)
        {
            if (_activeGeneration == generation)
            {
                _publish(true, snapshot);
            }
        }
    }

    private long BeginGeneration()
    {
        lock (_publicationGate)
        {
            var generation = ++_nextGeneration;
            _activeGeneration = generation;
            _publish(true, UsageSnapshot.Unavailable);
            return generation;
        }
    }

    private void InvalidateGeneration()
    {
        lock (_publicationGate)
        {
            _activeGeneration = 0;
        }
    }

    private void PublishPresenceWithoutSession(bool present)
    {
        lock (_publicationGate)
        {
            _activeGeneration = 0;
            _publish(present, UsageSnapshot.Unavailable);
        }
    }

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

        try
        {
            cancellation.Cancel();
            if (task is not null)
            {
                try
                {
                    await task.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
                catch (Exception error)
                {
                    _diagnostics.Write("session", error.GetType().Name);
                }
            }
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (_disposeGate)
        {
            _disposeTask ??= DisposeCoreAsync();
            return new ValueTask(_disposeTask);
        }
    }

    private async Task DisposeCoreAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            InvalidateGeneration();
            await StopSessionAsync().ConfigureAwait(false);
            PublishPresenceWithoutSession(false);
        }
        finally
        {
            _gate.Release();
            _gate.Dispose();
        }
    }
}
