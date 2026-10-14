## ADDED Requirements

<!-- comet-acceptance: QUOTA-01 -->
### Requirement: ChatGPT presence 与额度会话持续收敛

额度小程序 MUST 在启动时、收到系统 presence 变化后，以及低频重新读取当前系统进程时，依据当前 ChatGPT 运行状态协调额度 session。ChatGPT 保持运行且 app-server 可读时，小程序 MUST 自动恢复可用额度显示，无需重启额度小程序。对于无法建立会话的状态，小程序 MUST 记录可辨认失败阶段的脱敏诊断；诊断 MUST NOT 包含额度值、账户标识、认证信息或原始 app-server 数据。

#### Scenario: ChatGPT 已运行时启动额度小程序

- **WHEN** 用户启动额度小程序，且 ChatGPT 已运行、app-server 能返回有效周额度
- **THEN** 小程序 MUST 检测到当前 presence、建立用量 session，并在浮窗显示有效周额度

#### Scenario: 用量 session 临时启动失败后恢复

- **WHEN** ChatGPT 保持运行，额度小程序的 locator、子进程启动或 app-server 读取暂时失败，之后同一链路恢复可用
- **THEN** 小程序 MUST 在不重启自身的情况下按有界重试恢复额度显示，并留下能定位失败阶段的脱敏日志

#### Scenario: 系统漏掉 ChatGPT 启动事件

- **WHEN** ChatGPT 保持运行，但额度小程序没有收到对应的 presence 变化通知且当前没有额度 session
- **THEN** 小程序 MUST 在下一次低频系统进程重检时识别 ChatGPT 仍在运行，触发 session 协调并恢复额度显示

#### Scenario: 只有周额度窗口可用

- **WHEN** app-server 返回有效的 10080 分钟额度窗口但没有 300 分钟窗口
- **THEN** 小程序 MUST 显示有效周额度，且 MUST 将缺失的五小时窗口保持为不可用

#### Scenario: 诊断记录受到隐私约束

- **WHEN** locator 或 app-server 连接阶段失败
- **THEN** 诊断 MUST 仅记录固定阶段、错误类别和重试状态，且 MUST NOT 记录凭证、原始响应、账户标识或额度数值
