using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace CodexQuota.App;

internal sealed class TrayController : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly Forms.ContextMenuStrip _menu;
    private readonly StartupRegistration _startup;
    private readonly Func<OverlayMenuState> _overlayState;
    private readonly Action _toggleVisibility;
    private readonly Action _exit;
    private readonly Forms.ToolStripMenuItem _visibilityItem;
    private readonly Forms.ToolStripMenuItem _startupItem;
    private bool _disposed;

    public TrayController(
        StartupRegistration startup,
        Func<OverlayMenuState> overlayState,
        Action toggleVisibility,
        Action exit)
    {
        _startup = startup;
        _overlayState = overlayState;
        _toggleVisibility = toggleVisibility;
        _exit = exit;
        _visibilityItem = new Forms.ToolStripMenuItem();
        _visibilityItem.Click += (_, _) =>
        {
            _toggleVisibility();
            SynchronizeMenuState();
        };
        _startupItem = new Forms.ToolStripMenuItem("登录 Windows 时启动")
        {
            CheckOnClick = false,
        };
        _startupItem.Click += (_, _) =>
        {
            _ = _startup.SetEnabled(!_startup.IsEnabled);
            SynchronizeMenuState();
        };
        _menu = new Forms.ContextMenuStrip
        {
            ShowCheckMargin = true,
            ShowImageMargin = false,
            ShowItemToolTips = true,
        };
        _menu.Opening += (_, _) => SynchronizeMenuState();
        _menu.Items.Add(_visibilityItem);
        _menu.Items.Add(_startupItem);
        _menu.Items.Add(new Forms.ToolStripSeparator());
        _menu.Items.Add("退出", null, (_, _) => _exit());
        SynchronizeMenuState();
        _icon = new Forms.NotifyIcon
        {
            Text = "Codex Quota",
            Icon = Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? Drawing.SystemIcons.Application,
            ContextMenuStrip = _menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => _toggleVisibility();
    }

    public void ShowContextMenu()
    {
        if (_disposed) return;
        SynchronizeMenuState();
        _menu.Show(Forms.Control.MousePosition);
    }

    private void SynchronizeMenuState()
    {
        if (_disposed) return;
        var state = _overlayState();
        _visibilityItem.Text = state.VisibilityTitle;
        _visibilityItem.Checked = state.VisibilityEnabled;
        var startup = _startup.MenuPresentation;
        _startupItem.Text = startup.Title;
        _startupItem.ToolTipText = startup.ToolTipText;
        _startupItem.Enabled = startup.IsEnabled;
        _startupItem.Checked = startup.IsChecked;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _icon.Visible = false;
        _icon.ContextMenuStrip = null;
        _icon.Dispose();
        _menu.Dispose();
    }
}
