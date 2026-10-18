## 1. Regression and implementation — `QUOTA-SESSION-RECOVERY-02`

- [x] 1.1 Add a production-client regression that injects two old-transport close failures, proves the replacement does not start while cleanup is failing, then completes a fresh rate-limit read without recreating the accessory. Counterexample: the retry method returns or a replacement transport exists while the original transport is still unclosed; that does not satisfy the user outcome.
- [x] 1.2 Make every invalidation await cleanup, retain the old transport on failure, reset failed reconnect-closing state for later attempts, and log fixed cleanup stages/categories. Counterexample: a test passes after one retry but a repeated failure leaves the same rejected barrier/task permanently blocking all later reconnects.

## 2. Verification and delivery

- [x] 2.1 运行定向回归与 Swift 全量测试，构建并安装更新后的菜单栏应用，再从普通入口确认实时额度可见。回归覆盖同一客户端的清理失败恢复。反例：回归和构建通过，但普通安装入口仍显示不可用，或清理失败后必须重启助手。证据：`docs/comet/evidence/2026-10-18-retry-quota-close-barrier-live.md`。
- [x] 2.2 记录已验证源提交、目标分支、远端推送及 PR 集成路径；仅当父结果和普通入口实机证据均已证明后，才以 `complete` 归档。反例：任务复选框已完成，但缺少普通菜单栏实机读取或同进程恢复证据，此时交付仍不完整。证据：PR #12 以 `main` 为目标，源分支已推送，标准 merge-commit 集成路径已确定。

## Delivery Contract

- Parent outcome: `openspec/specs/accessory-session-lifecycle/spec.md#清理失败后会话仍可恢复`
- Parent Acceptance ID: `QUOTA-SESSION-RECOVERY-01`
- Acceptance ID: `QUOTA-SESSION-RECOVERY-02`
- Implementation owner: `AppServerClient` transport invalidation/reconnect lifecycle.
- Spec: `openspec/changes/retry-quota-close-barrier/specs/accessory-session-lifecycle/spec.md`
- Design: `openspec/changes/retry-quota-close-barrier/design.md`
- Evidence location: final verification report plus sanitized OSLog phase output; do not record quota values or account identifiers.
