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

#### Scenario: 用户关闭登录启动
- **WHEN** 用户在托盘菜单关闭登录时启动
- **THEN** 系统只删除自己管理的 Run value、保存 opt-out，并在后续版本或 Codex 重启时保持关闭

#### Scenario: 临时路径启动
- **WHEN** 应用从 `%TEMP%`、压缩包临时目录或无法规范化的路径运行
- **THEN** 系统不写入 Run value，并在托盘状态中提示用户先完整解压到稳定位置

#### Scenario: 用户隐藏额度
- **WHEN** 用户选择隐藏额度后 Codex 退出并再次启动
- **THEN** 系统保持用户的隐藏偏好，不因 Codex 生命周期变化擅自重新显示

### Requirement: Windows 预览构建与分发
系统 SHALL 通过 GitHub Actions Windows runner 构建 `net10.0-windows`、win-x64、self-contained、single-file 且不裁剪的 ZIP，并生成 SHA-256。没有受信任 Authenticode 证书和 Windows 实机验收前，Release MUST 标记为 Prerelease 并明确说明 Unknown publisher、SmartScreen 和企业策略限制。

#### Scenario: CI 构建门
- **WHEN** Windows CI 构建发布候选
- **THEN** CI 验证锁定依赖、单元/集成测试、PE x64、产品版本、单文件产物、未签名状态、ZIP 内容和 SHA-256，同时保持 macOS 现有回归通过

#### Scenario: GitHub 预发布
- **WHEN** 创建 `v0.2.0-preview.1`
- **THEN** Release 为 Prerelease，包含 Windows x64 ZIP 与 SHA-256，并明确区分 CI 证据和仍待用户 Windows 实机验证的项目

#### Scenario: Windows 实机验收
- **WHEN** 用户在真实 Windows 11 x64、已登录的 Codex Desktop 环境运行预览版
- **THEN** 验收记录分别覆盖真实额度、Codex 启停、焦点、hover/拖动、SmartScreen、DPI、睡眠恢复、登录启动和进程清理；未执行项不得标记通过
