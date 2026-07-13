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
