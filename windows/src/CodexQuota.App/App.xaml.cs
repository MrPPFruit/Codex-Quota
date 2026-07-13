using CodexQuota.Core;
using Microsoft.Win32;
using System.IO;
using System.Security;

namespace CodexQuota.App;

public partial class App : System.Windows.Application
{
    private SingleInstanceGuard? _singleInstance;
    private BoundedDiagnosticLog? _diagnostics;
    private OverlayWindow? _overlay;
    private TrayController? _tray;
    private UsageSessionCoordinator? _coordinator;
    private CancellationTokenSource? _lifetime;
    private Task? _presenceTask;
    private bool _userHidden;
    private bool _codexPresent;
    private int _shutdownStarted;

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
        _overlay = new OverlayWindow();
        try
        {
            using var preferences = Registry.CurrentUser.CreateSubKey(@"Software\CodexQuota", writable: false);
            _userHidden = preferences?.GetValue("UserHidden") is int hidden && hidden != 0;
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException) { }
        var startup = new StartupRegistration();
        if (startup.ShouldEnableAtLaunch)
        {
            _ = startup.SetEnabled(true);
        }
        _tray = new TrayController(startup, ToggleVisibility, () => _ = BeginShutdownAsync());
        _lifetime = new CancellationTokenSource();
        var locator = new WindowsCodexExecutableLocator(_diagnostics);
        _coordinator = new UsageSessionCoordinator(locator, _diagnostics, Publish);
        var probe = new WindowsCodexProcessProbe(_diagnostics);
        var monitor = new CodexPresenceMonitor(probe);
        _presenceTask = monitor.RunAsync(_coordinator.PresenceChangedAsync, _lifetime.Token);
    }

    protected override void OnExit(System.Windows.ExitEventArgs e)
    {
        _tray?.Dispose();
        _overlay?.Close();
        _diagnostics?.Write("lifecycle", "Codex Quota stopped");
        _singleInstance?.Dispose();
        base.OnExit(e);
    }

    private void Publish(bool codexPresent, UsageSnapshot snapshot)
    {
        Dispatcher.InvokeAsync(() =>
        {
            _codexPresent = codexPresent;
            _overlay?.UpdateSnapshot(snapshot);
            if (codexPresent && !_userHidden) _overlay?.ShowWithoutActivation();
            else _overlay?.Hide();
        });
    }

    private void ToggleVisibility()
    {
        _userHidden = !_userHidden;
        try
        {
            using var preferences = Registry.CurrentUser.CreateSubKey(@"Software\CodexQuota", writable: true);
            preferences.SetValue("UserHidden", _userHidden ? 1 : 0, RegistryValueKind.DWord);
        }
        catch (Exception error) when (error is SecurityException or UnauthorizedAccessException or IOException) { }
        if (!_userHidden && _codexPresent) _overlay?.ShowWithoutActivation();
        else _overlay?.Hide();
    }

    private async Task BeginShutdownAsync()
    {
        if (Interlocked.Exchange(ref _shutdownStarted, 1) != 0) return;
        try
        {
            _lifetime?.Cancel();
            if (_presenceTask is not null)
            {
                try { await _presenceTask.ConfigureAwait(false); }
                catch (Exception error) { _diagnostics?.Write("presence", error.GetType().Name); }
            }
            try
            {
                if (_coordinator is not null) await _coordinator.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception error)
            {
                _diagnostics?.Write("shutdown", error.GetType().Name);
            }
        }
        finally
        {
            _lifetime?.Dispose();
            await Dispatcher.InvokeAsync(Shutdown);
        }
    }
}
