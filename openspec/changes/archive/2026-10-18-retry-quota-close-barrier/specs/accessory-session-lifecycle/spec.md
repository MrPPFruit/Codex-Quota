## MODIFIED Requirements

### Requirement: 清理失败后会话仍可恢复
额度小程序 MUST 在 session 或其 app-server transport 关闭失败时继续持有旧 session/transport，保持额度状态为不可用，并按有界退避重试关闭。只有旧 session 和 transport 均确认关闭成功后，系统 MUST 才能创建或启动替代 session/transport。系统 MUST 自动继续 reconcile，无需用户重启额度小程序。

#### Scenario: ChatGPT 运行时的一次性清理失败恢复
- **WHEN** 当前 session 关闭失败一次，且 ChatGPT 仍在运行或随后重新运行
- **THEN** 额度小程序 MUST 重试关闭；只有关闭成功后才创建替代 session 并恢复额度更新

#### Scenario: 清理持续失败
- **WHEN** ChatGPT 运行期间 session 关闭持续失败
- **THEN** 额度状态 MUST 保持不可用，原 session MUST 继续由小程序持有，重试 MUST 使用有界退避，且 MUST NOT 创建替代 session

#### Scenario: 用户在清理重试期间退出
- **WHEN** 用户在清理重试等待期间退出额度小程序
- **THEN** 小程序 MUST 取消并等待后台 reconcile，然后串行执行最后一次 session 关闭尝试

#### Scenario: app-server transport 清理连续失败后恢复
- **WHEN** app-server transport 关闭连续失败，随后旧 transport 成功关闭，且 ChatGPT 仍在运行
- **THEN** 小程序 MUST 保留旧 transport 并按有界退避重试关闭；确认旧 transport 关闭前 MUST NOT 启动替代 transport；关闭成功后 MUST 在不重启额度小程序的情况下恢复额度读取，并记录脱敏的清理阶段和错误类别
