import { createHash } from "node:crypto";
import { appendFile, chmod, readFile, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";

export const markerKey = "CODEX_USAGE_SMOKE_RUN_ID";

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export function hasExactMarker(command, marker) {
  return new RegExp(`(?:^|\\s)${markerKey}=${escapeRegExp(marker)}(?:\\s|$)`).test(command);
}

export function parseProcessLine(line) {
  const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d\d:\d\d:\d\d\s+\d{4})\s+(.+)$/);
  return match ? { pid: Number(match[1]), ppid: Number(match[2]), startToken: match[3], command: match[4] } : null;
}

export function remainingBudgetSeconds(deadlineEpoch, nowEpoch) {
  return Math.max(0, Math.floor(deadlineEpoch - nowEpoch));
}

const identityHash = ({ pid, startToken, executable }) =>
  createHash("sha256").update(`${pid}\0${startToken}\0${executable}`).digest("hex");

function canonicalExecutable(commandName, timeout = 250) {
  const candidate = commandName.startsWith("/")
    ? commandName
    : execFileSync("/usr/bin/which", [commandName], { encoding: "utf8", timeout }).trim();
  return realpathSync(candidate);
}

export function collectOwned(psOutput, marker, rootPID, resolveExecutable) {
  const table = new Map(psOutput.split("\n").map(parseProcessLine).filter(Boolean).map((record) => [record.pid, record]));
  const descendsFromRoot = (record) => {
    if (record.pid === rootPID) return true;
    const visited = new Set([record.pid]);
    let cursor = record;
    while (cursor.ppid > 0) {
      if (cursor.ppid === rootPID) return true;
      if (visited.has(cursor.ppid)) return false;
      visited.add(cursor.ppid);
      cursor = table.get(cursor.ppid);
      if (!cursor) return false;
    }
    return false;
  };
  const owned = [];
  for (const parsed of table.values()) {
    if (!hasExactMarker(parsed.command, marker) || !descendsFromRoot(parsed)) continue;
    try {
      const executable = resolveExecutable(parsed.pid);
      owned.push({ ...parsed, command: undefined, executable, identityHash: identityHash({ ...parsed, executable }) });
    } catch {}
  }
  return owned;
}

export function selectIdentityMatches(recorded, current) {
  const hashes = new Set(recorded.map((record) => record.identityHash));
  return current.filter((record) => hashes.has(record.identityHash));
}

export function uniqueConsistentIdentities(records) {
  const byPID = new Map();
  const conflictedPIDs = new Set();
  for (const record of records) {
    if (conflictedPIDs.has(record.pid)) continue;
    if (!byPID.has(record.pid)) byPID.set(record.pid, record);
    else if (byPID.get(record.pid).identityHash !== record.identityHash) {
      byPID.delete(record.pid);
      conflictedPIDs.add(record.pid);
    }
  }
  return [...byPID.values()];
}

export function cleanupRecordedGroups({ groups, scanGroup, now, signal, sleep, finalDeadline }) {
  let bestEffortAfterDeadline = now() >= finalDeadline;
  const scanAll = () => uniqueConsistentIdentities(
    groups.flatMap((group) => selectIdentityMatches(group.records, scanGroup(group, bestEffortAfterDeadline)))
  );
  let remaining = scanAll();
  bestEffortAfterDeadline ||= now() >= finalDeadline;
  const termCount = remaining.length;
  for (const record of remaining) signal(record.pid, "SIGTERM");
  if (bestEffortAfterDeadline) {
    return { bestEffortAfterDeadline: true, termCount: remaining.length, killCount: 0, residualCount: remaining.length };
  }
  while (now() + 150 < finalDeadline && remaining.length) { sleep(50); remaining = scanAll(); }
  for (const record of remaining) signal(record.pid, "SIGKILL");
  const killCount = remaining.length;
  while (now() < finalDeadline && remaining.length) { sleep(25); remaining = scanAll(); }
  return { bestEffortAfterDeadline: false, termCount, killCount, residualCount: remaining.length };
}

function recordPID(pid, requiredMarker, timeout = 250) {
  const argumentsList = requiredMarker
    ? ["eww", "-p", String(pid), "-o", "pid=,ppid=,lstart=,command="]
    : ["-p", String(pid), "-o", "pid=,ppid=,lstart=,command="];
  const line = execFileSync("/bin/ps", argumentsList, { encoding: "utf8", timeout }).trim();
  const parsed = parseProcessLine(line);
  if (!parsed) throw new Error("PID identity unavailable");
  if (requiredMarker && !hasExactMarker(parsed.command, requiredMarker)) throw new Error("PID marker identity unavailable");
  const executable = canonicalExecutable(execFileSync("/bin/ps", ["-p", String(pid), "-o", "comm="], { encoding: "utf8", timeout }).trim(), timeout);
  return { pid, identityHash: identityHash({ ...parsed, executable }) };
}

function scan(marker, rootPID, tableTimeout = 750, processTimeout = 250) {
  const table = execFileSync("/bin/ps", ["eww", "-axo", "pid=,ppid=,lstart=,command="], { encoding: "utf8", timeout: tableTimeout });
  return collectOwned(table, marker, rootPID, (pid) => {
    const executable = execFileSync("/bin/ps", ["-p", String(pid), "-o", "comm="], { encoding: "utf8", timeout: processTimeout }).trim();
    return canonicalExecutable(executable, processTimeout);
  });
}

