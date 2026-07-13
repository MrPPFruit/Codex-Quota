using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using CodexQuota.Core;

namespace CodexQuota.App;

internal sealed class CodexAppServerClient : IAsyncDisposable
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(10);
    private readonly string _executable;
    private readonly BoundedDiagnosticLog _diagnostics;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly SemaphoreSlim _writeGate = new(1, 1);
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly UsagePayloadState _usageState = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TaskCompletionSource _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Process? _process;
    private Task? _readerTask;
    private Task? _stderrTask;
    private int _nextId;
    private int _closed;
    private readonly object _refreshTaskGate = new();
    private Task? _refreshTask;

    public CodexAppServerClient(string executable, BoundedDiagnosticLog diagnostics)
    {
        _executable = executable;
        _diagnostics = diagnostics;
    }

    public event Action<UsageSnapshot>? SnapshotChanged;
    public Task Completion => _completion.Task;

    public async Task<UsageSnapshot> StartAsync(CancellationToken cancellationToken)
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
        if (!process.Start())
        {
            throw new InvalidOperationException("Codex app-server failed to start");
        }

        _process = process;
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
        return await RefreshAsync(linked.Token).ConfigureAwait(false);
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
                    Publish(UsageSnapshot.Unavailable);
                }
            });
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

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0)
        {
            return;
        }

        _lifetime.Cancel();
        _completion.TrySetResult();
        Task? refreshTask;
        lock (_refreshTaskGate) refreshTask = _refreshTask;
        var process = _process;
        if (process is not null)
        {
            try { process.StandardInput.Close(); } catch (IOException) { }
            if (!process.HasExited)
            {
                using var grace = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
                try { await process.WaitForExitAsync(grace.Token).ConfigureAwait(false); }
                catch (OperationCanceledException)
                {
                    try { process.Kill(entireProcessTree: true); }
                    catch (InvalidOperationException) when (process.HasExited) { }
                    using var killDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(1));
                    await process.WaitForExitAsync(killDeadline.Token).ConfigureAwait(false);
                }
            }
            process.Exited -= OnProcessExited;
            process.Dispose();
        }
        if (_readerTask is not null)
        {
            try { await _readerTask.ConfigureAwait(false); } catch (OperationCanceledException) { }
        }
        if (_stderrTask is not null)
        {
            try { await _stderrTask.ConfigureAwait(false); } catch (OperationCanceledException) { }
        }
        if (refreshTask is not null)
        {
            using var refreshDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await refreshTask.WaitAsync(refreshDeadline.Token).ConfigureAwait(false);
        }
        _writeGate.Dispose();
        _refreshGate.Dispose();
        _lifetime.Dispose();
    }
}
