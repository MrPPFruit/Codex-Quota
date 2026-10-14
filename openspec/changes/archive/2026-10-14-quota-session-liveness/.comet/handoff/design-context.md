# Comet Design Handoff

- Change: quota-session-liveness
- Phase: design
- Mode: compact
- Context hash: 8cc98e2875bdf5dbe2858b277bd2fcd1eac6d3b393a23f8a1c1cf69932a68928

Generated-by: comet-handoff.sh

OpenSpec remains the canonical capability spec. This handoff is a deterministic, source-traceable context pack, not an agent-authored summary.

## openspec/changes/quota-session-liveness/proposal.md

- Source: openspec/changes/quota-session-liveness/proposal.md
- Lines: 1-30
- SHA256: 67c43646b5acf912dc37526729822a9e58710f8c27ba546424dc992c7fd38017

```md
## Why

额度浮窗再次显示“不可用”时，ChatGPT 进程与独立额度读取均正常，但当前额度应用没有可观察的会话启动记录，无法区分 presence 通知遗漏、locator 失败或 session 生命周期停滞。需要让小程序能从当前运行状态恢复，并留下不含额度值或凭证的诊断证据。

## What Changes

- 让 ChatGPT presence 与 app-server 用量会话持续收敛到当前系统状态；短暂丢失生命周期事件或启动失败后，无需重启额度应用即可恢复。
- 为 presence、locator、app-server 初始化/额度读取/退出及重试增加脱敏结构化日志，以便现场确认具体失败边界。
- 保持现有浮窗交互和额度来源不变，不记录额度数值、账户标识或凭证。

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `accessory-session-lifecycle`: 增加 ChatGPT 仍在运行时，presence 与额度读取会话最终恢复一致且可诊断的要求。

## Impact

- 影响 `CodexPresenceMonitor`、`AccessoryLifecycleCoordinator`、app-server 会话启动链及相关测试。
- 不改变额度协议、账号认证、用户界面或公开 API；不增加依赖。

## Delivery Contract

- Parent outcome: `openspec/specs/accessory-session-lifecycle/spec.md#清理失败后会话仍可恢复`
- Parent acceptance: independent
- [QUOTA-01] Outcome: ChatGPT 正在运行且 app-server 可返回额度时，浮窗最终显示可用额度；presence 或 session 的短暂失败无需重启额度应用即可恢复。 Negative: 独立 API probe 或单元测试通过，但普通用户浮窗仍持续显示“-- / 不可用”。 Evidence: 当前安装的签名应用、presence 与 session 的真实运行记录，以及恢复后的浮窗截图。
```

## openspec/changes/quota-session-liveness/design.md

- Source: openspec/changes/quota-session-liveness/design.md
- Lines: 1-44
- SHA256: 309d091a2b4307d89f02ebf234f3bde94e34c4762323d86fbc3b56e6e20b1b0e

```md
## Context

当前现场中，`NSWorkspace` 能枚举到 `com.openai.codex`，locator 与真实 `AppServerClient` 独立探针都成功，但正在运行的额度应用没有稳定的 `app-server` 子进程。额度应用现有错误处理会把 factory/client 错误收敛为“不可用”，而进程没有记录 presence 回调、locator 结果、JSON-RPC 阶段或重试状态，所以触发点尚不能从过去的运行记录还原。

本 change 的唯一用户结果是恢复普通安装应用的额度显示；首步加入脱敏诊断并在真实安装应用上复现，随后按得到的失败阶段做最小修复。它独立处理 presence 与 session 启动/连接阶段，不依赖已交付的 cleanup-failure retry 变更。

## Goals / Non-Goals

**Goals:**

- [QUOTA-01] ChatGPT 已运行时，额度应用最终建立有效额度会话并更新浮窗。
- 瞬时 presence 或 app-server 会话失败能在额度应用不重启的情况下恢复。
- 能从本机系统日志辨认失败发生在 presence、locator、进程启动、initialize、额度读取或重连阶段。
- 回归验证必须从签名应用和真实 app-server 链路确认用户可见额度，而非只验证 mock 或独立 probe。

**Non-Goals:**

- 改变浮窗视觉、文案、额度来源、认证方式或 ChatGPT 检测目标 bundle ID。
- 引入后台服务、外部日志平台、新依赖或高频轮询策略；只有诊断证据证明需要时才考虑扩展检测机制。
- 暴露账户信息、额度数值、重置时间、可执行文件路径或凭证到诊断日志。

## Decisions

- 先在现有 presence、session factory、app-server 握手/读取与 retry 边界加入 OSLog 事件，再从当前不可用运行态采集一轮启动证据。这样可以区分目前仍并存的几种原因，不用猜测性地重写 presence 检测。
- 日志只记录阶段、布尔 presence、重试序号和已定义错误类别；不记录原始 JSON、额度内容、账户标识、CLI 参数或任意错误文本。日志由 macOS 统一日志本地保存，不发送到外部服务。
- 根据现场确认的失败边界，修改已有生命周期协调链并为该边界增加回归测试。若证据表明是漏掉 presence 状态，则以当前 `NSWorkspace.runningApplications` 做重新收敛；若是 session 启动/协议阶段，则只修复对应状态转换。
- 保持普通 app-server 协议实现与 UI 组件不变；已有真实协议 probe 证明它能从当前 ChatGPT CLI 读取到 weekly-only 有效窗口，weekly 剩余值正确归一为 94%。

