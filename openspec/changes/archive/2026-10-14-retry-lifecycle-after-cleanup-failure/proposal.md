## Why

When the accessory fails to close an app-server session during a Codex presence transition, the lifecycle coordinator enters `degraded` and currently refuses every later reconcile. If Codex remains open or returns, the accessory can stay unavailable until the user restarts it, even though a later cleanup attempt could succeed.

The live failure showed ChatGPT and a direct app-server quota read were healthy while the accessory had no app-server child; restarting only the accessory restored the quota display. The pre-restart lifecycle error was not logged, so the cleanup failure path is a confirmed code defect and plausible cause, not a proven trigger for that specific incident.

## What Changes

- Allow a degraded accessory session to retry cleanup with the existing bounded backoff.
- Preserve the ownership rule that a replacement session starts only after the old session closes successfully.
- Add a regression test that injects one cleanup failure and verifies automatic recovery without restarting the accessory.

## Capabilities

### New Capabilities

- `accessory-session-lifecycle`: Recovery and ownership rules for app-server sessions across Codex presence changes.

### Modified Capabilities

None.

## Impact

- Affects `AccessoryLifecycleCoordinator` and its lifecycle tests.
- No protocol, UI, preference, authentication, or public API changes.
- Acceptance ID `QUOTA-SESSION-RECOVERY-01`: after a transient session cleanup failure, the accessory retries cleanup and resumes quota reading without an accessory restart.
- Counterexample: the test passes because a replacement client was created, but the old client is still open; that is not accepted as recovery.
