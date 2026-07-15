using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class CodexAppServerClient : IUsageSession
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan BackgroundShutdownTimeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan DefaultCalibrationInterval = TimeSpan.FromSeconds(120);
    private readonly string _executable;
    private CodexExecutableCandidate? _candidate;
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly TimeSpan _calibrationInterval;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly UsagePayloadState _usageState = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TaskCompletionSource _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly object _disposeGate = new();
    private Process? _process;
    private Task? _readerTask;
    private Task? _stderrTask;
    private int _nextId;
    private int _closed;
    private readonly object _refreshTaskGate = new();
    private Task? _refreshTask;
    private Task? _calibrationTask;
    private Task? _disposeTask;
    private int _startClaimed;

    public CodexAppServerClient(string executable, BoundedDiagnosticLog diagnostics)
        : this(new CodexExecutableCandidate(executable, "unverified test executable"), diagnostics)
    {
    }

    internal CodexAppServerClient(
        CodexExecutableCandidate candidate,
        BoundedDiagnosticLog diagnostics,
        TimeSpan? calibrationInterval = null)
    {
        var interval = calibrationInterval ?? DefaultCalibrationInterval;
        if (interval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(calibrationInterval));
        _candidate = candidate;
        _executable = candidate.Path;
        _diagnostics = diagnostics;
        _calibrationInterval = interval;
    }

    public event Action<UsageSnapshot>? SnapshotChanged;
    public Task Completion => _completion.Task;

    public async Task<UsageSnapshot> StartAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _closed) != 0, this);
        if (Interlocked.CompareExchange(ref _startClaimed, 1, 0) != 0)
        {
            throw new InvalidOperationException("Codex app-server client can only be started once");
        }

        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _closed) != 0, this);
            return await StartCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async Task<UsageSnapshot> StartCoreAsync(CancellationToken cancellationToken)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _executable,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = new UTF8Encoding(false),
            },
            EnableRaisingEvents = true,
        };
        process.StartInfo.ArgumentList.Add("app-server");
        process.StartInfo.ArgumentList.Add("--stdio");
        process.Exited += OnProcessExited;
        var ownershipTransferred = false;
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("Codex app-server failed to start");
            }

            _process = process;
            ownershipTransferred = true;
            _readerTask = ReadLoopAsync(process, _lifetime.Token);
            _stderrTask = DrainAsync(process.StandardError.BaseStream, _lifetime.Token);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
            linked.CancelAfter(RequestTimeout);

            _ = await RequestAsync("initialize", new
            {
                clientInfo = new { name = "codex-quota", title = "Codex Quota", version = "0.2.0" },
                capabilities = new { },
            }, linked.Token).ConfigureAwait(false);
            await NotifyAsync("initialized", new { }, linked.Token).ConfigureAwait(false);
            var snapshot = await RefreshAsync(linked.Token).ConfigureAwait(false);
            ReleaseExecutionLease();
            StartCalibrationLoop();
            return snapshot;
        }
        finally
        {
            if (!ownershipTransferred)
            {
                process.Exited -= OnProcessExited;
                process.Dispose();
            }
        }
    }

    private async Task<UsageSnapshot> RefreshAsync(CancellationToken cancellationToken)
    {
        await _refreshGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                var startingRevision = _usageState.CaptureRevision();
                var result = await RequestAsync("account/rateLimits/read", new { }, cancellationToken).ConfigureAwait(false);
                if (!TryExtractRateLimits(result, out var limits) || !RateLimitJson.TryParsePayload(limits, out var payload))
                {
                    throw new InvalidDataException("Invalid rate-limit snapshot");
                }

                UsageSnapshot? published = null;
                if (!_usageState.TryCommitFullAndPublish(startingRevision, payload, snapshot =>
                    {
                        published = snapshot;
                        Publish(snapshot);
                    })) continue;
                return published ?? UsageSnapshot.Unavailable;
            }
            throw new InvalidDataException("Rate-limit snapshot remained stale during refresh");
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    private async Task<JsonElement> RequestAsync(string method, object parameters, CancellationToken cancellationToken)
    {
        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_pending.TryAdd(id, completion))
        {
            throw new InvalidOperationException("Duplicate JSON-RPC request id");
        }

        try
        {
            await WriteAsync(new { id, method, @params = parameters }, cancellationToken).ConfigureAwait(false);
            return await completion.Task.WaitAsync(RequestTimeout, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _pending.TryRemove(id, out _);
        }
    }

    private Task NotifyAsync(string method, object parameters, CancellationToken cancellationToken) =>
        WriteAsync(new { method, @params = parameters }, cancellationToken);

    private async Task WriteAsync(object message, CancellationToken cancellationToken)
    {
        var process = _process ?? throw new InvalidOperationException("app-server is not running");
        var line = JsonSerializer.Serialize(message) + "\n";
        await _writeGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await process.StandardInput.WriteAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _writeGate.Release();
        }
    }

    private async Task ReadLoopAsync(Process process, CancellationToken cancellationToken)
    {
        var framer = new JsonLineFramer();
        var buffer = new byte[8192];
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var count = await process.StandardOutput.BaseStream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (count == 0)
                {
                    break;
                }
                foreach (var frame in framer.Append(buffer.AsSpan(0, count)))
                {
                    HandleLine(Encoding.UTF8.GetString(frame));
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is JsonException or InvalidDataException or IOException)
        {
            _diagnostics.Write("protocol", error.GetType().Name);
        }
        finally
        {
            FailPending();
            if (Volatile.Read(ref _closed) == 0)
            {
                Publish(UsageSnapshot.Unavailable);
            }
            _completion.TrySetResult();
        }
    }

    private void HandleLine(string line)
    {
        using var document = JsonDocument.Parse(line, new JsonDocumentOptions { MaxDepth = 32 });
        var root = document.RootElement;
        if (root.TryGetProperty("id", out var idElement) && idElement.TryGetInt32(out var id) &&
            _pending.TryGetValue(id, out var completion))
        {
            if (root.TryGetProperty("error", out var error))
            {
                completion.TrySetException(new InvalidDataException($"JSON-RPC error {error.ValueKind}"));
            }
            else if (root.TryGetProperty("result", out var result))
            {
                completion.TrySetResult(result.Clone());
            }
            else
            {
                completion.TrySetException(new InvalidDataException("JSON-RPC response has no result"));
            }
            return;
        }

        if (!root.TryGetProperty("method", out var method) ||
            method.GetString() != "account/rateLimits/updated" ||
            !root.TryGetProperty("params", out var parameters) ||
            !TryExtractRateLimits(parameters, out var limits) ||
            !RateLimitJson.TryParsePatch(limits, out var patch))
        {
            return;
        }

        if (!_usageState.ApplyAndPublish(patch, Publish)) ScheduleRefresh();
    }

    private static bool TryExtractRateLimits(JsonElement container, out JsonElement limits)
    {
        if (container.ValueKind == JsonValueKind.Object && container.TryGetProperty("rateLimits", out limits))
        {
            return limits.ValueKind == JsonValueKind.Object;
        }
        limits = default;
        return false;
    }

    private void ScheduleRefresh()
    {
        lock (_refreshTaskGate)
        {
            if (Volatile.Read(ref _closed) != 0 || _refreshTask is { IsCompleted: false }) return;
            _refreshTask = Task.Run(async () =>
            {
                try
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
                    deadline.CancelAfter(RequestTimeout);
                    await RefreshAsync(deadline.Token).ConfigureAwait(false);
                }
                catch (Exception error) when (error is OperationCanceledException or InvalidDataException or IOException or TimeoutException)
                {
                    if (!(_lifetime.IsCancellationRequested && error is OperationCanceledException))
                    {
                        _usageState.ClearAndPublish(Publish);
                    }
                }
            });
        }
    }

    private void StartCalibrationLoop()
    {
        lock (_refreshTaskGate)
        {
            if (Volatile.Read(ref _closed) != 0 || _calibrationTask is { IsCompleted: false }) return;
            _calibrationTask = CalibrateAsync();
        }
    }

    private async Task CalibrateAsync()
    {
        while (!_lifetime.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(_calibrationInterval, _lifetime.Token).ConfigureAwait(false);
                await RefreshAsync(_lifetime.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error) when (error is InvalidDataException or IOException or TimeoutException or OperationCanceledException)
            {
                _usageState.ClearAndPublish(Publish);
            }
        }
    }

    private void Publish(UsageSnapshot snapshot) => SnapshotChanged?.Invoke(snapshot);

    private void OnProcessExited(object? sender, EventArgs eventArgs)
    {
        FailPending();
        if (Volatile.Read(ref _closed) == 0)
        {
            Publish(UsageSnapshot.Unavailable);
        }
        _completion.TrySetResult();
    }

    private void FailPending()
    {
        foreach (var pending in _pending.Values)
        {
            pending.TrySetException(new IOException("Codex app-server disconnected"));
        }
    }

    private static async Task DrainAsync(Stream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[4096];
        while (await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false) > 0)
        {
            // Deliberately discard helper diagnostics to keep memory bounded and avoid account data leakage.
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
        Interlocked.Exchange(ref _closed, 1);
        _lifetime.Cancel();
        _completion.TrySetResult();
        Task? refreshTask;
        Task? calibrationTask;
        await _lifecycleGate.WaitAsync().ConfigureAwait(false);
        Process? process;
        try
        {
            process = Interlocked.Exchange(ref _process, null);
        }
        finally
        {
            _lifecycleGate.Release();
        }
        lock (_refreshTaskGate)
        {
            refreshTask = _refreshTask;
            calibrationTask = _calibrationTask;
        }
        var processExitConfirmed = true;
        if (process is not null)
        {
            processExitConfirmed = false;
            try
            {
                processExitConfirmed = await OwnedProcessShutdown.StopAsync(
                    process,
                    closeStandardInput: true).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                _diagnostics.Write("cleanup", error.GetType().Name);
            }
            finally
            {
                process.Exited -= OnProcessExited;
                try { process.StandardOutput.Close(); }
                catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
                try { process.StandardError.Close(); }
                catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException) { }
                process.Dispose();
            }
        }
        ReleaseExecutionLease();

        var backgroundTasks = new[] { _readerTask, _stderrTask, refreshTask, calibrationTask }
            .Where(task => task is not null)
            .Select(task => ObserveShutdownTaskAsync(task!))
            .ToArray();
        var backgroundStopped = true;
        Exception? backgroundFailure = null;
        if (backgroundTasks.Length > 0)
        {
            using var deadline = new CancellationTokenSource(BackgroundShutdownTimeout);
            try
            {
                await Task.WhenAll(backgroundTasks).WaitAsync(deadline.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (deadline.IsCancellationRequested)
            {
                backgroundStopped = false;
            }
            catch (Exception error)
            {
                backgroundFailure = error;
            }
        }

        if (backgroundStopped)
        {
            _writeGate.Dispose();
            _refreshGate.Dispose();
            _lifetime.Dispose();
        }

        if (!processExitConfirmed || !backgroundStopped)
        {
            throw new SessionCleanupUnconfirmedException(
                !processExitConfirmed
                    ? "Owned app-server exit could not be confirmed"
                    : "App-server background cleanup did not complete");
        }

        if (backgroundFailure is not null)
        {
            throw new IOException("App-server background cleanup failed", backgroundFailure);
        }
    }

    private void ReleaseExecutionLease() => Interlocked.Exchange(ref _candidate, null)?.Dispose();

    private static async Task ObserveShutdownTaskAsync(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (IOException) { }
    }
}
