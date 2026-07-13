import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const read = (path) => readFile(new URL(`../${path}`, import.meta.url), "utf8");

test("accessory bundle metadata is a UIElement app with the fixed identity", async () => {
  const plist = await read("config/accessory-Info.plist");
  assert.match(plist, /<key>CFBundleIdentifier<\/key>\s*<string>com\.ppfruit\.codex-quota<\/string>/);
  assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>CodexUsageAccessory<\/string>/);
  assert.match(plist, /<key>CFBundleDisplayName<\/key>\s*<string>Codex Quota<\/string>/);
  assert.match(plist, /<key>CFBundleIconFile<\/key>\s*<string>CodexQuota<\/string>/);
  assert.match(plist, /<key>LSUIElement<\/key>\s*<true\/>/);
  assert.match(plist, /<key>LSMinimumSystemVersion<\/key>\s*<string>26\.0<\/string>/);
  assert.doesNotMatch(plist, /Accessibility|ScreenCapture|Screen Recording|Network|entitlement/i);
});

test("build script owns one deterministic bundle and rejects symlink escape", async () => {
  const script = await read("scripts/build-accessory-app.sh");
  assert.match(script, /swift build -c release/);
  assert.match(script, /build_root="\$artifacts_dir\/build"/);
  assert.match(script, /bundle="\$build_root\/Codex Quota\.app"/);
  assert.match(script, /CodexQuota-AppIcon-1024\.png/);
  assert.match(script, /iconutil -c icns/);
  assert.match(script, /realpath/);
  assert.match(script, /-L/);
  assert.match(script, /codesign --force --deep --sign -/);
  assert.match(script, /codesign --verify --deep --strict/);
  assert.match(script, /plutil/);
});

test("smoke is PID-owned, deadline bounded, and emits redacted JSON", async () => {
  const script = await read("scripts/run-accessory-smoke.sh");
  assert.match(script, /Contents\/MacOS\/CodexUsageAccessory/);
  assert.doesNotMatch(script, /\bopen\b/);
  assert.match(script, /CODEX_ACCESSORY_SMOKE_DIAGNOSTIC_PATH/);
  assert.match(script, /CODEX_ACCESSORY_SMOKE_EXIT_AFTER_SECONDS/);
  assert.match(script, /record-pid/);
  assert.match(script, /cleanup-records/);
  assert.match(script, /CODEX_USAGE_SMOKE_RUN_ID/);
  assert.match(script, /deadline/i);
  assert.match(script, /accessory-smoke-report\.mjs/);
  assert.doesNotMatch(script, /frontmostBundleIDBefore|frontmostBundleIDAfter/);
});

test("package exposes accessory build and verification entry points", async () => {
  const packageJSON = JSON.parse(await read("package.json"));
  assert.equal(packageJSON.scripts["build:accessory"], "bash scripts/build-accessory-app.sh");
  assert.equal(packageJSON.scripts["package:unsigned"], "bash scripts/package-unsigned-release.sh");
  assert.equal(packageJSON.scripts["verify:accessory"], "npm run build:accessory && npm run smoke:accessory");
  assert.equal(packageJSON.scripts["smoke:accessory"], "SMOKE_EXPECT_CODEX_PRESENCE=present bash scripts/run-accessory-smoke.sh && SMOKE_EXPECT_CODEX_PRESENCE=absent bash scripts/run-accessory-smoke.sh");
});

test("unsigned preview packaging is explicit, checks identity, and emits a checksum", async () => {
  const script = await read("scripts/package-unsigned-release.sh");
  assert.match(script, /Signature=adhoc/);
  assert.match(script, /Mach-O.*arm64/);
  assert.match(script, /ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent/);
  assert.match(script, /unzip -Z1/);
  assert.match(script, /spctl --assess --type execute/);
  assert.match(script, /shasum -a 256/);
  assert.match(script, /-preview\.1-macos-arm64\.zip/);
  assert.doesNotMatch(script, /xattr|spctl --master-disable/);
});

test("public product identity is consistent across persistence and app-server metadata", async () => {
  const overlay = await read("Sources/CodexUsageUI/UsageOverlayView.swift");
  const client = await read("Sources/CodexUsageCore/AppServerClient.swift");
  assert.match(overlay, /storageKey = "codex-quota\.bubble-appearance-preset"/);
  assert.match(client, /"name": \.string\("codex-quota"\)/);
  assert.doesNotMatch(`${overlay}\n${client}`, /codex-glance|codex-usage-accessory/);
});
