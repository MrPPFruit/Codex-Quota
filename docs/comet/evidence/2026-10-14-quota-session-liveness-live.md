# 额度显示恢复：现场证据

## 签名应用与真实数据链

- 安装位置：`/Applications/Codex Quota.app`。
- `codesign --verify --deep --strict --verbose=2`：签名有效；安装包与本分支构建产物主程序 SHA-256 相同：`8e58a2e0759ec84cabef9a7f9a608e755b6a2f156c6e53804fd3d5fe110dbfb62c`。
- 现场运行主程序及其 app-server 子进程；两者在取证时仍运行。
- 真实 app-server 成功路径：`19:39:22.173 presence_changed running=true` → `19:39:22.430 locator_succeeded / session_start_requested / session_running` → `19:39:22.557 initialize_succeeded` → `19:39:23.489 initial_rate_limit_read_succeeded`。
- 约 30 秒与 60 秒重检时，协调器分别在 `19:39:53.568`、`19:40:25.450` 再收到 `running=true`，状态保持 `phase=running`；这是安装应用运行中的周期性本地 presence 重检。
- 对当前 ChatGPT app-server 的独立只读 JSON-RPC 探测仅返回 10080 分钟周窗口，没有 300 分钟五小时窗口。额度数值仅用于本机 CUA 现场验证，没有写入仓库证据。应用没有用默认值伪造缺失窗口。

## 用户可见状态

- Codex 内置 CUA 对 `/Applications/Codex Quota.app` 的可访问状态报告周额度“充足”；同一轮 CUA 截图已在任务对话中显示，画面为绿色周额度图标。具体额度数值不保存在仓库。
- 应用现有“运行 ChatGPT 时显示额度气泡”偏好为开启，smoke 结果也确认浮窗 window 可见；本次 CUA 的应用绑定截图接口只捕获状态项图标，没有把独立浮窗 PNG 导出到仓库，因此报告引用本轮对话中的截图证据，不伪称存在本地截图文件。

## 诊断边界

- 旧版本退出前没有上述阶段日志，无法从旧进程日志证明最初这次故障具体漏了哪条系统事件。
- 已被代码和真实重检记录证明的缺陷是：presence 监听只有 KVO/系统通知，没有周期性重读当前进程；若启动事件遗漏且没有后续事件，session 可一直缺席。30 秒本地重检与回归测试修复并覆盖了这条可复现路径。
