## Why

Codex Quota 的悬浮窗目前只属于启动时所在的 macOS 桌面空间。用户切换到其他桌面或全屏应用后，应用和额度读取仍然正常，但气泡不在当前可见窗口列表，造成“应用运行却看不到”的假象。

## What Changes

- 让悬浮窗加入所有 macOS 桌面空间，并作为全屏应用的辅助窗口显示。
- 保留不抢焦点、可拖动、透明点击区域和现有浮动层级。
- 增加窗口策略测试，锁定跨空间行为。

## Capabilities

### New Capabilities

- `overlay-space-visibility`: 悬浮气泡在桌面空间与全屏应用之间的可见性契约。

### Modified Capabilities

无。

## Impact

- 影响 `OverlayPanel` 的窗口 collection behavior 与其单元测试。
- 不影响额度协议、位置持久化、UI 尺寸、认证和发布版本号。