## Risks / Trade-offs

- [Risk] 现场触发具有间歇性，诊断重启后可能恢复而未复现。→ 部署带日志构建后观察启动和至少一个重试周期；只在实际失败边界可见且真实浮窗可用后判定验收。
- [Risk] 日志可能意外包含敏感数据。→ 使用固定事件名称和枚举错误类别，不序列化 app-server payload 或自由文本错误。
- [Risk] 系统日志会滚动覆盖较早事件。→ 验证记录包含同一运行批次内的 presence、session、retry 顺序，并立即保存到本次验证报告。

## Migration Plan

1. 在 `codex/quota-session-liveness` 上构建带脱敏阶段日志的 macOS app，更新本机 `/Applications/Codex Quota.app` 并观察当前故障链。
2. 依据日志实现最小根因修复和真实回归检查；构建并替换本机 app，确认额度浮窗恢复。
3. 若修复引入回归，回滚本 change 分支即可；用户数据和偏好不迁移。

## Open Questions

- 当前无法从旧版系统日志确定故障是 presence 状态未进入 coordinator，还是 coordinator/session factory 的重试停滞；第一轮带日志启动将关闭这一未知项。
- 当前 app-server 只返回 10080 分钟周窗口，五小时窗口缺失属有效数据形态；验收要求周额度显示，不要求伪造五小时额度。
```

## openspec/changes/quota-session-liveness/tasks.md

- Source: openspec/changes/quota-session-liveness/tasks.md
- Lines: 1-15
- SHA256: 63f9aec7f8c655a368f8b9860cabadfe0c200161a32c9c2bf186e30ad344c3e5

```md
## 1. Diagnose the current failure — [QUOTA-01]

- [ ] 1.1 Add fixed-stage, privacy-safe logging across presence, session factory, app-server startup/read/termination, and retry boundaries.
- [ ] 1.2 Build and relaunch the signed app; use the current unavailable state to identify the first failing boundary from unified logs.

## 2. Repair the confirmed lifecycle gap — [QUOTA-01]

- [ ] 2.1 Implement the smallest repair for the observed failing boundary without changing the quota UI or source.
- [ ] 2.2 Add a project test that fails on the current implementation and passes after the repair, covering recovery without restarting the accessory.

## 3. Verify the user result — [QUOTA-01]

- [ ] 3.1 Run relevant Swift tests, signed app build, OpenSpec strict validation, and local security/diff checks.
- [ ] 3.2 Validate the normal installed app with live ChatGPT presence and app-server data; save sanitized logs and a screenshot proving weekly quota appears while a missing five-hour window remains unavailable.
- [ ] 3.3 Record the counterexample check and real-chain evidence, then integrate the branch and complete the GitHub workflow.
```

## openspec/changes/quota-session-liveness/specs/accessory-session-lifecycle/spec.md

- Source: openspec/changes/quota-session-liveness/specs/accessory-session-lifecycle/spec.md
- Lines: 1-26
- SHA256: 6c647af28264ce94719466c340697dd329b60c694faff5505fae8bf314d74ade

```md
## ADDED Requirements

<!-- comet-acceptance: QUOTA-01 -->
### Requirement: ChatGPT presence 与额度会话持续收敛

额度小程序 MUST 在启动时以及收到系统 presence 变化后，依据当前 ChatGPT 运行状态协调额度 session。ChatGPT 保持运行且 app-server 恢复可读时，小程序 MUST 自动恢复可用额度显示，无需重启额度小程序。对于无法建立会话的状态，小程序 MUST 记录可辨认失败阶段的脱敏诊断；诊断 MUST NOT 包含额度值、账户标识、认证信息或原始 app-server 数据。

#### Scenario: ChatGPT 已运行时启动额度小程序

- **WHEN** 用户启动额度小程序，且 ChatGPT 已运行、app-server 能返回有效周额度
- **THEN** 小程序 MUST 检测到当前 presence、建立用量 session，并在浮窗显示有效周额度

#### Scenario: 用量 session 临时启动失败后恢复

- **WHEN** ChatGPT 保持运行，额度小程序的 locator、子进程启动或 app-server 读取暂时失败，之后同一链路恢复可用
- **THEN** 小程序 MUST 在不重启自身的情况下按有界重试恢复额度显示，并留下能定位失败阶段的脱敏日志

#### Scenario: 只有周额度窗口可用

- **WHEN** app-server 返回有效的 10080 分钟额度窗口但没有 300 分钟窗口
- **THEN** 小程序 MUST 显示有效周额度，且 MUST 将缺失的五小时窗口保持为不可用

#### Scenario: 诊断记录受到隐私约束

- **WHEN** locator 或 app-server 连接阶段失败
- **THEN** 诊断 MUST 仅记录固定阶段、错误类别和重试状态，且 MUST NOT 记录凭证、原始响应、账户标识或额度数值
```
