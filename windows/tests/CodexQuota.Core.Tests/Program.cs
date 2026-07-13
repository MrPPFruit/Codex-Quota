using System.Text;
using System.Text.Json;
using CodexQuota.Core;

var tests = new (string Name, Action Body)[]
{
    ("完整快照识别 5 小时和周窗口", FullSnapshotNormalizes),
    ("稀疏更新保留窗口身份与重置时间", SparsePatchMerges),
    ("非法 patch 要求完整刷新", InvalidPatchFailsClosed),
    ("未知窗口身份要求完整刷新", UnknownIdentityRefreshes),
    ("剩余百分比限制在 0 到 100", PercentagesClamp),
    ("JSONL 支持分片和 CRLF", JsonLinesHandleFragments),
    ("JSONL 超限后清空并拒绝", JsonLineLimitFailsClosed),
    ("诊断文本移除本机目录与换行", DiagnosticsAreRedacted),
    ("Codex 包身份只接受官方精确 family", PackageIdentityIsExact),
    ("Codex 生命周期只在状态变化时发布", PresenceTransitionsAreDeduplicated),
    ("悬浮窗在负坐标工作区保持可见", PlacementSupportsNegativeCoordinates),
    ("悬浮窗拒绝无法容纳面板的工作区", PlacementRejectsUndersizedWorkArea),
    ("迟到完整快照不能覆盖后续稀疏更新", StaleFullSnapshotCannotOverwritePatch),
    ("要求刷新通知会废弃在途完整快照", InvalidatingPatchRejectsInflightSnapshot),
    ("发布顺序与额度 revision 保持一致", PublicationsFollowStateRevision),
};

var failures = new List<string>();
foreach (var test in tests)
{
    try
    {
        test.Body();
        Console.WriteLine($"PASS {test.Name}");
    }
    catch (Exception error)
    {
        failures.Add($"FAIL {test.Name}: {error.Message}");
    }
}

if (failures.Count > 0)
{
    failures.ForEach(Console.Error.WriteLine);
    return 1;
}

Console.WriteLine($"PASS {tests.Length}/{tests.Length}");
return 0;

static void FullSnapshotNormalizes()
{
    using var document = LoadFixture("full-snapshot.json");
    Assert(RateLimitJson.TryParsePayload(document.RootElement, out var payload), "payload parse failed");
    var snapshot = UsageNormalizer.Normalize(payload);
    AssertEqual(93d, snapshot.FiveHour.RemainingPercent, "five-hour remaining");
    AssertEqual(78d, snapshot.Weekly.RemainingPercent, "weekly remaining");
    AssertEqual(Freshness.Fresh, snapshot.FiveHour.Freshness, "five-hour freshness");
    AssertEqual(1_783_987_200L, snapshot.FiveHour.ResetsAt, "five-hour reset");
}

static void SparsePatchMerges()
{
    using var snapshotDocument = LoadFixture("full-snapshot.json");
    using var patchDocument = LoadFixture("sparse-update.json");
    Assert(RateLimitJson.TryParsePayload(snapshotDocument.RootElement, out var payload), "payload parse failed");
    Assert(RateLimitJson.TryParsePatch(patchDocument.RootElement, out var patch), "patch parse failed");
    var result = UsageNormalizer.Merge(payload, patch);
    Assert(!result.RequiresFullRefresh && result.Payload is not null, "unexpected refresh");
    var normalized = UsageNormalizer.Normalize(result.Payload!);
    AssertEqual(89d, normalized.FiveHour.RemainingPercent, "updated remaining");
    AssertEqual(1_783_987_200L, normalized.FiveHour.ResetsAt, "reset must survive sparse patch");
    AssertEqual(78d, normalized.Weekly.RemainingPercent, "weekly must survive sparse patch");
}

static void InvalidPatchFailsClosed()
{
    using var document = LoadFixture("invalid-patch.json");
    Assert(!RateLimitJson.TryParsePatch(document.RootElement, out _), "invalid patch was accepted");
}

