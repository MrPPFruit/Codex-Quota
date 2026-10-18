## Context

`AppServerClient.invalidate()` currently starts transport closure asynchronously and stores its `Task` as `closeBarrier`. If `close()` fails, the transport reference has already been cleared and the failed task remains stored. Later `connect()` awaits that same failed task before the transport-start stage; this wait is outside the connection error handler, so the failure is neither retried nor logged as a connection failure. The session loop keeps retrying, but can never reach a fresh app-server process. This matches the live trace: repeated `connection_started` without `transport_started`, while a fresh `AppServerClient` and a restarted accessory both read successfully.

## Goals / Non-Goals

**Goals:**

- Preserve ownership of the old transport until its process is confirmed closed.
- Let the existing bounded retry loop retry cleanup after one or more failures, then start a replacement connection.
- Make cleanup failure visible through fixed-stage, privacy-safe logs.

**Non-Goals:**

- Change the quota API, user-visible UI, account authentication, or retry budget.
- Clear a failed barrier and start a replacement while the previous child may still be alive.

## Decisions

- Make invalidation wait for transport close. On failure, keep the same transport and `transportStarted` state, clear only the completed barrier, log the fixed error category, and propagate the error. A later session retry then retries cleanup before opening a new transport.
- Reset a failed reconnect-closing lifecycle task to a retryable idle state. Otherwise later calls would join the same completed failed task forever.
- Add a regression that injects two cleanup failures, then succeeds. It must prove the replacement transport is not started before the old one closes and the normal rate-limit handshake completes afterward.
- Extend the existing `accessory-session-lifecycle` requirement because the behavior is already part of the product contract; no new capability is introduced.

The alternative of dropping the failed barrier and proceeding directly to a new transport is rejected: it could orphan a live child and create concurrent app-server sessions.

## Risks / Trade-offs

- **Repeated cleanup failure keeps quota unavailable** → Preserve fail-closed behavior and retry with the existing bounded backoff; do not create a replacement until closure succeeds.
- **Waiting for close delays a reconnect slightly** → Current process termination is bounded; this wait is required by the existing ownership contract.

## Migration Plan

No persisted state or user settings change. Build and install the accessory update; an already-running old process must be restarted once to load the fix. Rollback is the prior app bundle; no data migration is required.

## Open Questions

None. The original cleanup failure was not logged by the old process, so its initiating trigger remains unknown; the permanent retry-poisoning behavior is established by the current control flow and reproduced by the regression test.
