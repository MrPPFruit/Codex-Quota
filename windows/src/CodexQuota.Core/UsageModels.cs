using System.Text.Json;

namespace CodexQuota.Core;

public enum UsageWindowKind
{
    FiveHour,
    Weekly,
}

public enum Freshness
{
    Fresh,
    Stale,
    Unavailable,
}

public sealed record UsageWindow(
    UsageWindowKind Kind,
    double? RemainingPercent,
    long? ResetsAt,
    Freshness Freshness)
{
    public static UsageWindow Unavailable(UsageWindowKind kind) =>
        new(kind, null, null, Freshness.Unavailable);
}

public sealed record UsageSnapshot(UsageWindow FiveHour, UsageWindow Weekly)
{
    public static UsageSnapshot Unavailable { get; } = new(
        UsageWindow.Unavailable(UsageWindowKind.FiveHour),
        UsageWindow.Unavailable(UsageWindowKind.Weekly));
}

public sealed record RateLimitWindow(double? UsedPercent, int? WindowDurationMins, long? ResetsAt);

public sealed record RateLimitPayload(
    RateLimitWindow? Primary,
    RateLimitWindow? Secondary,
    IReadOnlyList<RateLimitWindow> Additional)
{
    public static RateLimitPayload Empty { get; } = new(null, null, []);
}

public enum FieldPatchKind
{
    Missing,
    Null,
    Value,
}

public readonly record struct FieldPatch<T>(FieldPatchKind Kind, T Value)
{
    public static FieldPatch<T> Missing => new(FieldPatchKind.Missing, default!);
    public static FieldPatch<T> Null => new(FieldPatchKind.Null, default!);
    public static FieldPatch<T> FromValue(T value) => new(FieldPatchKind.Value, value);
}

public sealed record RateLimitWindowPatch(
    FieldPatch<double> UsedPercent,
    FieldPatch<int> WindowDurationMins,
    FieldPatch<long> ResetsAt);

public sealed record RateLimitPatch(
    FieldPatch<RateLimitWindowPatch> Primary,
    FieldPatch<RateLimitWindowPatch> Secondary);

public enum FullRefreshReason
{
    UnknownWindowIdentity,
    WindowIdentityChanged,
    InvalidPatch,
}

public readonly record struct UsageMergeResult(RateLimitPayload? Payload, FullRefreshReason? RefreshReason)
{
    public bool RequiresFullRefresh => RefreshReason is not null;

    public static UsageMergeResult Merged(RateLimitPayload payload) => new(payload, null);
    public static UsageMergeResult Refresh(FullRefreshReason reason) => new(null, reason);
}

public static class UsageNormalizer
{
    private const int FiveHourMinutes = 300;
    private const int WeeklyMinutes = 10_080;

    public static UsageSnapshot Normalize(RateLimitPayload payload)
    {
        var fiveHour = UsageWindow.Unavailable(UsageWindowKind.FiveHour);
        var weekly = UsageWindow.Unavailable(UsageWindowKind.Weekly);

        foreach (var window in Enumerate(payload))
        {
            if (window.UsedPercent is not { } usedPercent || !double.IsFinite(usedPercent))
            {
                continue;
            }

            switch (window.WindowDurationMins)
            {
                case FiveHourMinutes:
                    fiveHour = MakeWindow(UsageWindowKind.FiveHour, usedPercent, window.ResetsAt);
                    break;
                case WeeklyMinutes:
                    weekly = MakeWindow(UsageWindowKind.Weekly, usedPercent, window.ResetsAt);
                    break;
            }
        }

        return new UsageSnapshot(fiveHour, weekly);
    }

    public static UsageMergeResult Merge(RateLimitPayload current, RateLimitPatch patch)
    {
        var primary = MergeWindow(current.Primary, patch.Primary);
        if (primary.RefreshReason is not null)
        {
            return UsageMergeResult.Refresh(primary.RefreshReason.Value);
        }

        var secondary = MergeWindow(current.Secondary, patch.Secondary);
        if (secondary.RefreshReason is not null)
        {
            return UsageMergeResult.Refresh(secondary.RefreshReason.Value);
        }

        return UsageMergeResult.Merged(new RateLimitPayload(
            primary.Window,
            secondary.Window,
            current.Additional));
    }

