## Why

Codex Quota 目前只能在 macOS 上运行，Windows Codex 用户无法获得同样的额度悬浮提示和随 Codex 生命周期自动显隐体验。Windows 版需要在不重写稳定 macOS 宿主、也不引入跨平台 Web 壳的前提下补齐这一能力。

## What Changes

- 新增 Windows 11 x64 原生后台应用，在 Codex 运行时显示额度气泡，Codex 退出时隐藏。
- 新增 Windows 原生额度模型与 `codex app-server --stdio` 客户端，保持 5 小时/周额度、重置时间、稀疏更新、断线重连和不可用语义一致。
- 新增无任务栏、置顶但不抢焦点的可拖动悬浮窗，以及系统托盘菜单和用户级登录启动开关。
- 新增 Windows 构建、测试、self-contained 发布包与 GitHub Actions 验证。
- 更新公开文档、平台支持矩阵、安装与未签名预览分发说明。
- macOS 现有 Swift/AppKit 实现和行为不做迁移或重写。

## Capabilities

### New Capabilities

- `windows-companion`: Windows 额度数据桥、Codex 生命周期伴随、悬浮气泡、托盘控制、登录启动、构建与分发契约。

### Modified Capabilities

无。

## Impact

- 新增独立的 Windows/.NET 源码、测试和发布脚本。
- CI 从单一 macOS job 扩展为 macOS 与 Windows 两个平台 job。
- GitHub Release 增加 Windows x64 未签名预览资产及 SHA-256。
- Windows 运行时依赖 Codex Desktop 提供可执行的本地 `codex.exe app-server`；发现失败时必须安全降级为不可用，不读取或复制认证文件。
