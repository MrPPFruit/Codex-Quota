# 更新记录

## 0.2.0-preview.1 - 2026-07-14

- 新增 Windows 11 x64 原生 WPF Preview，提供 Codex 生命周期联动、额度气泡、托盘与用户级登录启动。
- Windows 包为 self-contained single-file ZIP，不要求单独安装 .NET。
- 首个 Windows Preview 未进行商业代码签名，需通过 SHA-256 校验并接受 SmartScreen 测试边界。

## 0.1.1-preview.1 - 2026-07-14

- 增加 arm64、ad-hoc 签名、未公证预览包及 SHA-256 校验文件，没有新增核心功能。
- 明确 Gatekeeper 手动放行步骤和未签名分发风险。

## 0.1.0 - 2026-07-13

- 首个公开源码版本。
- 显示 Codex 的 5 小时与周额度及重置时间。
- 支持独立悬浮、拖动与位置记忆、悬停展开和状态色流。
- Codex 启动时显示、退出时隐藏。
- 安装到 Applications 后首次启动会自动尝试注册为 macOS 登录项，用户可随时关闭。
