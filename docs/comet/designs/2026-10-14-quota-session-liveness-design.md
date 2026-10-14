---
comet_change: quota-session-liveness
role: technical-design
canonical_spec: openspec
---

## 实现决策

- 唯一用户目标是普通 macOS 安装应用在 ChatGPT 已运行且额度接口可读时显示有效周额度。状态语义 owner 为 `AccessoryLifecycleCoordinator`；`SystemCodexPresenceMonitor` 只负责给它提供当前 presence，`AppServerClient` 只负责 app-server 协议与额度快照。
- 在三个现有边界加固定阶段 `Logger` 事件：presence 发布、session factory/locator、app-server 启动/initialize/额度读取/退出、生命周期 retry。错误只记录本地枚举类别，不写原始错误、CLI 路径/参数、JSON、账号或额度字段。
- 保留 KVO 和 wake/session 通知；每 30 秒从 `NSWorkspace.runningApplications` 重新获取一次本地快照，并将当前 `present=true` 重交给 coordinator。该低频检查能修复漏事件造成的 stale presence，不会重复启动仍活跃的 session，也不产生网络流量。
- 项目测试注入 bundle snapshot 和短间隔，模拟启动事件漏送后真实进程仍在；验证 monitor→coordinator→session→quota snapshot 的完整恢复链。
- 测试 seam 是 lifecycle 已有的 session factory/client mock 与客户端 transport mock；产品 seam 是系统安装路径 `/Applications/Codex Quota.app`、真实 `NSWorkspace` presence、真实 app-server 子进程和浮窗 accessibility/screenshot。

## 依赖与边界

- 复用系统 `OSLog`，无新依赖、服务、配置项或公开 API。
- 不改变现有 ChatGPT bundle ID、app-server 方法、quota normalization、浮窗组件或用户偏好；10080 分钟窗口可用且 300 分钟缺失时，周额度必须正常显示。
- 改动仅在 `codex/quota-session-liveness` 分支。更新前留存当前已安装二进制的可恢复副本或使用已验证构建产物作为回滚来源。

## 主要风险

- 诊断后重启可能让暂态故障消失；因此重启后的日志必须包含 presence、factory、连接和有效快照的完整顺序，并核对普通用户浮窗结果。
- macOS unified log 默认可能对任意值做隐私处理；固定阶段与枚举日志仍须实际查询验证。
- 只增加日志可能让后续故障更容易诊断却没有修复用户可见问题；验收只以真实浮窗的有效周额度和无需重启的恢复成立。

## 回滚与迁移

- 本地部署使用构建后签名校验的 app；失败时可从已保存的旧 app bundle 恢复。
- 不迁移偏好或用户数据。代码回滚通过 feature branch 回退。

## 非目标

- 不引入高频轮询、外部遥测、后台守护进程或 UI 状态/文案。

## Acceptance Design

- [QUOTA-01] Owner: `AccessoryLifecycleCoordinator`；Observable: ChatGPT 保持运行且 app-server 可读时，普通浮窗显示有效周额度，漏掉 presence 事件后至多等待一个 30 秒本地重检周期即可自动恢复；Counterexample: 独立 API probe 或 mock 测试成功，但普通浮窗仍显示“-- / 不可用”；Evidence: 项目内漏事件恢复测试、本机 unified log、安装 app 的 app-server 子进程和恢复后的浮窗截图。
