## 1. Windows 工程与共享契约

- [x] 1.1 创建 `windows/` 下的 .NET 10 WPF App、Core 与测试工程，固定 win-x64 self-contained single-file、trimming 关闭和 PerMonitorV2 manifest
- [x] 1.2 提取语言无关额度与 JSON-RPC fixtures，并为 C# 实现覆盖 300/10080 窗口、稀疏 patch、非法字段、有限数字和 1 MiB 帧上限
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
