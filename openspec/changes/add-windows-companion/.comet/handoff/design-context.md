# Comet Design Handoff

- Change: add-windows-companion
- Phase: design
- Mode: compact
- Context hash: daf49d2f461c7433f93e7507bbf97a7d69ca5e0e428dc1b76ed91ed618afd16f

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/add-windows-companion/proposal.md

- Source: openspec/changes/add-windows-companion/proposal.md
- Lines: 1-29
- SHA256: ff14c99f0d9b9774c9fec932fb0ede6a6645c6b2dcfb94a4fbbd0dcc88cf734b

```md
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
```

## openspec/changes/add-windows-companion/design.md

- Source: openspec/changes/add-windows-companion/design.md
- Lines: 1-86
- SHA256: d3f34d146523092a0fb17cae937a66b80ed5faa65f74df070b9ad06beaf575ee

[TRUNCATED]

```md
## Context

当前产品由 Swift 6.2、AppKit 和 SwiftUI 构成，额度模型与 app-server 协议语义已经稳定，但所有窗口、进程、签名、登录项和生命周期代码均为 macOS 专用。Windows Codex Desktop 采用 MSIX/WindowsApps 与每用户 helper mirror，公开问题显示不同版本可能出现路径分裂或 WindowsApps ACL 阻止直接执行，因此 locator 是兼容性与安全边界，不可用 PATH 猜测代替。

Windows 首版需要让用户下载后参与真实设备验证；开发环境与 GitHub runner 没有用户的 Store Codex 安装、登录态、SmartScreen 和多 DPI 桌面，故产物只能是 Preview。

## Goals / Non-Goals

**Goals:**

- 在不改变 macOS 实现的前提下新增 Windows 11 x64 原生 companion。
- 保持额度、稀疏更新、断线、生命周期、悬浮交互和用户偏好语义一致。
- 以最少依赖生成可直接下载的 self-contained Windows 产物。
- 把可由 CI 证明与必须由真实 Windows 证明的证据明确分层。

**Non-Goals:**

- 不做 Electron/Tauri 跨平台重写、WinUI 3、Microsoft Store/MSIX、安装器或自动更新器。
- 不做 Windows ARM64、Windows 10、WSL 模式、宠物吸附、历史曲线、通知或遥测。
- 不把未签名构建、CI fixture 或 macOS 截图描述为 Windows 稳定版实机证据。

## Decisions

### 1. 使用 WPF + .NET 10 的独立 Windows 宿主

新增 `windows/` 下的 C# 解决方案，核心库负责额度模型、JSON-RPC、locator 与生命周期，WPF App 负责窗口、托盘、偏好和 Win32 互操作。发布使用 `net10.0-windows`、`win-x64`、self-contained、single-file、`PublishTrimmed=false`。

选择 WPF 是因为透明异形窗口、文本、动画、DPI 与辅助功能均有成熟原生路径；WinForms `NotifyIcon` 作为 .NET 自带托盘能力。相比 WinUI 3，它不需要 Windows App SDK 部署；相比 Tauri 或 Rust，它避免引入 WebView 或自建文本/可访问性基础设施。

### 2. 平台代码并存，语义通过 fixtures 对齐

不建立跨语言 FFI 或共享运行时。Swift 与 C# 各自保留平台原生实现，共享 JSON fixture 和显式测试契约：300/10080 分钟窗口、稀疏 patch、非法数字、断线、帧上限和刷新规则。这样比把稳定 macOS 代码迁移到新框架更小，也避免 Windows 风险波及现有版本。

### 3. locator 先绑定官方包，再验证少量 helper

生命周期检测先使用 Win32 package identity API确认运行中的 package family 为官方 Codex。候选仅来自当前 Codex 每用户 mirror 的明确 canonical 根目录；拒绝 reparse point、目录逃逸和 PATH 回退。候选必须通过 WinVerifyTrust、能力探针和总 deadline 后才能执行。

首个 Preview 不猜写固定 signer subject；代码记录验证后的 signer/package publisher 类型并 fail closed。真实 Windows probe 用于确认官方当前 signer 后再决定是否收紧 allowlist。WindowsApps 内资源路径只作为诊断证据，不作为默认执行来源。

### 4. 单连接生命周期与有界清理

一个后台 coordinator 管理 `Codex presence → locator → app-server connection → snapshots → overlay`。每次连接独占 Process 和 generation；断线先发布 unavailable，再有界退避重连。退出只操作自身持有的 Process 对象与其仍匹配的进程树；清理未确认时不报告成功。

### 5. 使用 Win32 无激活窗口策略和空间迟滞

WPF Window 使用 `WindowStyle=None`、`AllowsTransparency=True`、`ShowInTaskbar=false`，创建 HWND 后设置 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`，处理 `WM_MOUSEACTIVATE → MA_NOACTIVATE`。拖动通过 `WM_NCHITTEST → HTCAPTION`，透明形状外返回 `HTTRANSPARENT`。

