# macOS 正式分发说明

源码公开不等于二进制可直接分发。普通用户双击下载的应用时，macOS Gatekeeper 会校验开发者身份与 Apple 公证状态。

## 当前状态

- 本地构建：ad-hoc 签名。
- Developer ID Application 证书：未配置。
- Apple 公证与 stapling：未执行。
- GitHub Release：唯一的统一预览 Release `v0.1.0` 提供明确标注的 arm64 未公证 ZIP、Windows 11 x64 ZIP 和各自 SHA-256；它不是 Developer ID 正式发行包，也不会标记为 Latest。

## 未公证预览包

macOS 会阻止首次打开。确认下载来源和 SHA-256 后，可先尝试打开应用，再前往“系统设置 → 隐私与安全性”，在安全性区域选择“仍要打开”。系统会把这次选择保存为该应用的例外。

这种例外不证明开发者身份，也不证明应用经过 Apple 恶意软件扫描。不要关闭 Gatekeeper，不要建议用户全局移除下载隔离属性。

受管理设备可能禁止手动放行。预览版升级时需要手动替换应用，Gatekeeper 例外和登录项授权也可能需要重新确认。SHA-256 仅用于核对 Release 下载内容，不能替代 Developer ID 签名。

## 正式发布的最小链路

1. 加入 Apple Developer Program，并创建 Developer ID Application 证书。
2. 使用稳定的 bundle identifier 和版本号构建 Release。
3. 启用 Hardened Runtime，以 Developer ID 对应用签名并加入可信时间戳。
4. 将应用打包为 ZIP 或 DMG，使用 `notarytool` 提交 Apple 公证。
5. 对可 stapling 的产物附加公证票据，并用 `codesign`、`spctl` 和干净 Mac 复核。
6. 只把通过上述验证的产物上传到 GitHub Release。

Mac App Store 不是当前推荐路线：现有实现需要定位并启动官方 Codex 的 `app-server`，应先单独评估 App Sandbox 对该链路的影响。
