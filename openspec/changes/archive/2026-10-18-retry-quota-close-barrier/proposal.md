## Why

额度助手当前显示“不可用”时，独立的 Codex app-server 读取和新建 `AppServerClient` 均能成功；运行中的旧实例却每 30 秒只记录一次 `connection_started`，退出并重新启动后立即恢复。代码路径显示，旧 transport 清理失败会留下已失败的单次关闭 barrier，后续重连反复等待它，无法启动新子进程。首次清理失败的触发原因未被旧版本记录，因此本 change 修复已确认的卡死路径，并补上清理失败阶段日志。

## What Changes

- app-server transport 关闭失败时保留旧 transport，由现有有界重试继续清理；确认旧进程关闭前不启动替代 transport。
- 清理任务失败后恢复可重试的 session 状态，避免重复等待已失败的 closing task。
- 为 transport 清理结果增加仅含固定阶段和错误类别的脱敏日志，并增加连续失败后恢复的回归测试。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `accessory-session-lifecycle`: 明确 app-server transport 清理失败时保留旧 transport 并自动重试，成功关闭前不得创建替代 transport。

## Impact

- 影响 `Sources/CodexUsageCore/AppServerClient.swift`、`Tests/CodexUsageCoreTests/AppServerClientTests.swift` 和对应 OpenSpec requirement。
- 不改变额度来源、用户界面、账号认证、公开 API 或重试预算。

## Delivery Contract

- Parent outcome: `openspec/specs/accessory-session-lifecycle/spec.md#清理失败后会话仍可恢复`
- Parent Acceptance ID: `QUOTA-SESSION-RECOVERY-01`
- Acceptance ID: `QUOTA-SESSION-RECOVERY-02`
- Ordinary user entry: Codex 正在运行时打开已安装的 Codex Quota 菜单栏浮窗。
- Outcome: transport 清理连续失败后，助手保留旧 transport 并通过既有退避重试；旧进程确认退出后恢复读取额度，全程无需重启助手。
- Counterexample: 测试观察到新的 transport 已创建或一次 `reconnect()` 返回，但旧 transport 的清理仍失败或失去所有权；这不算恢复。
- Implementation owner: `AppServerClient` transport invalidation/reconnect lifecycle。
- Verification evidence: 待由 focused regression、Swift suite 和本机菜单栏真链验收补齐。