static void UnknownIdentityRefreshes()
{
    var payload = new RateLimitPayload(null, null, []);
    var patch = new RateLimitPatch(
        FieldPatch<RateLimitWindowPatch>.FromValue(new RateLimitWindowPatch(
            FieldPatch<double>.FromValue(10),
            FieldPatch<int>.Missing,
            FieldPatch<long>.Missing)),
        FieldPatch<RateLimitWindowPatch>.Missing);
    var result = UsageNormalizer.Merge(payload, patch);
    AssertEqual(FullRefreshReason.UnknownWindowIdentity, result.RefreshReason, "refresh reason");
}

static void PercentagesClamp()
{
    var payload = new RateLimitPayload(
        new RateLimitWindow(-50, 300, 10),
        new RateLimitWindow(150, 10_080, 20),
        []);
    var snapshot = UsageNormalizer.Normalize(payload);
    AssertEqual(100d, snapshot.FiveHour.RemainingPercent, "upper clamp");
    AssertEqual(0d, snapshot.Weekly.RemainingPercent, "lower clamp");
}

static void JsonLinesHandleFragments()
{
    var framer = new JsonLineFramer(64);
    AssertEqual(0, framer.Append("{\"id\":"u8).Count, "partial frame count");
    var frames = framer.Append("1}\r\n{\"id\":2}\n"u8);
    AssertEqual(2, frames.Count, "frame count");
    AssertEqual("{\"id\":1}", Encoding.UTF8.GetString(frames[0]), "first frame");
    AssertEqual("{\"id\":2}", Encoding.UTF8.GetString(frames[1]), "second frame");
}

static void JsonLineLimitFailsClosed()
{
    var framer = new JsonLineFramer(4);
    _ = framer.Append("1234"u8);
    var failed = false;
    try
    {
        _ = framer.Append("5"u8);
    }
    catch (InvalidDataException)
    {
        failed = true;
    }

    Assert(failed, "oversized frame was accepted");
    var frames = framer.Append("{}\n"u8);
    AssertEqual(1, frames.Count, "framer did not recover after rejection");
}

static void DiagnosticsAreRedacted()
{
    var source = "C:\\Users\\Alice\\project\nC:\\Users\\Alice\\AppData\\Local\\OpenAI";
    var result = DiagnosticRedactor.Sanitize(
        source,
        @"C:\Users\Alice",
        @"C:\Users\Alice\AppData\Local",
        @"C:\Users\Alice\AppData\Local\Temp");
    Assert(!result.Contains("Alice", StringComparison.OrdinalIgnoreCase), "profile leaked");
    Assert(!result.Contains('\n'), "newline leaked");
    Assert(result.Contains("%USERPROFILE%", StringComparison.Ordinal), "profile marker missing");
}

static void PackageIdentityIsExact()
{
    Assert(CodexPackagePolicy.IsOfficial("OpenAI.Codex_2p2nqsd0c76g0"), "official family rejected");
    Assert(!CodexPackagePolicy.IsOfficial("openai.codex_2p2nqsd0c76g0"), "case change accepted");
    Assert(!CodexPackagePolicy.IsOfficial("OpenAI.Codex_2p2nqsd0c76g0.fake"), "suffix accepted");
    Assert(!CodexPackagePolicy.IsOfficial(null), "null accepted");
}

static void PresenceTransitionsAreDeduplicated()
{
    using var cancellation = new CancellationTokenSource();
    var probe = new FakeProcessProbe(new FakeObservedProcess(), null);
    var changes = new List<bool>();
    var monitor = new CodexPresenceMonitor(
        probe,
        TimeSpan.Zero,
        (_, _) =>
        {
            cancellation.Cancel();
            return Task.CompletedTask;
        });
    monitor.RunAsync((present, _) =>
    {
        changes.Add(present);
        return ValueTask.CompletedTask;
    }, cancellation.Token).GetAwaiter().GetResult();
    AssertEqual(2, changes.Count, "presence transition count");
    AssertEqual(true, changes[0], "first transition");
    AssertEqual(false, changes[1], "second transition");
}

static void PlacementSupportsNegativeCoordinates()
{
    var frame = OverlayPlacement.ClampCentered(-2_000, 900, 130, 78, new DesktopRect(-1_920, 0, 1_920, 1_080));
    Assert(frame is not null, "placement unexpectedly failed");
    var value = frame ?? throw new InvalidOperationException("placement unexpectedly failed");
    AssertEqual(-1_920d, value.Left, "negative left clamp");
    AssertEqual(861d, value.Top, "vertical center");
}

