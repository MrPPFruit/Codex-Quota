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
