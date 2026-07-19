## Context

实机运行时，Codex Quota 的窗口可以在 `CGWindowList` 中找到并单独截取内容，但不会出现在当前桌面的 `optionOnScreenOnly` 窗口列表。现有 collection behavior 只有 `.transient`，因此窗口没有跨 Spaces 的归属。

## Goals / Non-Goals

**Goals:**

- 气泡在用户切换普通桌面和全屏应用后仍在当前空间可见。
- 保持 `.floating`、非激活和不随应用失活隐藏的原有交互策略。

**Non-Goals:**

- 不改变气泡位置、尺寸、视觉效果或强制抢到其他应用前台。
- 不改用私有 WindowServer API，也不轮询或复制窗口。

## Decisions

`OverlayPanel` 使用 `.canJoinAllSpaces` 和 `.fullScreenAuxiliary`，同时保留 `.transient`。前者将该独立工具窗口加入每个桌面空间，后者允许它作为全屏应用上的辅助窗口；两者都是 AppKit 的公开窗口策略。把该集合定义为静态值并纳入测试，避免未来初始化代码意外退回到仅 `.transient`。

## Risks / Trade-offs

- [气泡会在更多空间中出现] → 这是用户选择“显示额度气泡”后的预期；用户仍可通过菜单隐藏。
- [个别全屏应用对辅助浮窗的显示策略不同] → 保留 `.floating` 和既有 fail-safe 显示逻辑，不使用未公开绕过手段。
