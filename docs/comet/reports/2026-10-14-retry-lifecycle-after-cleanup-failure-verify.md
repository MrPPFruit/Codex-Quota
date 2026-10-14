# 验证报告：cleanup 失败后的生命周期恢复

## 结论

修复后的额度小程序无需重启 ChatGPT 即可恢复读取。清理失败时会保留旧 session 并按退避重试；旧 session 关闭成功之前不会创建替代 session。代码缺陷和回归路径已验证；本次现场故障的具体触发仍无法从旧日志确认。

## Acceptance

- [PASS] QUOTA-SESSION-RECOVERY-01 — Evidence: `Sources/CodexUsageAccessory/AccessoryLifecycleCoordinator.swift` 与 `Tests/CodexUsageAccessoryTests/LifecycleTests.swift` 验证清理失败后重试、旧 session 关闭前禁止替代 session；更新后的 `/Applications/Codex Quota.app` 连续运行 30 秒，子进程 `app-server --stdio` 仍在，浮窗读取本周剩余 96%。

## 验证证据

- `swift test --filter 'cleanupFailureRetriesBeforeReplacementSession|repeatedCleanupFailureNeverCreatesReplacementSession'`：2 项通过。
- `swift test --quiet`：退出码 0；Core 14 项、跨 Core/UI 55 项、Accessory 71 项通过。
- `npm test`：27 项通过。
- `npm run build:accessory`：成功；构建包通过 `codesign --verify --deep --strict`。
- `openspec validate --all --strict --no-interactive`：4 项通过。
- `git diff --check`：通过。
- 实机更新后，额度浮窗显示“本周额度，剩余 96%，充足”；该值与先前独立只读读取到的 4% 已用相符。ChatGPT 主程序未重启。

## Counterexample 检查

持续清理失败时，测试确认 session factory 仍只创建 1 个 session，协调器留在 `degraded`/`stopping`，退出清理也明确失败；因此“替代 session 已创建”或“界面曾显示数值”都没有被当成恢复成功。

## 风险与限制

- 故障发生前没有 lifecycle 错误记录；因此不能将那次具体不可用状态确定归因于清理失败。已修复的是代码中可重复验证的 degraded 永久停摆缺陷。
- Swift 构建仍报告 `AccessoryApp.swift:136` 的既有隐式强捕获警告；本次没有改动该处。
- 当前变更不改变 macOS presence 检测策略；若之后的证据表明 `NSWorkspace` 丢失了 presence 通知，应另行处理该触发条件。
