import assert from "node:assert/strict";
import test from "node:test";
import { cleanupRecordedGroups, collectOwned, hasExactMarker, parseProcessLine, remainingBudgetSeconds, selectIdentityMatches } from "../scripts/lib/smoke-process-evidence.mjs";

const marker = "12345678-1234-1234-1234-123456789abc";

test("smoke marker matches only the exact inherited environment token", () => {
  assert.equal(hasExactMarker(`bin CODEX_USAGE_SMOKE_RUN_ID=${marker} other=x`, marker), true);
  assert.equal(hasExactMarker(`bin OTHER=${marker}`, marker), false);
  assert.equal(hasExactMarker(`bin CODEX_USAGE_SMOKE_RUN_ID=${marker}-foreign`, marker), false);
  assert.equal(hasExactMarker(`bin PREFIX_CODEX_USAGE_SMOKE_RUN_ID=${marker}`, marker), false);
});

test("owned process evidence ignores unrelated processes and hashes identity", () => {
  const table = [
    ` 101 1 Sun Jul 13 00:00:01 2026 /tool CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 102 1 Sun Jul 13 00:00:02 2026 /official CODEX_USAGE_SMOKE_RUN_ID=unrelated`,
    ` 103 1 Sun Jul 13 00:00:03 2026 /scanner SMOKE_SCANNER_TARGET=${marker}`,
  ].join("\n");
  const records = collectOwned(table, marker, 101, (pid) => `/canonical/${pid}`);
  assert.equal(records.length, 1);
  assert.equal(records[0].pid, 101);
  assert.match(records[0].identityHash, /^[a-f0-9]{64}$/);
  assert.equal("command" in records[0] && records[0].command !== undefined, false);
  assert.deepEqual(parseProcessLine("not a process"), null);
});

test("same-user copied marker is excluded unless it descends from this root", () => {
  const table = [
    ` 100 1 Sun Jul 13 00:00:00 2026 /root CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 101 100 Sun Jul 13 00:00:01 2026 /child CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 102 101 Sun Jul 13 00:00:02 2026 /grandchild CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 999 1 Sun Jul 13 00:00:03 2026 /copied CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
  ].join("\n");
  const owned = collectOwned(table, marker, 100, (pid) => `/canonical/${pid}`);
  assert.deepEqual(owned.map(({ pid }) => pid), [100, 101, 102]);
  const signals = [];
  cleanupRecordedGroups({
    groups: [{ records: [] }], scanGroup: () => [], now: () => 0,
    signal: (...value) => signals.push(value), sleep: () => {}, finalDeadline: 500,
  });
  assert.deepEqual(signals, []);
});

test("missing or cyclic parent chains fail closed", () => {
  const table = [
    ` 100 1 Sun Jul 13 00:00:00 2026 /root CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 201 202 Sun Jul 13 00:00:01 2026 /cycle-a CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 202 201 Sun Jul 13 00:00:02 2026 /cycle-b CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
    ` 203 404 Sun Jul 13 00:00:03 2026 /missing CODEX_USAGE_SMOKE_RUN_ID=${marker}`,
  ].join("\n");
  assert.deepEqual(collectOwned(table, marker, 100, (pid) => `/canonical/${pid}`).map(({ pid }) => pid), [100]);
});

test("shared deadline budget never becomes negative or stacks waits", () => {
  assert.equal(remainingBudgetSeconds(112, 100), 12);
  assert.equal(remainingBudgetSeconds(112, 109.8), 2);
  assert.equal(remainingBudgetSeconds(112, 113), 0);
});

test("PID reuse identity mismatch is never selected for signaling", () => {
  const recorded = [{ pid: 101, identityHash: "old-start-and-executable" }];
  const reused = [{ pid: 101, identityHash: "new-start-or-executable" }];
  const exact = [{ pid: 101, identityHash: "old-start-and-executable" }];
  assert.deepEqual(selectIdentityMatches(recorded, reused), []);
  assert.deepEqual(selectIdentityMatches(recorded, exact), exact);
});

test("a descendant recorded before reparent remains cleanup-eligible only by its recorded identity", () => {
  const recorded = { pid: 102, identityHash: "recorded-descendant" };
  const signals = [];
  cleanupRecordedGroups({
    groups: [{ kind: "owned", records: [recorded] }],
    scanGroup: () => [recorded],
    now: () => 500,
    signal: (pid, name) => signals.push([pid, name]),
    sleep: () => assert.fail("expired cleanup must not wait"),
    finalDeadline: 500,
  });
  assert.deepEqual(signals, [[102, "SIGTERM"]]);
});

