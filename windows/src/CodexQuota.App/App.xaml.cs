namespace CodexQuota.App;

public partial class App : System.Windows.Application
{
    private SingleInstanceGuard? _singleInstance;
    private BoundedDiagnosticLog? _diagnostics;

    protected override void OnStartup(System.Windows.StartupEventArgs e)
    {
        base.OnStartup(e);
        _singleInstance = SingleInstanceGuard.TryAcquire();
        if (!_singleInstance.OwnsInstance)
        {
            Shutdown();
            return;
        }

        _diagnostics = new BoundedDiagnosticLog();
        _diagnostics.Write("lifecycle", "Codex Quota 0.2.0 started");
    }

    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        _diagnostics?.Write("lifecycle", "Codex Quota stopped");
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
