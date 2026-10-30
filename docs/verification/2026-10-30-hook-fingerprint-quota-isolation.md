# 钩子重复审查：诊断与本机修复

日期：2026-10-30，Asia/Shanghai。

## 用户结果与验收

AC-HOOK-01：普通聊天批准 Ponytail 钩子后，在插件可执行内容不变时，额度辅助进程刷新或重连不再使授权失效；正常聊天的钩子与审查继续开启。

反例：独立后端一次返回 trusted，但聊天又出现三个待批准，不能作为完成证据。

## 故障与根因

用户批准已写入配置，但共享插件整体指纹变化，使后续读取返回 modified。钩子命令声明哈希不变。

确认的写入者包括 Codex Quota 的辅助 app-server：14:08:17 启动的 PID 9772，父进程 PID 13431 为 /Applications/Codex Quota.app/Contents/MacOS/CodexUsageAccessory。辅助后端只收到初始化和 account/rateLimits/read 请求，却在初始化过程中刷新了共享插件缓存。

用 Quota 相同身份复现后，共享插件目录变化仅涉及 .git/index、.git/logs 下的克隆/检出日志和 .git/objects/pack 文件。排除 .git 后，完整插件源内容指纹始终是：

`sha256:4907f48cb80a41873586852a0d4936b879111816d97ccc826e28a31f2e6b61be`

按 Codex 源码实现的完整指纹算法，与运行中的 hooks/list 返回逐字一致，证明 .git 元数据确实被纳入当前版本的插件内容指纹。此前诊断中新启动的完整后端也复现了相同副作用，不能把那些变化全归因于后台 Quota。

源码参考：

- https://github.com/openai/codex/blob/main/codex-rs/hooks/src/engine/plugin_fingerprint.rs
- https://github.com/openai/codex/blob/main/codex-rs/core-plugins/src/store.rs

## 最小修复

工作树：/Users/ppg/Documents/CloudCodeWorkSpace/Tools_ShowCodexLife_Addons/.worktrees/public-codex-quota。

修改 Sources/CodexUsageCore/AppServerClient.swift 的 startTransport：仅在 Quota 自己的额度辅助进程添加 `--disable plugins`。额度查询不需要插件发现、安装或执行，因此不应刷新正常聊天共享的插件缓存。没有修改 ~/.codex/config.toml、聊天钩子开关、审查逻辑或授权哈希；没有过滤真实插件源文件，也没有自动接受审查。

Tests/CodexUsageCoreTests/AppServerClientTests.swift 中既有 handshakeOrder 验证同时约束启动参数，避免恢复成会加载插件的完整辅助后端。

注意：这修复了 Quota 的职责越界，不是对安装版 Codex 指纹算法的补丁。安装版 Codex 仍会计入 .git；其他完整后端若重新克隆该插件，仍可能触发同类审查。未热改或替换 OpenAI 的签名应用。

## 验证证据

- 精确针对性验证：`swift test --filter AppServerClientTests.handshakeOrder`，1 项通过。
- `swift build -c release` 通过；链接阶段存在已有模块缓存警告，不影响退出状态。
- 与真实账户连接的最小进程验证：额度读取成功，25 秒观察内共享插件目录无文件内容变化。
- 本机已替换 /Applications/Codex Quota.app；沿用原应用的 ad-hoc 签名方式，codesign --verify --deep --strict 通过；安装后二进制与签名后的暂存二进制 SHA-256 相同。
- 实际 Quota 辅助进程参数已包含 `app-server --stdio --disable plugins`。14:25:00 日志确认 initial_rate_limit_read_succeeded；菜单栏实际显示“本周额度，剩余96%，充足”。
- 启动初期遇到额度请求超时和既有 cleanup_failure，应用自行重连后恢复，未额外修改该问题。
- 用户在修复后重新点击“全部允许”，明确反馈“已允许，待批准提示消失”。
- 随后检查三个钩子均仍启用；授权内容哈希与当前完整目录指纹一致：`sha256:e3fee87cf04e85a9b333534423c1a7785fc9a92325b342a457424f3a88be62ce`。

## 整合状态与限制

修复分支：codex/quota-plugin-cache-isolation，从既有 f77fd32 建立。只本地提交，不推送、不创建 PR、不合并 main。本机应用已安装；仓库对 main 的整合为 UNINTEGRATED。

尚未执行全量回归或长期监控。Codex 自身界面禁止自动化控制，聊天提示消失由用户现场确认。

旧 Quota 应用保留在本次 work/hook-diagnosis/backup，可恢复。未保存或复制认证信息。
