# Windows 与 macOS 气泡视觉对齐验证

## 结论

Windows 内部 WPF 表面已完成结构级对齐：收起/展开尺寸、字体层级、额度回退、语义色、两行排版、透明角和单一连续色场均与 macOS 当前设计保持一致。旧版的 5 DIP 内缩、黑色实底、独立彩色描边、外发光和角向分段色带已经移除。

真实材质仍有一项必须在 Windows 11 桌面完成的验收：CI 的 `RenderTargetBitmap` 只能捕获 WPF 内容，不能捕获 DWM Desktop Acrylic 对桌面背景的采样、折射和圆角抗锯齿。因此本报告不把离屏 PNG 解释为完整桌面材质通过。

## 对照基准

- macOS 收起态：52×52 pt。
- macOS 展开态：130×78 pt。
- Windows 收起态：52×52 DIP。
- Windows 展开态：130×78 DIP。
- 两端使用相同的 10 秒单向色流、半透明白层、粉/青/紫/蓝色域、额度阈值和紧凑两行信息结构。

Windows 不再使用会留下扇区分界的角向分段位图。当前色场由四个相互重叠的二维高斯柔光团生成，并在固定 160×160 DIP Canvas 子层中旋转；该尺寸覆盖 130×78 DIP 展开表面的任意旋转角并保留抗锯齿余量，hover 只改变窗口外形，不重新缩放或追踪色层。

preview.2 的 runner PNG 与用户实机截图证明，原 `Image` 被父布局约束后会在展开态的部分相位露出白色底层。preview.3 将固定色场放入不压缩子元素的 Canvas，并在 0/24/45/90/135°、96/144 DPI 下逐点验证圆角矩形内部没有退回白色 base layer。

## 自动化证据

- GitHub Actions：[CI 29274677047](https://github.com/MrPPFruit/Codex-Quota/actions/runs/29274677047) PASS。
- Windows Release build、Core tests、App/UI tests、x64 self-contained single-file 打包与 SHA-256 校验 PASS。
- macOS Node、Swift、bundle build 与 codesign 回归 PASS。
- Windows runner 产物 `codex-quota-windows-ui-captures` 包含固定相位的 `collapsed.png` 与 `expanded.png`；截图验证透明角、表面满铺、文字安全区和无独立外圈。
- 本地 `npm test` 27/27、`swift test` 138/138、`openspec validate add-windows-companion --strict` PASS。

## 预发布产物

- GitHub Prerelease：[v0.2.0-preview.2](https://github.com/MrPPFruit/Codex-Quota/releases/tag/v0.2.0-preview.2)。
- Windows x64 ZIP SHA-256：`940d6d083410707ea37bb808a0aa1cc76cec93a7c6562fb357eeeca4b6a05661`。
- Release 同时保留固定 WPF 收起/展开结构截图；截图不包含 DWM 桌面合成。
- 发布后已重新下载 ZIP 与 `.sha256` 文件，并通过 `shasum -a 256 -c` 校验。

## 实机验收门

下列项目必须由 Windows 11 22621 或更新版本的真实桌面完成，当前保持未通过状态：

- Desktop Acrylic 是否真实采样气泡后方桌面；
- 浅色、深色与高频壁纸下的通透度和文字对比度；
- 100%、125%、150%、200% DPI 下的圆形/圆角边缘；
- hover 形变、拖动、焦点保持与 Reduce Motion；
- 10 秒色流的空闲 CPU/GPU 开销；
- 无 Authenticode 签名预览包的 SmartScreen 行为。

若实机 DWM 材质初始化失败，应用会使用不透明中性浅色表面并记录脱敏原因；不会退回旧版霓虹描边视觉。
