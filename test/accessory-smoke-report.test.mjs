import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { atomicWriteSmokeReport, evaluateForeground } from "../scripts/lib/accessory-smoke-report.mjs";

test("foreground evidence fails closed on unavailable probes", () => {
  assert.throws(() => evaluateForeground("", "com.example.front"), /unavailable/);
  assert.throws(() => evaluateForeground("com.example.front", null), /unavailable/);
  assert.equal(evaluateForeground("com.example.front", "com.example.front"), true);
  assert.equal(evaluateForeground("com.example.front", "com.example.other"), false);
});

test("safe report writer replaces a destination symlink without external writes", async () => {
  const root = await mkdtemp(join(tmpdir(), "accessory-report-test."));
  const artifacts = join(root, "artifacts"); await mkdir(artifacts);
  const destination = join(artifacts, "accessory-smoke.json");
  const outside = join(root, "outside.json"); await writeFile(outside, "outside");
  await symlink(outside, destination);
  try {
    await atomicWriteSmokeReport({ artifactsDirectory: artifacts, destination, value: { complete: true } });
    assert.equal(await readFile(outside, "utf8"), "outside");
    assert.deepEqual(JSON.parse(await readFile(destination, "utf8")), { complete: true });
    assert.equal((await lstat(destination)).isFile(), true);
    assert.equal((await lstat(destination)).mode & 0o777, 0o600);
    assert.deepEqual((await (await import("node:fs/promises")).readdir(artifacts)).sort(), ["accessory-smoke.json"]);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("safe report writer rejects non-allowlisted and directory destinations", async () => {
  const root = await mkdtemp(join(tmpdir(), "accessory-report-test."));
  const artifacts = join(root, "artifacts"); await mkdir(artifacts);
  try {
    await assert.rejects(atomicWriteSmokeReport({ artifactsDirectory: artifacts, destination: join(artifacts, "other.json"), value: {} }), /allowlisted/);
    await mkdir(join(artifacts, "accessory-smoke.json"));
    await assert.rejects(atomicWriteSmokeReport({ artifactsDirectory: artifacts, destination: join(artifacts, "accessory-smoke.json"), value: {} }), /directory/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("safe report writer permits the deterministic absent report", async () => {
  const root = await mkdtemp(join(tmpdir(), "accessory-report-test."));
  const artifacts = join(root, "artifacts"); await mkdir(artifacts);
  const destination = join(artifacts, "accessory-smoke-absent.json");
  try {
    await atomicWriteSmokeReport({ artifactsDirectory: artifacts, destination, value: { expectedCodexPresence: "absent" } });
    assert.deepEqual(JSON.parse(await readFile(destination, "utf8")), { expectedCodexPresence: "absent" });
  } finally { await rm(root, { recursive: true, force: true }); }
});