async function appendSnapshot(path, records, rootExecutable) {
  const redacted = records.map((record) => ({
    pid: record.pid,
    identityHash: record.identityHash,
    isRootExecutable: record.executable === rootExecutable,
  }));
  if (redacted.length) await appendFile(path, redacted.map((record) => `${JSON.stringify(record)}\n`).join(""), { mode: 0o600 });
  else await writeFile(path, "", { flag: "a", mode: 0o600 });
  await chmod(path, 0o600);
}

async function readObserved(path) {
  const text = await readFile(path, "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).map((line) => JSON.parse(line));
}

export async function runCLI(environment = process.env, argv = process.argv.slice(2)) {
  const [operation, path, pidText, observerPath] = argv;
  const marker = environment.SMOKE_SCANNER_TARGET;
  if (!path?.startsWith("/")) throw new Error("invalid smoke scanner path");
  if (operation === "record-pid") {
    const record = recordPID(Number(pidText), marker);
    await appendFile(path, `${JSON.stringify(record)}\n`, { mode: 0o600 }); await chmod(path, 0o600);
    return;
  }
  if (operation === "terminate-recorded") {
    const recorded = await readObserved(path);
    const deadline = Number(environment.SMOKE_FINAL_DEADLINE_MS);
    const currentMatches = () => recorded.filter((record) => {
      try {
        const current = recordPID(record.pid, marker);
        if (current.identityHash !== record.identityHash) throw new Error(`PID ${record.pid} identity changed; refusing signal`);
        return true;
      } catch (error) {
        if (error.message?.includes("identity changed")) throw error;
        return false;
      }
    });
    let matches = currentMatches();
    for (const record of matches) process.kill(record.pid, "SIGTERM");
    while (Date.now() + 150 < deadline && matches.length) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50); matches = currentMatches();
    }
    for (const record of matches) process.kill(record.pid, "SIGKILL");
    while (Date.now() < deadline && matches.length) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25); matches = currentMatches();
    }
    if (matches.length) throw new Error("recorded PID survived final deadline");
    return;
  }
  if (operation === "cleanup-records") {
    if (!marker || !/^[A-Fa-f0-9-]{32,64}$/.test(marker)) throw new Error("invalid smoke scanner marker");
    const appPath = pidText;
    const ownedRecords = await readObserved(path);
    const appRecords = await readObserved(appPath);
    const observerRecords = await readObserved(observerPath);
    const currentFor = (records, requiredMarker, timeout = 250) => records.flatMap((record) => {
      try {
        const current = recordPID(record.pid, requiredMarker, timeout);
        return current.identityHash === record.identityHash ? [current] : [];
      } catch { return []; }
    });
    const groups = [
      { kind: "owned", records: ownedRecords },
      { kind: "app", records: appRecords },
      { kind: "observer", records: observerRecords },
    ];
    const result = cleanupRecordedGroups({
      groups,
      scanGroup: (group, quick) => {
        if (group.kind === "owned") return currentFor(group.records, marker, quick ? 20 : 250);
        if (quick && group.kind === "app") return []; // app is already marker-owned in the unified scan
        return currentFor(group.records, group.kind === "app" ? marker : undefined, quick ? 20 : 250);
      },
      now: () => Date.now(),
      signal: (pid, name) => { try { process.kill(pid, name); } catch (error) { if (error.code !== "ESRCH") throw error; } },
      sleep: (milliseconds) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds),
      finalDeadline: Number(environment.SMOKE_FINAL_DEADLINE_MS),
    });
    process.stdout.write(JSON.stringify(result));
    if (!result.bestEffortAfterDeadline && result.residualCount) throw new Error("recorded processes survived final deadline");
    return;
  }
  if (!marker || !/^[A-Fa-f0-9-]{32,64}$/.test(marker)) throw new Error("invalid smoke scanner marker");
  if (operation === "scan") {
    const rootPID = Number(environment.SMOKE_ROOT_PID);
    if (!Number.isSafeInteger(rootPID) || rootPID <= 0) throw new Error("invalid smoke root PID");
    await appendSnapshot(path, scan(marker, rootPID), environment.SMOKE_ROOT_EXECUTABLE);
    return;
  }
  const observed = await readObserved(path);
  const currentObserved = () => observed.flatMap((record) => {
    try { const value = recordPID(record.pid, marker); return value.identityHash === record.identityHash ? [value] : []; }
    catch { return []; }
  });
  const current = currentObserved();
  const observedHashes = new Set(observed.map((record) => record.identityHash));
  if (operation === "cleanup") {
    const deadline = Number(environment.SMOKE_FINAL_DEADLINE_MS);
    let remaining = selectIdentityMatches(observed, current);
    for (const record of remaining) process.kill(record.pid, "SIGTERM");
    while (Date.now() + 150 < deadline && remaining.length) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
      remaining = selectIdentityMatches(observed, currentObserved());
    }
    for (const record of remaining) process.kill(record.pid, "SIGKILL");
    while (Date.now() < deadline && remaining.length) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
      remaining = selectIdentityMatches(observed, currentObserved());
    }
    if (remaining.length) throw new Error("marker-owned processes survived final deadline");
    return;
  }
  if (operation === "summary") {
    const unique = [...new Set(observed.map((record) => record.identityHash))];
    const children = [...new Set(observed.filter((record) => !record.isRootExecutable).map((record) => record.identityHash))];
    const residual = current.filter((record) => observedHashes.has(record.identityHash));
    process.stdout.write(JSON.stringify({
      observedOwnedProcessCount: unique.length,
      observedOwnedChildProcessCount: children.length,
      observedOwnedIdentityHashes: unique,
      residualOwnedProcessCount: residual.length,
    }));
    return;
  }
  throw new Error("unknown operation");
}

if (process.argv[1]?.endsWith("smoke-process-evidence.mjs")) await runCLI();
