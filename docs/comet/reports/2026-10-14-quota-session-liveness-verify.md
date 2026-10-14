# 验证报告：额度显示的会话存活恢复

## 结论

已修复 ChatGPT 进程启动事件遗漏时额度会话可能永久缺席的问题。额度应用仍运行时，每 30 秒会重新读取本地 `NSWorkspace.runningApplications`；检测到 ChatGPT 存在后会再次通知既有生命周期协调器，自动建立 app-server session。真实安装应用现已显示周额度，无需重启 ChatGPT；具体额度数值不写入仓库。

- [PASS] QUOTA-01 — Evidence: [现场证据](../evidence/2026-10-14-quota-session-liveness-live.md)、`Sources/CodexUsageAccessory/CodexPresenceMonitor.swift`、`Tests/CodexUsageAccessoryTests/LifecycleTests.swift` 及本轮 CUA 截图；真实 app-server 只返回周窗口，缺失五小时窗口保持不可用。

## 验证

- `swift test --quiet`：141 项通过（Core 14、跨 Core/UI 55、Accessory 72）。
- `swift test --filter periodicPresenceReconciliationRecoversMissedChatGPTLaunchEvent`：定向反例通过；模拟启动事件遗漏、进程仍在，session 和周额度快照在不重启协调器的情况下恢复。
- `npm test`：27 项通过。
- `npm run verify:accessory`：签名生产构建与 present/absent 两种 accessory smoke 均通过。
- `openspec validate quota-session-liveness --strict --json`：通过。
- `codesign --verify --deep --strict --verbose=2 /Applications/Codex Quota.app`：通过；当前安装主程序与本分支构建产物 SHA-256 一致。
- `git diff --check`：通过。新增 OSLog 只使用固定阶段、布尔 presence 与固定错误类别，不记录额度、账户标识、路径、原始响应或凭证。

## Counterexample 检查

“独立 app-server 探测成功”不能单独证明产品可用；回归测试要求普通生命周期协调器在没有 ChatGPT 启动通知的条件下创建 session、发布额度快照。现场又确认签名安装应用启动了真实 app-server、完成 initialize/read，并由 CUA 看到了可用周额度，所以结论依据覆盖了真实用户链。

## 风险与限制

- 初次不可用时的旧进程无阶段日志，历史触发点仍无法确定；本次修复针对证据充分且可复现的事件遗漏后永久停摆缺陷。
- 真实接口没有五小时窗口，报告不推断其原因，也不伪造数值；只确认周窗口正常显示。
- CUA 截图证明真实安装应用的周额度状态项可见；应用绑定的截图结果没有包含独立浮窗 PNG，因此浮窗状态由当前“显示额度气泡”偏好及 accessory smoke 的窗口可见性共同佐证。
