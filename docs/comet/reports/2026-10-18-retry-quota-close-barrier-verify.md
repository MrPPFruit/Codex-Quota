# 验证报告：额度 transport 清理失败后恢复

## 结果

已验证 transport 连续清理失败后，同一 `AppServerClient` 保留旧 transport 并继续尝试清理；旧 transport 关闭成功前不会启动替代 transport，随后能完成新的 rate-limit 握手。修复版已安装到普通应用路径，菜单栏通过正常入口读到有效周额度。

## Acceptance

- [PASS] QUOTA-SESSION-RECOVERY-01 — Evidence: 已归档父验收报告 `docs/comet/reports/2026-10-14-retry-lifecycle-after-cleanup-failure-verify.md` 与本次安装后的普通菜单栏实机观察 `docs/comet/evidence/2026-10-18-retry-quota-close-barrier-live.md`。
- [PASS] QUOTA-SESSION-RECOVERY-02 — Evidence: `Tests/CodexUsageCoreTests/AppServerClientTests.swift` 中 `transportCleanupFailuresCanRetryBeforeReplacement` 验证连续失败、旧 transport 关闭前禁止替代启动及后续成功读取；普通安装入口实机结果见 `docs/comet/evidence/2026-10-18-retry-quota-close-barrier-live.md`。

## 验证命令

- `swift test --filter transportCleanupFailuresCanRetryBeforeReplacement`：1 项通过。
- `swift test`：142 项通过；本次 change 之前已完成全量运行。
- `npm test`：27 项通过；本次 change 之前已完成全量运行。
- `npm run verify:accessory`：release build 与 accessory present/absent smoke 通过；本次 change 之前已完成。
- `openspec validate retry-quota-close-barrier --strict`：通过；`git diff --check`：通过。
- 安装验证：`/Applications/Codex Quota.app` 的 executable SHA-256 与 release build 一致，bundle ID 为 `com.ppfruit.codex-quota`；进程启动后可访问菜单栏状态，并运行 app-server 子进程。

## Counterexample 检查

- “测试通过或 retry 返回”不足以证明恢复：回归测试明确断言旧 transport 的关闭仍失败时替代 transport 启动数为零；第三次关闭成功后才启动替代 transport，并完成握手读取。
- “构建通过或新进程启动”不足以证明用户结果：普通安装路径的 CUA 辅助功能状态及截图确认菜单栏展示有效周额度；证据见上述 live evidence 文件。

## 风险与限制

- 现场 OSLog 在正常成功链路中没有产生 lifecycle 事件，因此无法从本次安装运行证明清理失败日志的真实触发；固定阶段/错误类别的日志实现由代码审查与回归测试覆盖。故障分支的行为证据来自同一生产客户端的注入测试，不是生产 app 的故障注入。
- 本地 release 包为 ad-hoc 签名。本次验收覆盖本机安装与真实菜单栏入口，不覆盖公证、分发或其他 Mac 环境。
- 构建仍有 `AccessoryApp.swift` 既有 weak-capture 警告；与本 change 无关。

## Git 集成

- 实现提交：`88eaae4`，分支 `codex/retry-failed-quota-cleanup`。
- 目标分支：`main`；远端 PR：[#12](https://github.com/MrPPFruit/Codex-Quota/pull/12)。
- 项目既有集成方式为 GitHub merge commit；该 PR 的 macOS 与 Windows 检查在实现提交上均通过，最终集成提交由 GitHub 合并时生成。
- merge commit SHA 将在 GitHub PR 合并后从远端读取并在交付记录中报告；本报告不把尚未生成的提交哈希写成已完成事实。
