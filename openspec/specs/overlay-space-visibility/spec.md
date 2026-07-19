# overlay-space-visibility Specification

## Purpose
TBD - created by archiving change keep-overlay-visible-across-spaces. Update Purpose after archive.
## Requirements
### Requirement: 气泡跨桌面空间可见
当用户启用额度气泡且 Codex 正在运行时，系统 MUST 将悬浮窗加入所有 macOS 桌面空间，并允许其作为全屏应用的辅助窗口显示，同时保持非激活浮动窗口策略。

#### Scenario: 用户切换桌面空间
- **WHEN** 气泡在一个普通桌面空间中已显示，用户切换到另一个桌面空间
- **THEN** 气泡 MUST 在切换后的当前空间保持可见

#### Scenario: 用户进入全屏应用
- **WHEN** 气泡已显示，用户进入全屏应用空间
- **THEN** 气泡 MUST 作为辅助窗口保持可见且不得抢占键盘焦点