    public static bool NeedsRefresh(UsageSnapshot snapshot, long now) =>
        NeedsRefresh(snapshot.FiveHour, now) || NeedsRefresh(snapshot.Weekly, now);

    private static bool NeedsRefresh(UsageWindow window, long now) =>
        window.Freshness != Freshness.Fresh || window.ResetsAt is null || window.ResetsAt <= now;

    private static IEnumerable<RateLimitWindow> Enumerate(RateLimitPayload payload)
    {
        if (payload.Primary is not null)
        {
            yield return payload.Primary;
        }

        if (payload.Secondary is not null)
        {
            yield return payload.Secondary;
        }

        foreach (var window in payload.Additional)
        {
            yield return window;
        }
    }

    private static UsageWindow MakeWindow(UsageWindowKind kind, double usedPercent, long? resetsAt) =>
        new(kind, Math.Clamp(100 - usedPercent, 0, 100), resetsAt, Freshness.Fresh);

    private static WindowMergeResult MergeWindow(
        RateLimitWindow? current,
        FieldPatch<RateLimitWindowPatch> patch)
    {
        if (patch.Kind == FieldPatchKind.Missing)
        {
            return WindowMergeResult.Success(current);
        }

        if (patch.Kind == FieldPatchKind.Null)
        {
            return WindowMergeResult.Success(null);
        }

        var value = patch.Value;

        int duration;
        switch (value.WindowDurationMins.Kind)
        {
            case FieldPatchKind.Missing:
                if (current?.WindowDurationMins is not { } known || !IsKnownDuration(known))
                {
                    return WindowMergeResult.Refresh(FullRefreshReason.UnknownWindowIdentity);
                }

                duration = known;
                break;
            case FieldPatchKind.Null:
                return WindowMergeResult.Refresh(FullRefreshReason.UnknownWindowIdentity);
            case FieldPatchKind.Value:
                var updated = value.WindowDurationMins.Value;
                if (!IsKnownDuration(updated))
                {
                    return WindowMergeResult.Refresh(FullRefreshReason.UnknownWindowIdentity);
                }

                if (current?.WindowDurationMins is { } previous && previous != updated)
                {
                    return WindowMergeResult.Refresh(FullRefreshReason.WindowIdentityChanged);
                }

                duration = updated;
                break;
            default:
                return WindowMergeResult.Refresh(FullRefreshReason.InvalidPatch);
        }

        return WindowMergeResult.Success(new RateLimitWindow(
            Apply(value.UsedPercent, current?.UsedPercent),
            duration,
            Apply(value.ResetsAt, current?.ResetsAt)));
    }

    private static T? Apply<T>(FieldPatch<T> patch, T? current) where T : struct => patch.Kind switch
    {
        FieldPatchKind.Missing => current,
        FieldPatchKind.Null => null,
        FieldPatchKind.Value => patch.Value,
        _ => current,
    };

    private static bool IsKnownDuration(int duration) =>
        duration is FiveHourMinutes or WeeklyMinutes;

    private readonly record struct WindowMergeResult(
        RateLimitWindow? Window,
        FullRefreshReason? RefreshReason)
    {
        public static WindowMergeResult Success(RateLimitWindow? window) => new(window, null);
        public static WindowMergeResult Refresh(FullRefreshReason reason) => new(null, reason);
    }
}

public static class RateLimitJson
{
    public static bool TryParsePayload(JsonElement element, out RateLimitPayload payload)
    {
        payload = RateLimitPayload.Empty;
        if (element.ValueKind != JsonValueKind.Object ||
            !TryReadWindow(element, "primary", out var primary) ||
            !TryReadWindow(element, "secondary", out var secondary))
        {
            return false;
        }

        var additional = new List<RateLimitWindow>();
        if (element.TryGetProperty("additional", out var additionalElement))
        {
            if (additionalElement.ValueKind != JsonValueKind.Array)
            {
                return false;
            }

            foreach (var item in additionalElement.EnumerateArray())
            {
                if (!TryParseWindow(item, out var window) || window is null)
                {
                    return false;
                }

                additional.Add(window);
            }
        }

        payload = new RateLimitPayload(primary, secondary, additional);
        return true;
    }

