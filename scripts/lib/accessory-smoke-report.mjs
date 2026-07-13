import { constants } from "node:fs";
import { chmod, lstat, mkdir, open, realpath, rename, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

export function evaluateForeground(before, after) {
  if (typeof before !== "string" || typeof after !== "string" || !before.trim() || !after.trim()) {
    throw new Error("frontmost application probe unavailable");
  }
  return before === after;
}

export async function atomicWriteSmokeReport({ artifactsDirectory, destination, value }) {
  const allowed = new Set([
    join(resolve(artifactsDirectory), "accessory-smoke.json"),
    join(resolve(artifactsDirectory), "accessory-smoke-absent.json"),
  ]);
  if (!allowed.has(resolve(destination))) throw new Error("smoke report destination is not allowlisted");
  await mkdir(artifactsDirectory, { recursive: true });
  const canonicalArtifacts = await realpath(artifactsDirectory);
  const artifactsStat = await lstat(artifactsDirectory);
  if (artifactsStat.isSymbolicLink() || !artifactsStat.isDirectory()) throw new Error("artifacts directory is a symlink or invalid");
  if (await realpath(dirname(destination)) !== canonicalArtifacts) throw new Error("smoke report destination escaped artifacts");
  const existing = await lstat(destination).catch((error) => error.code === "ENOENT" ? null : Promise.reject(error));
  if (existing?.isDirectory()) throw new Error("smoke report destination is a directory");
  const temporary = join(canonicalArtifacts, `.accessory-smoke.${randomUUID()}.tmp`);
  let handle;
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
    await handle.writeFile(`${JSON.stringify(value)}\n`);
    await handle.sync();
    await handle.close(); handle = undefined;
    await chmod(temporary, 0o600);
    await rename(temporary, destination);
  } catch (error) {
    await handle?.close().catch(() => {});
    await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

export async function runReportCLI(environment = process.env) {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  await atomicWriteSmokeReport({
    artifactsDirectory: environment.SMOKE_ARTIFACTS_DIRECTORY,
    destination: environment.SMOKE_REPORT_DESTINATION,
    value,
  });
}

if (process.argv[1]?.endsWith("accessory-smoke-report.mjs")) await runReportCLI();
