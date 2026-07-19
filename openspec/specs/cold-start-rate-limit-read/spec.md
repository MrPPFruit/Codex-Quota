# cold-start-rate-limit-read Specification

## Purpose
TBD - created by archiving change extend-rate-limit-read-budget. Update Purpose after archive.
## Requirements
### Requirement: 冷启动额度读取使用独立的有限预算
系统在启动新的 app-server 后，MUST 为进程启动、初始化握手和首个 `account/rateLimits/read` 响应使用独立的有限冷启动预算。该预算 MUST 长于常规刷新操作预算，且默认值 MUST 为 30 秒。

#### Scenario: 首个额度响应慢于常规预算但位于冷启动预算内
- **WHEN** 首个 `account/rateLimits/read` 响应晚于常规操作预算、但早于冷启动预算到达
- **THEN** 系统 MUST 接受有效响应并发布其额度快照，而不是关闭 transport 或发布全局不可用

#### Scenario: 冷启动预算耗尽
- **WHEN** 首个完整读取未在冷启动预算内完成
- **THEN** 系统 MUST 关闭当前 transport 并发布不可用快照

### Requirement: 已连接刷新保持短时限
系统在已连接后触发的完整刷新 MUST 保持使用常规刷新预算，且 MUST NOT 因延长冷启动预算而无限期等待。

#### Scenario: 已连接刷新超时
- **WHEN** 已连接后的完整刷新未在常规刷新预算内完成
- **THEN** 系统 MUST 使当前连接失效并发布不可用快照
