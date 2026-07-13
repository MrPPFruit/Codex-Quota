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

WPF Window 使用 `WindowStyle=None`、`AllowsTransparency=False`、`ShowInTaskbar=false` 的非 layered HWND，创建后设置 `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`，处理 `WM_MOUSEACTIVATE → MA_NOACTIVATE`。`WM_NCHITTEST` 只负责让窗口区域外返回 `HTTRANSPARENT`；形状内统一由 WPF `DragMove()` 拥有拖动生命周期，避免原生 non-client drag 与动画中断形成双重所有者。

几何仅由 180ms 窗口过渡驱动；内容先淡出后淡入并裁切在实时轮廓内。hover 保持区复用 macOS 已验证的“入口 frame ∪ 展开 frame + 10 DIP”，避免屏幕边缘振荡。循环色流固定中心和尺寸，只旋转颜色相位；Reduce Motion 时移除动画时钟。

Windows 11 22621 及以上优先使用 DWM `DWMSBT_TRANSIENTWINDOW` 提供系统 Desktop Acrylic，并以 `SetWindowRgn` 按实时 DPI 把非 layered HWND 裁切为当前圆形或连续圆角矩形；内部 WPF 仅绘制与 macOS 同构的半透明白层、固定中心的连续二维柔光色场和文字，不再绘制独立彩色描边、黑色实底或外发光。色场使用相互重叠的高斯柔光团生成，不使用会留下扇区分界的角向分段插值；动画只旋转固定尺寸色场，不随 hover 形变重新缩放。DWM 材质初始化失败时使用同一内容表面的不透明中性浅色降级，不回退到霓虹卡片视觉。

为避免把离屏渲染误当作桌面合成证据，WPF 内容提取为无窗口依赖的 `OverlaySurface`。Windows runner 可在 STA 中固定额度、展开状态、色流相位和 Reduce Motion 后输出 52×52 与 130×78 PNG，用于验证尺寸、透明角、排版、语义色和无独立外圈；系统 Acrylic 的背景采样、窗口区域、非激活、拖动和动画只能由真实 Windows 11 桌面验证。

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
- [非 layered WPF 与 Desktop Acrylic、动态窗口区域组合在特定驱动上失败] → 真实 Windows 材质 Spike 必须同时验证背景采样、透明角、hover 和拖动；失败时明确降级，不以自绘描边伪装系统玻璃，也不在缺少证据时立即重写 WinUI。
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
6. Windows 视觉材质重构以新的 `v0.2.0-preview.2` 发布，不覆盖已公开的 `v0.2.0-preview.1` 标签或资产。

回滚方式是停止发布新的 Windows Preview 或删除未发布资产；macOS 源码和既有 Release 不受影响。已发布标签和 Release 不重写。

## Open Questions

- 当前用户 Windows Codex 版本的 package publisher、helper signer 与每用户 mirror 实际目录，需要首个 Preview probe 确认。
- 用户 Windows 设备是否为 x64、是否有多显示器及缩放组合，将决定首轮实机覆盖范围；首版不因此扩展到 ARM64。
