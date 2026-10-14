## Context

`AccessoryLifecycleCoordinator` serializes ownership of the app-server session. On a failed `shutdown()`, it deliberately keeps the session reference and marks itself `degraded`, which prevents starting a duplicate process. However, `scheduleReconcile()` rejects all future work in that phase, so the safety guard also prevents recovery. `AccessoryUsageSession.shutdown()` clears its failed shutdown task and can be retried.

The live incident had a healthy ChatGPT process and successful direct app-server read, while the accessory had no app-server child; restarting only the accessory restored the display. The incident did not retain lifecycle logs, so it does not prove a cleanup failure occurred. This change fixes the independently confirmed unrecoverable coordinator branch without changing presence detection policy.

## Goals / Non-Goals

**Goals:**

- Retry cleanup of the retained session with the coordinator's existing bounded backoff.
- Keep the quota state unavailable and prevent a replacement session until cleanup succeeds.
- Let explicit accessory shutdown cancel background reconciliation and make one final serialized cleanup attempt.

**Non-Goals:**

- Change how macOS detects ChatGPT presence or add periodic polling without evidence of missed workspace notifications.
- Change app-server protocol, retry budgets, overlay behavior, or user preferences.
- Attribute the specific live incident to cleanup failure without logs.

## Decisions

- Reuse `retryDelay` and the existing capped exponential delay. This avoids a second retry policy and keeps unit tests deterministic.
- Keep retrying the same retained session after each failure. Creating a replacement before the old `shutdown()` succeeds would violate process ownership and could leave duplicate app-server children.
- Make `shutdownForQuit()` cancel and await the coordinator task before its final cleanup attempt, preventing a background retry and quit cleanup from racing over the same session.

## Risks / Trade-offs

- A persistent cleanup failure will keep the accessory in an unavailable state and retry at the capped interval; it will not create duplicate sessions. Explicit quit cancels that loop.
- This does not repair a missed `NSWorkspace` presence event. The current incident lacked logs to establish that as the cause; presence-event diagnostics or periodic reconciliation should be considered only if a recurrence demonstrates that gap.

## Acceptance Mapping

- `QUOTA-SESSION-RECOVERY-01` → `specs/accessory-session-lifecycle/spec.md` → task 1.1 → lifecycle regression test and verification report.
- Counterexample: a new session is created after a failed close while the old client remains open. A green test or successful quota read in that state is not accepted as recovery.
