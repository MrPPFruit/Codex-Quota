## 验证结论

通过。首次 app-server 读取已从常规操作 budget 中隔离：冷启动完整读取最多 30 秒，连接成功后的写入与刷新仍为 10 秒。

## 已执行验证

- `swift test --filter AppServerClientTests`：28 项通过，其中包含新增的慢首次额度响应回归。
- `swift test`：139 项通过。
- `npm test`：27 项通过。
- `npm run build:accessory`：Release app bundle 构建、ad-hoc 签名和严格签名校验通过。
- `scripts/run-accessory-smoke.sh`：受控启动、辅助应用激活策略、可见悬浮窗、菜单项、子进程所有权与清理均通过；无残留自有进程。
- `openspec validate extend-rate-limit-read-budget --strict`：通过。
- `git diff --check`：通过；对源码改动进行疑似密钥扫描，未发现新增结果。

## 规格核对

- 首个额度响应在常规 100ms 已过、但冷启动 500ms 内到达时，新增测试确认连接保持有效并发布完整快照。
- 原有超时测试显式使用相同的冷启动/常规短 budget，确认预算耗尽仍关闭 transport 并发布不可用。
- `connect()` 使用 `initialReadDeadline` 驱动进程启动和完整握手/read 的总时限；`refresh()` 和写入继续使用 `deadline`。

## 实机协议证据与限制

当前 Mac 的 ChatGPT 内置 `codex app-server` 曾在约 16 至 23 秒后返回有效额度，因此旧的 10 秒全流程截止会错误终止可成功的读取。新 30 秒预算覆盖该已观测范围，但仍是有限等待；若官方 Codex 未来长期超过 30 秒，应用将继续安全降级为不可用并重连。

本次未修改 app-server 参数、认证路径、额度字段解析、UI 布局、应用版本号或 GitHub Release。新 bundle 已在隔离工作区构建和烟测；是否覆盖安装到 `/Applications` 及发布到 GitHub 需按后续交付指令执行。
