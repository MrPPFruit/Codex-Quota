## Why

Codex Quota 会为每次初次读取启动新的 `codex app-server`。当前 Codex 版本在网络较慢或其附加服务超时时，首个额度响应可超过现有的 10 秒总预算；应用于是终止正常仍在返回的请求，并把两个额度窗口同时显示为不可用。

## What Changes

- 为首次建立 app-server 连接和读取额度提供独立、有限的冷启动预算。
- 保持已连接后的写入、刷新和故障处理仍使用原有较短的操作预算，避免慢请求无限占用后台进程。
- 增加回归测试：首个额度响应慢于常规操作预算、但在冷启动预算内时必须成功显示额度。

## Capabilities

### New Capabilities

- `cold-start-rate-limit-read`: 独立额度工具首次启动 app-server 时的有界读取时限和成功语义。

### Modified Capabilities

无（仓库当前没有已归档的 OpenSpec capability）。

## Impact

- 影响 `Sources/CodexUsageCore/AppServerClient.swift` 的首次连接时限边界。
- 影响 `Tests/CodexUsageCoreTests/AppServerClientTests.swift` 的时限回归覆盖。
- 不改变对外协议、认证方式、额度计算、UI 布局或发布版本号。
