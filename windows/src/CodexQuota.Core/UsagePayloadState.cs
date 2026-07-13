namespace CodexQuota.Core;

public readonly record struct PatchApplication(UsageSnapshot? Snapshot, bool RequiresFullRefresh);

public sealed class UsagePayloadState
{
    private readonly object _gate = new();
    private RateLimitPayload? _payload;
    private long _revision;

    public long CaptureRevision()
    {
        lock (_gate) return _revision;
    }

    public bool TryCommitFull(long expectedRevision, RateLimitPayload payload, out UsageSnapshot snapshot)
    {
        lock (_gate)
        {
            if (_revision != expectedRevision)
            {
                snapshot = UsageSnapshot.Unavailable;
                return false;
            }
            _payload = payload;
            _revision++;
            snapshot = UsageNormalizer.Normalize(payload);
            return true;
        }
    }

    public bool TryCommitFullAndPublish(long expectedRevision, RateLimitPayload payload, Action<UsageSnapshot> publish)
    {
        ArgumentNullException.ThrowIfNull(publish);
        lock (_gate)
        {
            if (_revision != expectedRevision) return false;
            _payload = payload;
            _revision++;
            publish(UsageNormalizer.Normalize(payload));
            return true;
        }
    }

    public PatchApplication Apply(RateLimitPatch patch)
    {
        lock (_gate)
        {
            if (_payload is null)
            {
                _revision++;
                return new PatchApplication(null, true);
            }
            var merged = UsageNormalizer.Merge(_payload, patch);
            if (merged.RequiresFullRefresh || merged.Payload is null)
            {
                _payload = null;
                _revision++;
                return new PatchApplication(null, true);
            }
            _payload = merged.Payload;
            _revision++;
            return new PatchApplication(UsageNormalizer.Normalize(merged.Payload), false);
        }
    }

    public bool ApplyAndPublish(RateLimitPatch patch, Action<UsageSnapshot> publish)
    {
        ArgumentNullException.ThrowIfNull(publish);
        lock (_gate)
        {
            if (_payload is null)
            {
                _revision++;
                return false;
            }
            var merged = UsageNormalizer.Merge(_payload, patch);
            if (merged.RequiresFullRefresh || merged.Payload is null)
            {
                _payload = null;
                _revision++;
                return false;
            }
            _payload = merged.Payload;
            _revision++;
            publish(UsageNormalizer.Normalize(merged.Payload));
            return true;
        }
    }
}