几何仅由 180ms 窗口过渡驱动；内容先淡出后淡入并裁切在实时轮廓内。hover 保持区复用 macOS 已验证的“入口 frame ∪ 展开 frame + 10 DIP”，避免屏幕边缘振荡。循环色流固定中心和尺寸，只旋转颜色相位；Reduce Motion 时移除动画时钟。

### 6. PerMonitorV2 与中心锚点持久化

manifest 声明 PerMonitorV2。WPF 内容使用 DIP，Win32 monitor/work-area 与指针物理像素在单一边界转换。只保存收起气泡中心、显示器设备名、可见性和登录项 opt-out；不保存展开尺寸。显示器消失时钳制到可容纳面板的工作区。

### 7. HKCU Run 和便携 ZIP

登录启动使用 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 的单一 `CodexQuota` value。首次稳定路径启动自动注册；用户关闭后持久化 opt-out。临时路径拒绝注册，不自复制、不安装服务、不写 HKLM。

发布包为未签名 ZIP，不生成自签名证书。`v0.2.0-preview.1` 必须是 GitHub Prerelease，说明 SmartScreen/Unknown publisher、企业设备限制、SHA-256 边界和手动升级方式。

### 8. 诊断只保留最小脱敏证据

为 Windows 实机联调保留有界本地诊断：locator 候选类别、拒绝原因、协议阶段、进程清理结果和 DPI/显示器数量。不得记录账户标识、token、完整用户目录、窗口标题或额度历史；用户可从托盘打开诊断目录。

## Risks / Trade-offs

- [官方 Windows Codex helper 路径或签名与当前假设不同] → locator fail closed，Preview 通过脱敏 probe 收集证据后再调整；不回退 PATH。
- [WPF 透明窗口在不同 GPU/DPI 下视觉或命中不一致] → CI 只验证纯几何，真实 100/125/150% 与多屏截图作为发布后验收门。
- [self-contained 单文件体积较大] → 接受体积换取用户无需安装 .NET；不启用 WPF 不安全的 trimming，压缩只在测量启动成本后决定。
- [未签名 EXE 被 SmartScreen 阻止] → 明确 Prerelease 和手动放行说明；不使用自签名证书或关闭系统防护。
- [2 秒进程检测产生常驻开销] → Codex 缺席时只做包/进程存在检查，发现可信进程后等待进程退出；不引入 WMI 依赖或 1 秒 heartbeat。
- [Windows 用户实测失败] → 不影响 macOS 分支与已有 Release；Preview 可通过新提交和新预发布版本迭代，已有标签不改写。

## Migration Plan

1. 在独立分支新增 Windows 源码、fixtures、CI 和文档，保持 macOS job 通过。
2. 由 Windows runner 生成并验证 `v0.2.0-preview.1` 候选资产。
3. 以 GitHub Prerelease 发布 Windows x64 ZIP 与 SHA-256。
4. 用户在真实 Windows 11 x64 上完成规定清单并反馈诊断。
5. 根据 probe 证据修正 locator/窗口兼容问题，以新的 Preview 标签发布；真实验收完成前不发布稳定 `v0.2.0`。

```

Full source: openspec/changes/add-windows-companion/design.md

## openspec/changes/add-windows-companion/tasks.md

- Source: openspec/changes/add-windows-companion/tasks.md
- Lines: 1-39
- SHA256: f3b9fb82c4ae8be7e419b913f2ab66b8a32b19afca5249df12d372c5d40d7d95

```md
## 1. Windows 工程与共享契约

- [ ] 1.1 创建 `windows/` 下的 .NET 10 WPF App、Core 与测试工程，固定 win-x64 self-contained single-file、trimming 关闭和 PerMonitorV2 manifest
- [ ] 1.2 提取语言无关额度与 JSON-RPC fixtures，并为 C# 实现覆盖 300/10080 窗口、稀疏 patch、非法字段、有限数字和 1 MiB 帧上限
- [ ] 1.3 增加单实例、版本身份、最小脱敏诊断和 Windows 产品图标资源

## 2. Codex 生命周期与协议

- [ ] 2.1 实现官方 Codex MSIX package identity 检测与缺席时低开销生命周期监控
- [ ] 2.2 实现 canonical helper locator、reparse point 拒绝、WinVerifyTrust、确定性候选优先级和有界 capability probe
- [ ] 2.3 实现 JSONL stdio app-server 客户端、完整快照、稀疏更新、安全刷新、断线不可用与有界重连
- [ ] 2.4 实现 Process 所有权、有界退出和 Codex 启停 session coordinator，覆盖快速启停和清理失败测试