test("cleanup performs TERM, reverify, KILL, then confirms exit", () => {
  const record = { pid: 101, identityHash: "same" };
  let clock = 0; let scans = 0; const signals = [];
  const result = cleanupRecordedGroups({
    groups: [{ records: [record] }],
    scanGroup: () => ++scans < 3 ? [record] : [],
    now: () => clock,
    signal: (pid, name) => signals.push([pid, name]),
    sleep: () => { clock += 400; },
    finalDeadline: 500,
  });
  assert.deepEqual(signals, [[101, "SIGTERM"], [101, "SIGKILL"]]);
  assert.equal(result.residualCount, 0);
});

test("expired cleanup does one verified TERM pass and never KILLs", () => {
  const record = { pid: 101, identityHash: "same" }; const signals = [];
  const result = cleanupRecordedGroups({
    groups: [{ records: [record] }], scanGroup: () => [record], now: () => 500,
    signal: (pid, name) => signals.push([pid, name]), sleep: () => assert.fail("must not wait"), finalDeadline: 500,
  });
  assert.deepEqual(signals, [[101, "SIGTERM"]]);
  assert.equal(result.bestEffortAfterDeadline, true);
});

test("marker or identity mismatches produce zero signals", () => {
  const signals = [];
  cleanupRecordedGroups({
    groups: [{ records: [{ pid: 101, identityHash: "recorded" }] }],
    scanGroup: () => [{ pid: 101, identityHash: "reused-or-marker-mismatch" }], now: () => 0,
    signal: (...value) => signals.push(value), sleep: () => {}, finalDeadline: 500,
  });
  assert.deepEqual(signals, []);
});

test("one group consuming the budget does not bypass later identity verification", () => {
  const signals = []; let clock = 0;
  const first = { pid: 101, identityHash: "first" };
  const result = cleanupRecordedGroups({
    groups: [{ kind: "first", records: [first] }, { kind: "later", records: [{ pid: 202, identityHash: "expected" }] }],
    scanGroup: (group) => { if (group.kind === "first") { clock = 500; return [first]; } return [{ pid: 202, identityHash: "different" }]; },
    now: () => clock, signal: (pid, name) => signals.push([pid, name]), sleep: () => {}, finalDeadline: 500,
  });
  assert.deepEqual(signals, [[101, "SIGTERM"]]);
  assert.equal(result.bestEffortAfterDeadline, true);
});

test("overlapping owned and app topology signals one identity once per phase", () => {
  const record = { pid: 101, identityHash: "same-pid-start-executable" };
  let clock = 0; let scans = 0; const signals = [];
  cleanupRecordedGroups({
    groups: [{ kind: "owned", records: [record] }, { kind: "app", records: [record] }],
    scanGroup: () => ++scans <= 4 ? [record] : [],
    now: () => clock,
    signal: (pid, name) => signals.push([pid, name]),
    sleep: () => { clock += 400; },
    finalDeadline: 500,
  });
  assert.deepEqual(signals, [[101, "SIGTERM"], [101, "SIGKILL"]]);
});

test("same PID with conflicting identities is rejected without signals", () => {
  const signals = [];
  cleanupRecordedGroups({
    groups: [
      { kind: "owned", records: [{ pid: 101, identityHash: "old" }] },
      { kind: "app", records: [{ pid: 101, identityHash: "new" }] },
    ],
    scanGroup: (group) => group.records,
    now: () => 500,
    signal: (...value) => signals.push(value),
    sleep: () => assert.fail("conflicting identity must not wait"),
    finalDeadline: 500,
  });
  assert.deepEqual(signals, []);
});

for (const [name, identities, expectedSignals] of [
  ["A/B/A remains permanently conflicted", ["A", "B", "A"], 0],
  ["A/B/B remains permanently conflicted", ["A", "B", "B"], 0],
  ["A/A/A deduplicates to one identity", ["A", "A", "A"], 1],
]) {
  test(name, () => {
    const signals = [];
    cleanupRecordedGroups({
      groups: identities.map((identityHash) => ({ records: [{ pid: 101, identityHash }] })),
      scanGroup: (group) => group.records,
      now: () => 500,
      signal: (...value) => signals.push(value),
      sleep: () => assert.fail("expired topology check must not wait"),
      finalDeadline: 500,
    });
    assert.equal(signals.length, expectedSignals);
    if (expectedSignals) assert.deepEqual(signals[0], [101, "SIGTERM"]);
  });
}
