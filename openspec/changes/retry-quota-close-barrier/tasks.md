## 1. Regression and implementation — `QUOTA-SESSION-RECOVERY-02`

- [x] 1.1 Add a production-client regression that injects two old-transport close failures, proves the replacement does not start while cleanup is failing, then completes a fresh rate-limit read without recreating the accessory. Counterexample: the retry method returns or a replacement transport exists while the original transport is still unclosed; that does not satisfy the user outcome.
- [x] 1.2 Make every invalidation await cleanup, retain the old transport on failure, reset failed reconnect-closing state for later attempts, and log fixed cleanup stages/categories. Counterexample: a test passes after one retry but a repeated failure leaves the same rejected barrier/task permanently blocking all later reconnects.

## 2. Verification and delivery

- [ ] 2.1 Run the focused regression and full Swift suite; build and install the updated accessory, then verify the normal menu-bar entry displays live quota. The regression covers injected same-session cleanup recovery. Counterexample: the regression/build passes but the ordinary installed menu-bar path still displays unavailable or requires an accessory restart after a recoverable cleanup failure.
- [ ] 2.2 Record the verified commit and integration/remote state, then archive as `complete` only after the parent outcome and live entry are proven. Counterexample: all checkboxes pass but the live menu-bar path or same-process recovery evidence is missing; the outcome remains incomplete.

## Delivery Contract

- Parent outcome: `openspec/specs/accessory-session-lifecycle/spec.md#清理失败后会话仍可恢复`
- Parent Acceptance ID: `QUOTA-SESSION-RECOVERY-01`
- Acceptance ID: `QUOTA-SESSION-RECOVERY-02`
- Implementation owner: `AppServerClient` transport invalidation/reconnect lifecycle.
- Spec: `openspec/changes/retry-quota-close-barrier/specs/accessory-session-lifecycle/spec.md`
- Design: `openspec/changes/retry-quota-close-barrier/design.md`
- Evidence location: final verification report plus sanitized OSLog phase output; do not record quota values or account identifiers.
