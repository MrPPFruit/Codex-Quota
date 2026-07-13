---
comet_change: add-windows-companion
role: technical-design
canonical_spec: openspec
---

## 实现决策

- `windows/CodexQuota.Windows.sln` 包含一个无框架 Core、一个 WPF App 和一个测试工程；不引入 MVVM/DI/日志/自动更新框架。
- Core 使用 `System.Text.Json` 与 `Process` 实现协议，App 只通过 snapshot/event 接口消费，不解析 JSON。
- Codex presence 绑定官方 MSIX package family；locator 只枚举固定每用户 mirror 候选，依次执行 canonical/reparse、WinVerifyTrust 和 capability probe，不使用 PATH。
- WPF HWND 使用 NOACTIVATE/TOOLWINDOW/MOUSEACTIVATE 原生策略；所有 Win32 像素在窗口边界转换为 DIP，布局纯函数可在 CI 测试。
- 悬浮层视觉沿用单一自动适配彩色气泡。色场固定几何、相位单向旋转；窗口 180ms 形变与内容淡入淡出互斥，hover 使用 10 DIP 空间迟滞。
- 首次从稳定路径运行时注册 HKCU Run；只管理自身 value，用户 opt-out 优先于首次启动策略。
- 发布为 .NET 10 self-contained、win-x64、single-file、no trim ZIP；无 Authenticode 证书时仅发布 GitHub Prerelease。

## 依赖与边界

- 运行依赖 Windows 11 x64 与官方 Codex Desktop 登录态，不读取认证文件。
- 托盘复用 .NET 自带 WinForms NotifyIcon；仅使用必要 Win32 P/Invoke，不增加 Windows App SDK。
- CI 依赖锁定 commit 的 checkout/setup-dotnet；Windows 资产只由 Windows runner 生成。
- 真实 Store helper signer、SmartScreen、焦点、DPI 与多屏只能在用户 Windows 设备验证。

## 主要风险

- Helper mirror 或签名不符合推断时必须不可用，不执行宽松回退；脱敏诊断用于下一 Preview 修正。
- WPF 透明合成可能在部分 GPU 上有性能/锯齿差异；循环色流只在可见且未减少动画时运行。
- 单文件体积会大于原生 Rust，但换取零运行时安装与显著更低 UI/可访问性复杂度。
- 未签名 EXE 会触发 SmartScreen；文档不得把 SHA-256 描述为身份认证。

## 测试 seam

- 文件系统、签名、package identity、Process transport、clock、pointer、monitor 和 registry 均通过窄接口注入。
- 共享 JSON fixtures 固定跨语言协议语义；C# 负责完整解析/重连测试，Swift 保持现有回归。
- WPF 视图状态通过 presentation model、纯布局和 HWND policy 测试；Windows runner 只做 smoke，不冒充视觉实机。
- Release 回下载后再次校验 SHA-256、PE x64、产品版本、未签名状态和 ZIP 内容。

## 回滚与迁移

- Windows 源码位于独立目录，删除该目录与 Windows CI job 即可回滚，不修改 Swift targets。
- 已发布 Preview 标签不覆盖；失败修复使用新的 `preview.N`。
- 真实 Windows 验收未完成前保持 OpenSpec change 未归档，稳定 `v0.2.0` 不创建。

## 非目标

- 不做 MSIX/安装器、ARM64、Windows 10、WSL、宠物吸附、自动更新、遥测或跨平台 UI 重写。