    public static bool TryParsePatch(JsonElement element, out RateLimitPatch patch)
    {
        patch = new RateLimitPatch(
            FieldPatch<RateLimitWindowPatch>.Missing,
            FieldPatch<RateLimitWindowPatch>.Missing);
        if (element.ValueKind != JsonValueKind.Object ||
            !TryReadWindowPatch(element, "primary", out var primary) ||
            !TryReadWindowPatch(element, "secondary", out var secondary))
        {
            return false;
        }

        patch = new RateLimitPatch(primary, secondary);
        return true;
    }

    private static bool TryReadWindow(
        JsonElement parent,
        string propertyName,
        out RateLimitWindow? window)
    {
        window = null;
        if (!parent.TryGetProperty(propertyName, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        return TryParseWindow(element, out window);
    }

    private static bool TryParseWindow(JsonElement element, out RateLimitWindow? window)
    {
        window = null;
        if (element.ValueKind != JsonValueKind.Object ||
            !TryReadNullableFiniteDouble(element, "usedPercent", out var usedPercent) ||
            !TryReadNullableInt(element, "windowDurationMins", out var duration) ||
            !TryReadNullableLong(element, "resetsAt", out var resetsAt))
        {
            return false;
        }

        window = new RateLimitWindow(usedPercent, duration, resetsAt);
        return true;
    }

    private static bool TryReadWindowPatch(
        JsonElement parent,
        string propertyName,
        out FieldPatch<RateLimitWindowPatch> patch)
    {
        patch = FieldPatch<RateLimitWindowPatch>.Missing;
        if (!parent.TryGetProperty(propertyName, out var element))
        {
            return true;
        }

        if (element.ValueKind == JsonValueKind.Null)
        {
            patch = FieldPatch<RateLimitWindowPatch>.Null;
            return true;
        }

        if (element.ValueKind != JsonValueKind.Object ||
            !TryReadDoublePatch(element, "usedPercent", out var used) ||
            !TryReadIntPatch(element, "windowDurationMins", out var duration) ||
            !TryReadLongPatch(element, "resetsAt", out var resetsAt))
        {
            return false;
        }

        patch = FieldPatch<RateLimitWindowPatch>.FromValue(new RateLimitWindowPatch(
            used,
            duration,
            resetsAt));
        return true;
    }

    private static bool TryReadNullableFiniteDouble(
        JsonElement parent,
        string name,
        out double? value)
    {
        value = null;
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number ||
            !element.TryGetDouble(out var number) ||
            !double.IsFinite(number))
        {
            return false;
        }

        value = number;
        return true;
    }

    private static bool TryReadNullableInt(JsonElement parent, string name, out int? value)
    {
        value = null;
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out var number))
        {
            return false;
        }

        value = number;
        return true;
    }

    private static bool TryReadNullableLong(JsonElement parent, string name, out long? value)
    {
        value = null;
        if (!parent.TryGetProperty(name, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt64(out var number))
        {
            return false;
        }

        value = number;
        return true;
    }

    private static bool TryReadDoublePatch(JsonElement parent, string name, out FieldPatch<double> patch)
    {
        patch = FieldPatch<double>.Missing;
        if (!parent.TryGetProperty(name, out var element))
        {
            return true;
        }

        if (element.ValueKind == JsonValueKind.Null)
        {
            patch = FieldPatch<double>.Null;
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number ||
            !element.TryGetDouble(out var number) ||
            !double.IsFinite(number))
        {
            return false;
        }

        patch = FieldPatch<double>.FromValue(number);
        return true;
    }

    private static bool TryReadIntPatch(JsonElement parent, string name, out FieldPatch<int> patch)
    {
        patch = FieldPatch<int>.Missing;
        if (!parent.TryGetProperty(name, out var element))
        {
            return true;
        }

        if (element.ValueKind == JsonValueKind.Null)
        {
            patch = FieldPatch<int>.Null;
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt32(out var number))
        {
            return false;
        }

        patch = FieldPatch<int>.FromValue(number);
        return true;
    }

    private static bool TryReadLongPatch(JsonElement parent, string name, out FieldPatch<long> patch)
    {
        patch = FieldPatch<long>.Missing;
        if (!parent.TryGetProperty(name, out var element))
        {
            return true;
        }

        if (element.ValueKind == JsonValueKind.Null)
        {
            patch = FieldPatch<long>.Null;
            return true;
        }

        if (element.ValueKind != JsonValueKind.Number || !element.TryGetInt64(out var number))
        {
            return false;
        }

        patch = FieldPatch<long>.FromValue(number);
        return true;
    }
}
