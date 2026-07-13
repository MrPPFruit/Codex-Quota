# Codex Quota v0.1.1 Preview

这是 Codex Quota 首个可直接下载的 macOS 预览版本。它是 **ad-hoc 签名、未经 Apple 公证** 的构建，不是经过 Developer ID 验证的正式分发版本。

## 系统要求

- Apple silicon Mac（arm64）
- macOS 26 或更高版本
- Codex 安装在 `/Applications/ChatGPT.app`

## 安装

1. 下载 ZIP，解压后把 `Codex Quota.app` 移到 `/Applications`。
2. 首次双击时，macOS 会阻止打开，这是当前预览版的预期行为。
3. 在首次尝试打开后的约一小时内，进入“系统设置 → 隐私与安全性”。
4. 找到 Codex Quota，点击“仍要打开 / Open Anyway”，再确认打开。

受组织策略管理的 Mac 可能不提供“仍要打开”，此类设备可能无法运行该预览版。请不要关闭 Gatekeeper，也不要执行删除隔离属性的命令。

## 已知限制

- Apple 无法验证此构建的开发者身份，也没有提供公证恶意软件检查结果。
- SHA-256 文件只能用于核对下载是否与本 Release 资产一致，不能证明发布者身份，也不能替代 Developer ID 签名。
- 当前没有自动更新器。升级时请先退出 Codex Quota，再替换 `/Applications` 中的旧版本。
- ad-hoc 构建升级后，macOS 可能要求再次执行“仍要打开”。如果“登录时启动”失效，请在菜单中关闭后重新开启该选项。

未来取得 Apple Developer Program 资格后，将改用 Developer ID 签名和 Apple 公证，并以稳定版本发布。
