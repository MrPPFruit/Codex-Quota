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
- 引入后台服务、外部日志平台、新依赖或网络轮询。
- 暴露账户信息、额度数值、重置时间、可执行文件路径或凭证到诊断日志。

## Decisions

- 在现有 presence、session factory、app-server 握手/读取与 retry 边界加入 OSLog 事件；现场确认直接 app-server 可读、ChatGPT 仍运行、旧额度应用无子进程，而新启动完整成功。旧进程没有历史日志，原始事件无法追溯。
- `SystemCodexPresenceMonitor` 继续使用 KVO 和 wake/session 通知获取即时变化，并每 30 秒重新读取本地 `NSWorkspace.runningApplications`。重复的 present=true 重新交给 coordinator，确保漏掉一次系统通知后仍能创建缺失 session；该重检不发网络请求。
- 日志只记录阶段、布尔 presence、重试序号和已定义错误类别；不记录原始 JSON、额度内容、账户标识、CLI 参数或任意错误文本。日志由 macOS 统一日志本地保存，不发送到外部服务。
- 用可注入的 presence snapshot 和短测试周期模拟“ChatGPT 启动事件未送达但进程仍存在”，验证重检会触发已有 coordinator 并发布真实窗口快照。
- 保持普通 app-server 协议实现与 UI 组件不变；已有真实协议 probe 证明它能从当前 ChatGPT CLI 读取到 weekly-only 有效窗口，周额度按接口返回值正确归一。

## Risks / Trade-offs

- [Risk] 现场触发具有间歇性，诊断重启后可能恢复而未复现。→ 部署带日志构建后观察启动和至少一个重试周期；只在实际失败边界可见且真实浮窗可用后判定验收。
- [Risk] 日志可能意外包含敏感数据。→ 使用固定事件名称和枚举错误类别，不序列化 app-server payload 或自由文本错误。
- [Risk] 系统日志会滚动覆盖较早事件。→ 验证记录包含同一运行批次内的 presence、session、retry 顺序，并立即保存到本次验证报告。

## Migration Plan

1. 在 `codex/quota-session-liveness` 上构建带脱敏阶段日志的 macOS app，更新本机 `/Applications/Codex Quota.app` 并观察当前故障链。
2. 依据日志实现最小根因修复和真实回归检查；构建并替换本机 app，确认额度浮窗恢复。
3. 若修复引入回归，回滚本 change 分支即可；用户数据和偏好不迁移。

## Open Questions

- 旧进程无日志且已退出，无法判定历史故障究竟是漏掉 presence 事件还是会话协调状态停滞；本次修复覆盖漏事件导致的永久 stale presence，并保留阶段日志供未来现场定位。
- 当前 app-server 只返回 10080 分钟周窗口，五小时窗口缺失属有效数据形态；验收要求周额度显示，不要求伪造五小时额度。
