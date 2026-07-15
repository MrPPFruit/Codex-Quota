# Windows 预览版分发说明

本分支生成的 Codex Quota `v0.1.0` Windows 包面向 Windows 11 x64。它由 GitHub Actions 的 Windows runner 从公开源码构建，采用 .NET 10 self-contained single-file WPF 发布，因此用户不需要另行安装 .NET Runtime。公开修复直接覆盖唯一 Prerelease `v0.1.0` 中对应的 Windows 资产，不新增发布页。

## 当前信任边界

本预览版尚未使用 Authenticode 商业代码签名证书。Windows SmartScreen 可能阻止首次运行，发布页提供的 SHA-256 只能确认下载文件与 GitHub Release 资产一致，不能证明开发者身份。只有从 `MrPPFruit/Codex-Quota` 官方 Release 下载并核对校验值后，才应选择“更多信息 → 仍要运行”。

程序不申请管理员权限、不安装 Windows 服务、不修改 ChatGPT/Codex，也不从 PATH、npm 或任意用户目录执行同名程序。`Codex` 与 `ChatGPT` 只作为低成本进程发现提示；程序必须进一步确认精确官方 Package Family Name `OpenAI.Codex_2p2nqsd0c76g0`，从运行进程取得 Package Full Name，并通过 Windows Package API 查询真实安装根，因此兼容安装到非系统盘的 Store 包。包内固定 `codex.exe` 必须通过 WinVerifyTrust，并作为当前版本的只读哈希基准。实际执行文件只允许来自官方桌面应用同步的 `%LOCALAPPDATA%\OpenAI\Codex\bin\<version>\codex.exe`；程序先持有拒绝写入和替换的只读 lease，再验证它与包内基准逐字节一致，并在该 lease 内完成能力探针与 app-server 初始化。缓存缺失、不一致、reparse point 或任何检查失败时均安全降级为不可用。

## 安装与升级

1. 将 ZIP 完整解压到固定目录，例如 `%LOCALAPPDATA%\Programs\Codex Quota`。
2. 核对 SHA-256 后运行 `CodexQuota.exe`。
3. 首次运行默认写入当前用户的 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，不需要管理员权限。
4. 可在托盘菜单关闭“登录 Windows 时启动”；该选择会持久化，后续启动不会擅自重新开启。
5. 升级前从托盘退出旧版，替换文件后重新运行一次，以更新登录项中的路径。

不要直接从 ZIP 内运行，也不要把程序放在临时目录。若移动了文件位置，应重新运行新位置中的程序。

开发者直接运行 `windows/scripts/package-release.ps1` 时，脚本会先为 `win-x64` 恢复依赖；CI 已在前置构建中完成恢复，因此显式传入 `-NoRestore`，避免重复联网。两条路径都会检查 `dotnet` 退出码，失败时不会继续生成看似有效的发布包。

## 首轮真实 Windows 验收

GitHub Actions 能验证编译、测试、PE x64、single-file、未签名状态、ZIP 内容与 SHA-256，但不能证明真实桌面行为。首轮 Windows 11 实机需验证：

- Microsoft Store ChatGPT/Codex 的 package identity 与 helper 路径；
- 真实 5 小时和周额度；
- 气泡不抢焦点、悬停展开、收缩和拖动；
- Desktop Acrylic 能采样气泡后方桌面，圆形与展开圆角没有矩形底、黑角或明显锯齿；
- 100%、不可用与周额度回退排版；
- 浅色、深色与高频壁纸背景；
- 100%、125%、150%、200% DPI 与屏幕边缘；
- Reduce Motion、动画期间 UI Automation 树与空闲色流 CPU；
- Codex 启停、托盘退出和 app-server 子进程无残留；
- SmartScreen 提示与登录启动开关。

Windows runner 生成的固定 PNG 只验证 WPF 内容尺寸、透明角、排版和无独立外圈，不能证明 DWM 桌面合成。完成上述实机验收前，Windows 资产保持 GitHub Prerelease，不宣称正式稳定版。
