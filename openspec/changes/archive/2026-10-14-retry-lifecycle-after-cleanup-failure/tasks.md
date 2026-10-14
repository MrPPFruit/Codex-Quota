## 1. Lifecycle recovery

- [x] 1.1 Retry retained-session cleanup after failure without permitting duplicate app-server sessions.
- [x] 1.2 Replace the permanent-degraded regression test with transient-failure recovery coverage, including no replacement before old-session cleanup succeeds.

## 2. Verification

- [x] 2.1 Run focused lifecycle tests, the full Swift test suite, required repository checks, and a live accessory read after installation.
- [x] 2.2 Record the known limitation that the original lifecycle error was not logged and the exact incident trigger remains unproven.
