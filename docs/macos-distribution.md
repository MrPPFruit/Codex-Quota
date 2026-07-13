# macOS 正式分发说明

源码公开不等于二进制可直接分发。普通用户双击下载的应用时，macOS Gatekeeper 会校验开发者身份与 Apple 公证状态。

## 当前状态

- 本地构建：ad-hoc 签名。
- Developer ID Application 证书：未配置。
- Apple 公证与 stapling：未执行。
- GitHub Release：只发布源码，不附带 `.app`、ZIP 或 DMG。

## 正式发布的最小链路

1. 加入 Apple Developer Program，并创建 Developer ID Application 证书。
2. 使用稳定的 bundle identifier 和版本号构建 Release。
3. 启用 Hardened Runtime，以 Developer ID 对应用签名并加入可信时间戳。
4. 将应用打包为 ZIP 或 DMG，使用 `notarytool` 提交 Apple 公证。
5. 对可 stapling 的产物附加公证票据，并用 `codesign`、`spctl` 和干净 Mac 复核。
6. 只把通过上述验证的产物上传到 GitHub Release。

Mac App Store 不是当前推荐路线：现有实现需要定位并启动官方 Codex 的 `app-server`，应先单独评估 App Sandbox 对该链路的影响。
