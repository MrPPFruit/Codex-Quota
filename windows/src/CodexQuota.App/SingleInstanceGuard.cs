namespace CodexQuota.App;

internal sealed class SingleInstanceGuard : IDisposable
{
    private readonly Mutex? _mutex;

    private SingleInstanceGuard(Mutex? mutex, bool ownsInstance)
    {
        _mutex = mutex;
        OwnsInstance = ownsInstance;
    }

    public bool OwnsInstance { get; }

    public static SingleInstanceGuard TryAcquire()
    {
        try
        {
            var mutex = new Mutex(
                initiallyOwned: true,
                name: @"Local\CodexQuota.com.ppfruit.windows",
                createdNew: out var createdNew);
            return new SingleInstanceGuard(mutex, createdNew);
        }
        catch (UnauthorizedAccessException)
        {
            return new SingleInstanceGuard(null, ownsInstance: false);
        }
    }

    public void Dispose()
    {
        if (OwnsInstance)
        {
            try
            {
                _mutex?.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // The process no longer owns the mutex; disposing is still safe.
            }
        }

        _mutex?.Dispose();
    }
}