static void PlacementRejectsUndersizedWorkArea()
{
    var frame = OverlayPlacement.ClampCentered(0, 0, 130, 78, new DesktopRect(0, 0, 100, 50));
    Assert(frame is null, "oversized panel was accepted");
}

static void StaleFullSnapshotCannotOverwritePatch()
{
    using var snapshotDocument = LoadFixture("full-snapshot.json");
    using var patchDocument = LoadFixture("sparse-update.json");
    Assert(RateLimitJson.TryParsePayload(snapshotDocument.RootElement, out var initial), "payload parse failed");
    Assert(RateLimitJson.TryParsePatch(patchDocument.RootElement, out var patch), "patch parse failed");
    var state = new UsagePayloadState();
    Assert(state.TryCommitFull(state.CaptureRevision(), initial, out _), "initial commit failed");
    var staleRevision = state.CaptureRevision();
    var application = state.Apply(patch);
    Assert(!application.RequiresFullRefresh, "patch required refresh");
    Assert(!state.TryCommitFull(staleRevision, initial, out _), "stale snapshot overwrote patch");
    AssertEqual(89d, application.Snapshot?.FiveHour.RemainingPercent ?? -1, "patch value");
}

static void InvalidatingPatchRejectsInflightSnapshot()
{
    using var snapshotDocument = LoadFixture("full-snapshot.json");
    Assert(RateLimitJson.TryParsePayload(snapshotDocument.RootElement, out var initial), "payload parse failed");
    var state = new UsagePayloadState();
    Assert(state.TryCommitFull(state.CaptureRevision(), initial, out _), "initial commit failed");
    var staleRevision = state.CaptureRevision();
    var invalidating = new RateLimitPatch(
        FieldPatch<RateLimitWindowPatch>.FromValue(new RateLimitWindowPatch(
            FieldPatch<double>.FromValue(10),
            FieldPatch<int>.Null,
            FieldPatch<long>.Missing)),
        FieldPatch<RateLimitWindowPatch>.Missing);
    Assert(state.Apply(invalidating).RequiresFullRefresh, "invalid identity did not require refresh");
    Assert(!state.TryCommitFull(staleRevision, initial, out _), "invalidated in-flight snapshot committed");
}

static void PublicationsFollowStateRevision()
{
    using var snapshotDocument = LoadFixture("full-snapshot.json");
    using var patchDocument = LoadFixture("sparse-update.json");
    Assert(RateLimitJson.TryParsePayload(snapshotDocument.RootElement, out var initial), "payload parse failed");
    Assert(RateLimitJson.TryParsePatch(patchDocument.RootElement, out var patch), "patch parse failed");
    var state = new UsagePayloadState();
    Assert(state.TryCommitFull(state.CaptureRevision(), initial, out _), "initial commit failed");
    var staleRevision = state.CaptureRevision();
    var publications = new List<double?>();
    Assert(state.ApplyAndPublish(patch, snapshot => publications.Add(snapshot.FiveHour.RemainingPercent)), "patch publish failed");
    Assert(!state.TryCommitFullAndPublish(staleRevision, initial, snapshot => publications.Add(snapshot.FiveHour.RemainingPercent)), "stale publish succeeded");
    AssertEqual(1, publications.Count, "publication count");
    AssertEqual(89d, publications[0] ?? -1, "published revision");
}

static JsonDocument LoadFixture(string name)
{
    var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "rate-limits", name);
    return JsonDocument.Parse(File.ReadAllText(path));
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static void AssertEqual<T>(T expected, T actual, string message)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual))
    {
        throw new InvalidOperationException($"{message}: expected={expected}, actual={actual}");
    }
}

file sealed class FakeProcessProbe(params IObservedCodexProcess?[] observations) : ICodexProcessProbe
{
    private readonly Queue<IObservedCodexProcess?> _observations = new(observations);
    public ValueTask<IObservedCodexProcess?> FindRunningAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return ValueTask.FromResult(_observations.Count > 0 ? _observations.Dequeue() : null);
    }
}

file sealed class FakeObservedProcess : IObservedCodexProcess
{
    public int ProcessId => 42;
    public Task WaitForExitAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public void Dispose() { }
}
