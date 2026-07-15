namespace CodexQuota.App;

internal readonly record struct StartupMenuPresentation(
    string Title,
    string ToolTipText,
    bool IsEnabled,
    bool IsChecked)
{
    public static StartupMenuPresentation Create(bool canRegister, bool isRegistered)
    {
        if (isRegistered || canRegister)
        {
            return new StartupMenuPresentation(
                "登录 Windows 时启动",
                string.Empty,
                true,
                isRegistered);
        }

        return new StartupMenuPresentation(
            "登录 Windows 时启动（需固定安装）",
            "请将程序解压到 %LOCALAPPDATA%\\Programs\\Codex Quota 后重新打开。",
            false,
            false);
    }
}
