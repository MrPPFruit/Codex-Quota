using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace CodexQuota.App;

internal sealed class TrayController : IDisposable
{
    private readonly Forms.NotifyIcon _icon;
    private readonly StartupRegistration _startup;
    private readonly Action _toggleVisibility;
    private readonly Action _exit;
    private readonly Forms.ToolStripMenuItem _startupItem;
    private bool _updatingStartupItem;

    public TrayController(StartupRegistration startup, Action toggleVisibility, Action exit)
    {
        _startup = startup;
        _toggleVisibility = toggleVisibility;
        _exit = exit;
        _startupItem = new Forms.ToolStripMenuItem("登录 Windows 时启动")
        {
            Checked = startup.IsEnabled,
            CheckOnClick = true,
        };
        _startupItem.CheckedChanged += (_, _) =>
        {
            if (_updatingStartupItem) return;
            if (_startup.SetEnabled(_startupItem.Checked)) return;
            _updatingStartupItem = true;
            _startupItem.Checked = _startup.IsEnabled;
            _updatingStartupItem = false;
        };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示 / 隐藏", null, (_, _) => _toggleVisibility());
        menu.Items.Add(_startupItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => _exit());
        _icon = new Forms.NotifyIcon
        {
            Text = "Codex Quota",
            Icon = Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? Drawing.SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => _toggleVisibility();
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