## 3. Windows 悬浮气泡

- [ ] 3.1 实现无激活、无任务栏、Topmost 透明 WPF 窗口及透明角 hit-test、HTCAPTION 拖动和位置持久化
- [ ] 3.2 实现 52×52 / 130×78 DIP 单一彩色气泡、固定几何色流、额度回退、语义色和紧凑展开排版
- [ ] 3.3 实现 180ms 可中断展开/收起、内容交叉淡入淡出、10 DIP 空间迟滞和 Reduce Motion
- [ ] 3.4 实现 PerMonitorV2、工作区钳制、负坐标、多 DPI 与显示器拔插的纯布局测试

## 4. 托盘、偏好与启动项

- [ ] 4.1 使用 WinForms NotifyIcon 实现显示/隐藏、登录时启动、诊断目录和退出菜单
- [ ] 4.2 实现 HKCU Run 首次稳定路径注册、临时路径拒绝、opt-out 持久化和路径迁移更新
- [ ] 4.3 验证用户隐藏偏好、Codex 生命周期、托盘退出和登录启动不会互相覆盖

## 5. CI 与打包

- [ ] 5.1 扩展 GitHub Actions 为独立 macOS 与 Windows job，并锁定第三方 Action 提交
- [ ] 5.2 增加 Windows Release publish 和 ZIP 脚本，验证测试、PE x64、版本、single-file、未签名状态、归档内容及 SHA-256
- [ ] 5.3 更新 README、CHANGELOG、Windows 安装/SmartScreen/升级/隐私说明和平台支持矩阵
- [ ] 5.4 从干净提交在 Windows runner 生成候选并回下载复验资产

## 6. 审查与预发布

- [ ] 6.1 对 locator、进程所有权、注册表、诊断脱敏和未签名分发完成独立安全/架构复审
- [ ] 6.2 保持 macOS Swift、Node、构建和签名回归通过，Windows Core/UI 状态测试全部通过
- [ ] 6.3 使用 MrPPFruit 账号创建 `v0.2.0-preview.1` GitHub Prerelease，上传 Windows x64 ZIP 与 SHA-256 并验证线上资产
- [ ] 6.4 在用户真实 Windows 11 x64 上完成 Store Codex locator、真实额度、焦点、hover/拖动、SmartScreen、DPI、登录启动和残留进程验收
```

## openspec/changes/add-windows-companion/specs/windows-companion/spec.md

- Source: openspec/changes/add-windows-companion/specs/windows-companion/spec.md
- Lines: 1-107
- SHA256: 7a1b36d36a43cef1bc34890976bc67fae28adfc19ed46fcca3f8586f1d743079

[TRUNCATED]

```md
## ADDED Requirements

### Requirement: Windows 原生后台伴侣
系统 SHALL 提供 Windows 11 x64 原生后台应用，并以当前用户单实例运行。应用 SHALL 在 Codex Desktop 运行时允许显示额度悬浮窗，在 Codex 退出时关闭自身创建的 app-server 子进程并隐藏悬浮窗；应用本身保留托盘进程等待 Codex 再次启动。

#### Scenario: Codex 启动与退出
- **WHEN** 可信的官方 Codex Windows 包进程从缺席变为运行，随后再次退出
- **THEN** 系统启动一个额度会话并显示悬浮窗，退出后有界关闭该会话、隐藏悬浮窗且不遗留所属 app-server 子进程

#### Scenario: 重复启动伴侣
- **WHEN** 当前用户已经运行一个 Codex Quota 实例后再次启动同一程序
- **THEN** 第二个实例立即退出且不创建第二个托盘、窗口、启动项或 app-server 子进程

#### Scenario: Codex 缺席
- **WHEN** 用户登录后 Codex Quota 自动启动而 Codex Desktop 尚未运行
- **THEN** 系统仅保留低开销托盘与生命周期检测，不显示额度气泡也不启动 app-server

### Requirement: Codex 可执行文件发现与信任 Gate
系统 MUST 只从运行中的官方 Codex MSIX 包身份和少量明确的每用户 Codex helper 根目录推导候选。系统 MUST 拒绝任意 PATH 猜测、相对路径、reparse point、超出允许根目录的文件及未通过真实性检查的候选；没有候选通过时 SHALL 安全降级为不可用，且 MUST NOT 读取、复制或保存 Codex 认证文件。

