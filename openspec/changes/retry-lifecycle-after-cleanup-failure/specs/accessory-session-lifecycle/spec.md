## ADDED Requirements

### Requirement: Failed session cleanup remains recoverable
The accessory MUST retain ownership of a session when shutdown fails, keep quota state unavailable, and retry shutdown with bounded backoff. It MUST NOT create or start a replacement session until shutdown of the retained session succeeds. Reconciliation MUST recover automatically without requiring the user to restart the accessory.

#### Scenario: Transient cleanup failure recovers while Codex is present
- **WHEN** shutdown of the current session fails once and Codex is present or becomes present again
- **THEN** the accessory retries shutdown, creates a replacement only after shutdown succeeds, and resumes quota updates

#### Scenario: Cleanup continues to fail
- **WHEN** shutdown keeps failing while Codex is present
- **THEN** the quota state remains unavailable, the same session remains owned, retries use bounded backoff, and no replacement session is created

#### Scenario: User quits during cleanup retry
- **WHEN** the user quits the accessory while cleanup retry is pending
- **THEN** background reconciliation is cancelled and awaited before one final serialized shutdown attempt
