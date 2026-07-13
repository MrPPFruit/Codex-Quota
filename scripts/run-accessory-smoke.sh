#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
bundle="$repo_root/artifacts/build/Codex Quota.app"
executable="$bundle/Contents/MacOS/CodexUsageAccessory"
expected_presence="${SMOKE_EXPECT_CODEX_PRESENCE:-present}"
[[ "$expected_presence" == "present" || "$expected_presence" == "absent" ]] || { echo "SMOKE_EXPECT_CODEX_PRESENCE 必须为 present 或 absent" >&2; exit 1; }
if [[ "$expected_presence" == "present" ]]; then
  report="$repo_root/artifacts/accessory-smoke.json"
else
  report="$repo_root/artifacts/accessory-smoke-absent.json"
fi
scanner="$repo_root/scripts/lib/smoke-process-evidence.mjs"
report_writer="$repo_root/scripts/lib/accessory-smoke-report.mjs"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codex-accessory-smoke.XXXXXX")"
internal="$work_dir/internal.json"
observed="$work_dir/owned-processes.jsonl"
app_identity="$work_dir/app-identity.jsonl"
observer_identity="$work_dir/observer-identity.jsonl"
report_payload="$work_dir/report-payload.json"
app_stdout="$work_dir/stdout.log"
app_stderr="$work_dir/stderr.log"
app_pid=""
app_root_pid=""
observer_pid=""
run_id="$(uuidgen | tr -d '\n')"
deadline_epoch=$(( $(date +%s) + 12 ))
work_deadline_epoch=$((deadline_epoch - 3))
smoke_succeeded=false
cleanup_result='{"bestEffortAfterDeadline":false,"termCount":0,"killCount":0,"residualCount":0}'

now_epoch() { date +%s; }
pid_exists() { kill -0 "$1" 2>/dev/null; }
wait_until_epoch() {
  local absolute_deadline="$1"; shift
  while (( $(now_epoch) < absolute_deadline )); do "$@" && return 0; sleep 0.1; done
  return 1
}
frontmost_bundle_id() {
  /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier.js' 2>/dev/null || true
}
scan_owned() { SMOKE_SCANNER_TARGET="$run_id" SMOKE_ROOT_PID="$app_root_pid" SMOKE_ROOT_EXECUTABLE="$executable_real" node "$scanner" scan "$observed"; }
observe_owned() {
  while [[ ! -e "$work_dir/stop-observer" ]] && (( $(now_epoch) < deadline_epoch )); do scan_owned || true; sleep 0.1; done
}
stop_observer() {
  touch "$work_dir/stop-observer"
  if [[ -n "$observer_pid" ]] && pid_exists "$observer_pid"; then
    local grace_deadline=$(( $(now_epoch) + 1 ))
    (( grace_deadline > work_deadline_epoch )) && grace_deadline=$work_deadline_epoch
    wait_until_epoch "$grace_deadline" bash -c '! kill -0 "$1" 2>/dev/null' _ "$observer_pid" || true
  fi
  observer_pid=""
}
run_cleanup() {
  stop_observer
  cleanup_result="$(SMOKE_SCANNER_TARGET="$run_id" SMOKE_FINAL_DEADLINE_MS="$((deadline_epoch * 1000))" node "$scanner" cleanup-records "$observed" "$app_identity" "$observer_identity" 2>/dev/null)" || \
    cleanup_result='{"bestEffortAfterDeadline":true,"cleanupError":true}'
}
cleanup() {
  run_cleanup
  if [[ -n "$app_pid" ]] && pid_exists "$app_pid"; then
    echo "accessory PID identity mismatch or cleanup budget exhausted; refusing unverified signal" >&2
  fi
  if [[ "$smoke_succeeded" == true ]]; then rm -rf "$work_dir"; else echo "smoke 失败诊断保留于 $work_dir" >&2; fi
}
trap cleanup EXIT INT TERM

[[ -x "$executable" && ! -L "$executable" ]] || { echo "accessory bundle 未构建或 executable 非法" >&2; exit 1; }
bundle_real="$(realpath "$bundle")"; executable_real="$(realpath "$executable")"
case "$executable_real" in "$bundle_real/Contents/MacOS/"*) ;; *) echo "executable 逃逸 bundle" >&2; exit 1 ;; esac

before="$(frontmost_bundle_id)"
[[ -n "$before" ]] || { echo "frontmost application probe unavailable before launch" >&2; exit 1; }
CODEX_USAGE_SMOKE_RUN_ID="$run_id" CODEX_ACCESSORY_SMOKE_DIAGNOSTIC_PATH="$internal" CODEX_ACCESSORY_SMOKE_EXIT_AFTER_SECONDS=3 CODEX_ACCESSORY_SMOKE_CODEX_PRESENCE="$expected_presence" \
  "$executable" >"$app_stdout" 2>"$app_stderr" &
