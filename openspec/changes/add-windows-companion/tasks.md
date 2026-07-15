## 1. Windows 工程与共享契约

- [x] 1.1 创建 `windows/` 下的 .NET 10 WPF App、Core 与测试工程，固定 win-x64 self-contained single-file、trimming 关闭和 PerMonitorV2 manifest
- [x] 1.2 提取语言无关额度与 JSON-RPC fixtures，并为 C# 实现覆盖 300/10080 窗口、稀疏 patch、非法字段、有限数字和 1 MiB 帧上限
- [x] 1.3 增加单实例、版本身份、最小脱敏诊断和 Windows 产品图标资源

## 2. Codex 生命周期与协议

- [x] 2.1 实现官方 Codex MSIX package identity 检测与缺席时低开销生命周期监控
- [x] 2.2 实现 canonical helper locator、reparse point 拒绝、WinVerifyTrust、确定性候选优先级和有界 capability probe
- [x] 2.3 实现 JSONL stdio app-server 客户端、完整快照、稀疏更新、安全刷新、断线不可用与有界重连
- [x] 2.4 实现 Process 所有权、有界退出和 Codex 启停 session coordinator，覆盖快速启停和清理失败测试

## 3. Windows 悬浮气泡

- [x] 3.1 实现无激活、无任务栏、Topmost 透明 WPF 窗口及透明角 hit-test、单一 DragMove 拖动所有者和位置持久化
- [x] 3.2 实现 52×52 / 130×78 DIP 单一彩色气泡、固定几何色流、额度回退、语义色和紧凑展开排版
- [x] 3.3 实现 180ms 可中断展开/收起、内容交叉淡入淡出、10 DIP 空间迟滞和 Reduce Motion
- [ ] 3.4 实现 PerMonitorV2、工作区钳制、负坐标、多 DPI 与显示器拔插的纯布局测试
- [x] 3.5 提取无窗口依赖的 `OverlaySurface`，移除 5 DIP 内缩、黑色实底、独立描边与外发光，并按 macOS 参考统一 52×52 / 130×78 的字体、语义色、固定色场和两行排版
- [ ] 3.6 在 Windows 11 22621+ 实现并验证非 layered HWND、Desktop Acrylic 与动态 `SetWindowRgn`，材质不可用时仅使用不透明中性浅色降级

## 4. 托盘、偏好与启动项

- [x] 4.1 使用 WinForms NotifyIcon 实现显示/隐藏、登录时启动和退出菜单
- [x] 4.2 实现 HKCU Run 首次稳定路径注册、临时路径拒绝、opt-out 持久化和路径迁移更新
- [ ] 4.3 验证用户隐藏偏好、Codex 生命周期、托盘退出和登录启动不会互相覆盖

## 5. CI 与打包

- [x] 5.1 扩展 GitHub Actions 为独立 macOS 与 Windows job，并锁定第三方 Action 提交
- [x] 5.2 增加 Windows Release publish 和 ZIP 脚本，验证测试、PE x64、版本、single-file、未签名状态、归档内容及 SHA-256
- [x] 5.3 更新 README、CHANGELOG、Windows 安装/SmartScreen/升级/隐私说明和平台支持矩阵
- [x] 5.4 从干净提交在 Windows runner 生成候选并回下载复验资产
- [x] 5.5 由 Windows runner 输出固定相位的收起/展开 WPF PNG，验证尺寸、透明角、文字安全区与无独立外圈；报告明确该证据不覆盖 DWM 桌面合成
- [x] 5.6 以 `0.2.0-preview.2` 生成新的 Windows x64 ZIP、SHA-256 与产品版本，拒绝覆盖已公开的 preview.1 资产

## 6. 审查与预发布

- [x] 6.1 对 locator、进程所有权、注册表、诊断脱敏和未签名分发完成独立安全/架构复审
- [x] 6.2 保持 macOS Swift、Node、构建和签名回归通过，Windows Core/UI 状态测试全部通过
- [x] 6.3 使用 MrPPFruit 账号创建 `v0.2.0-preview.1` GitHub Prerelease，上传 Windows x64 ZIP 与 SHA-256 并验证线上资产
- [ ] 6.4 在用户真实 Windows 11 x64 上完成 Store Codex locator、真实额度、焦点、hover/拖动、SmartScreen、DPI、登录启动和残留进程验收
- [ ] 6.5 在真实 Windows 11 上完成 Acrylic 背景采样、圆形/圆角区域、浅色/深色/高频桌面背景、100%/125%/150%/200% DPI 与空闲动画 CPU 的视觉材质验收
- [x] 6.6 使用 MrPPFruit 账号创建 `v0.2.0-preview.2` Prerelease，并回下载校验新的 ZIP、SHA-256 与 UI 结构截图证据

## 7. Windows 实机反馈修复

- [x] 7.1 以 `Codex` / `ChatGPT` 固定发现提示和精确官方 PFN 识别统一桌面宿主，probe 与 locator 复用候选枚举并保持既有签名/路径 Gate
- [x] 7.2 将 Aurora 色场固定为覆盖最大展开矩形任意旋转角的尺寸，验证收起/展开多个相位均无左右无色底层
- [x] 7.3 增加官方宿主迁移、错误 PFN、不可用额度与多相位渲染回归，并记录 CI 与真实 Windows 证据边界
- [x] 7.4 以 MrPPFruit 账号创建 `v0.2.0-preview.3` Prerelease，回下载校验 Windows ZIP、SHA-256 与 UI 截图
- [x] 7.5 以 Windows Package API 获取跨磁盘安装根，并用包内签名基准、官方每用户运行副本逐字节一致性和跨 initialize lease 修复 Store helper 启动，覆盖拒绝分支与真实额度显示
- [x] 7.6 拒绝同一 client 并发重复启动，将 session 重试收窄到明确可恢复异常，并让发布脚本同时支持独立 restore 与 CI `-NoRestore` 路径