#### Scenario: 可信 helper 可用
- **WHEN** 官方 Codex 包正在运行，候选位于允许的 canonical 根目录、无 reparse point、Authenticode 验证有效且在总 deadline 内通过 app-server capability probe
- **THEN** 系统仅使用该绝对路径以 `UseShellExecute=false` 启动 `app-server --stdio`

#### Scenario: 候选不可信或不可执行
- **WHEN** 候选来自 PATH、目录逃逸、reparse point、无效签名、能力探针失败或超时
- **THEN** 系统拒绝执行该候选，额度状态为不可用并保留可诊断但不含账户标识的原因

#### Scenario: 多个可信候选
- **WHEN** 多个候选均通过真实性与能力检查
- **THEN** 系统使用确定性的优先级选择官方每用户 mirror 中与当前 Codex 包匹配的候选，不按文件更新时间或递归扫描结果猜测

### Requirement: Windows 额度协议语义
系统 SHALL 通过 JSONL stdio 执行 `initialize → initialized → account/rateLimits/read`，识别 300 分钟与 10080 分钟窗口，并把 `usedPercent` 转换为剩余百分比。系统 MUST 支持稀疏 `account/rateLimits/updated`、完整刷新、断线不可用、有界退避重连、有限数字校验和 1 MiB 单帧上限。

#### Scenario: 完整快照
- **WHEN** app-server 返回包含 300 分钟和 10080 分钟窗口的合法完整快照
- **THEN** 系统发布 5 小时与本周的剩余百分比和本地化重置时间，剩余值限制在 0 到 100

#### Scenario: 稀疏更新
- **WHEN** 已知窗口收到只包含部分字段的合法更新
- **THEN** 系统保留未更新字段并发布合并结果；窗口身份未知、改变或字段类型非法时改为读取完整快照

#### Scenario: 断线与重连
- **WHEN** app-server 退出、stdout 中断、请求超时或 JSON 帧超过上限
- **THEN** 系统立即发布不可用、清理当前连接，并以有界指数退避创建新连接；新连接完整快照到达前不得合并旧连接更新

#### Scenario: 关闭所有权
- **WHEN** Codex 退出或用户退出 Codex Quota
- **THEN** 系统只终止自身创建且身份仍匹配的 app-server 进程树，并在最终期限内确认退出；无法确认时报告清理失败而不是终止无关进程

### Requirement: Windows 悬浮气泡与交互
系统 SHALL 提供置顶、无任务栏按钮且不激活前台应用的透明 WPF 悬浮窗。收起态 SHALL 为 52×52 DIP，展开态 SHALL 为 130×78 DIP；视觉 SHALL 延续单一彩色气泡、固定几何内单向色流、额度语义色与紧凑两行布局，并尊重 Windows 减少动画设置。

#### Scenario: hover 展开与空间迟滞
- **WHEN** 指针进入收起圆形后停留，随后移动到展开窗口边缘并离开
- **THEN** 窗口平滑展开且不抢焦点，保持区使用收起入口与展开矩形的并集外扩 10 DIP，只有真正离开保持区才收起且不得临界振荡

#### Scenario: 拖动与位置记忆
- **WHEN** 用户拖动收起或展开气泡并重启应用
- **THEN** 系统保存收起气泡中心锚点和显示器身份，程序动画不得覆盖该位置；原显示器缺失时把锚点钳制到可用工作区

#### Scenario: 多 DPI 与工作区
- **WHEN** 气泡位于 100%、125% 或 150% 缩放显示器，或任务栏位于任一屏幕边缘
- **THEN** 系统以 PerMonitorV2 处理 DIP 与物理像素转换，窗口始终位于当前显示器工作区且文字、透明角和命中区域保持正确

#### Scenario: 减少动画
- **WHEN** Windows 客户端区域动画被关闭
- **THEN** 系统停止循环色流并即时切换展开状态，不保留延迟、残影或不可见辅助功能内容

#### Scenario: 额度回退
- **WHEN** 5 小时窗口不可用而本周窗口可用
- **THEN** 收起态完整切换为本周额度，包括标签、数值、颜色和辅助功能语义

### Requirement: 托盘、可见性与登录启动
系统 SHALL 使用 Windows 托盘提供显示/隐藏、登录时启动和退出。首次从稳定路径正常启动时 SHALL 尝试注册当前用户 HKCU Run 项；用户关闭后 MUST 持久化 opt-out 且后续启动不得自动恢复。临时目录或不稳定路径 MUST 拒绝注册。

#### Scenario: 首次稳定启动
- **WHEN** 用户从非临时的绝对路径首次正常启动应用
- **THEN** 系统创建或更新自身 HKCU Run value，并在托盘菜单显示已启用状态
```

Full source: openspec/changes/add-windows-companion/specs/windows-companion/spec.md