app_pid=$!
app_root_pid="$app_pid"
SMOKE_SCANNER_TARGET="$run_id" node "$scanner" record-pid "$app_identity" "$app_pid"
observe_owned & observer_pid=$!
node "$scanner" record-pid "$observer_identity" "$observer_pid"

diagnostic_deadline=$work_deadline_epoch
wait_until_epoch "$diagnostic_deadline" test -s "$internal" || { echo "smoke diagnostic deadline exceeded within shared 12s budget" >&2; exit 1; }
pid_was_running=false; pid_exists "$app_pid" && pid_was_running=true
after="$(frontmost_bundle_id)"
[[ -n "$after" ]] || { echo "frontmost application probe unavailable after launch" >&2; exit 1; }

exit_deadline=$work_deadline_epoch
wait_until_epoch "$exit_deadline" bash -c '! kill -0 "$1" 2>/dev/null' _ "$app_pid" || { echo "accessory controlled exit exceeded shared 12s budget" >&2; exit 1; }
wait "$app_pid" || { echo "accessory 自身退出状态失败" >&2; exit 1; }
app_pid=""
scan_owned
stop_observer
run_cleanup
summary="$(SMOKE_SCANNER_TARGET="$run_id" node "$scanner" summary "$observed")"

INTERNAL_PATH="$internal" BEFORE="$before" AFTER="$after" EXPECTED_PRESENCE="$expected_presence" \
PID_WAS_RUNNING="$pid_was_running" EXECUTABLE_REAL="$executable_real" BUNDLE_REAL="$bundle_real" SUMMARY="$summary" CLEANUP_RESULT="$cleanup_result" \
node --input-type=module >"$report_payload" <<'NODE'
import { readFile } from "node:fs/promises";
import { evaluateForeground } from "./scripts/lib/accessory-smoke-report.mjs";
const internal = JSON.parse(await readFile(process.env.INTERNAL_PATH, "utf8"));
const owned = JSON.parse(process.env.SUMMARY);
const cleanup = JSON.parse(process.env.CLEANUP_RESULT);
const report = {
  pidExistedAfterLaunch: process.env.PID_WAS_RUNNING === "true",
  executableRealPathWithinBundle: process.env.EXECUTABLE_REAL.startsWith(`${process.env.BUNDLE_REAL}/Contents/MacOS/`),
  didNotStealFocus: evaluateForeground(process.env.BEFORE, process.env.AFTER),
  activationPolicy: internal.activationPolicy,
  window: internal.window,
  statusItemCount: internal.statusItemCount,
  menuItemCount: internal.menuItemCount,
  ...owned,
  exitedThroughControlledPath: internal.exitedThroughControlledPath,
  workDeadlineSeconds: 9,
  finalCleanupDeadlineSeconds: 12,
  cleanupBestEffortAfterDeadline: cleanup.bestEffortAfterDeadline,
  cleanupTermCount: cleanup.termCount ?? null,
  cleanupKillCount: cleanup.killCount ?? null,
  expectedCodexPresence: process.env.EXPECTED_PRESENCE
};
process.stdout.write(JSON.stringify(report));
NODE
SMOKE_ARTIFACTS_DIRECTORY="$repo_root/artifacts" SMOKE_REPORT_DESTINATION="$report" node "$report_writer" <"$report_payload"

node --input-type=module - "$report" <<'NODE'
import { readFile } from "node:fs/promises";
const report = JSON.parse(await readFile(process.argv[2], "utf8"));
const failures = [];
if (!report.pidExistedAfterLaunch || !report.executableRealPathWithinBundle) failures.push("launch ownership evidence invalid");
if (!report.didNotStealFocus || report.activationPolicy !== "accessory") failures.push("activation evidence invalid");
if (report.window.isKey || report.window.isMain || report.window.level !== 3) failures.push("window activation evidence invalid");
if (report.expectedCodexPresence === "present" && !report.window.isVisible) failures.push("present smoke window was hidden");
if (report.expectedCodexPresence === "absent" && report.window.isVisible) failures.push("absent smoke window was visible");
if (report.statusItemCount < 1 || report.menuItemCount !== 6) failures.push("status menu incomplete");
if (report.exitedThroughControlledPath !== true) failures.push("controlled exit was not reported by the app");
if (report.cleanupBestEffortAfterDeadline !== false) failures.push("cleanup missed the reserved operational budget");
if (report.expectedCodexPresence === "present" && (report.observedOwnedProcessCount < 2 || report.observedOwnedChildProcessCount < 1)) failures.push("present smoke child process evidence invalid");
if (report.expectedCodexPresence === "absent" && report.observedOwnedChildProcessCount !== 0) failures.push("absent smoke unexpectedly created a child process");
if (report.residualOwnedProcessCount !== 0) failures.push("marker-owned residual process evidence invalid");
if (failures.length) throw new Error(failures.join("; "));
NODE

(( $(now_epoch) <= deadline_epoch )) || { echo "smoke exceeded shared 12s total deadline" >&2; exit 1; }
smoke_succeeded=true
echo "$report"
