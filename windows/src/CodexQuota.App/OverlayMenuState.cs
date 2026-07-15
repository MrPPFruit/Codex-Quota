namespace CodexQuota.App;

internal readonly record struct OverlayMenuState(bool CodexPresent, bool VisibilityEnabled)
{
    public string VisibilityTitle => CodexPresent
        ? "显示额度小球"
        : "Codex 启动后显示小球";
}
