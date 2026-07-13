#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
artifacts_dir="$repo_root/artifacts"
build_root="$artifacts_dir/build"
bundle="$build_root/Codex Quota.app"
plist="$repo_root/config/accessory-Info.plist"
icon_source="$repo_root/assets/branding/CodexQuota-AppIcon-1024.png"

[[ ! -L "$artifacts_dir" && ! -L "$build_root" ]] || {
  echo "拒绝清理符号链接构建目录" >&2
  exit 1
}
mkdir -p "$artifacts_dir"
[[ "$(realpath "$artifacts_dir")" == "$repo_root/artifacts" ]] || {
  echo "构建目录逃逸工作区" >&2
  exit 1
}

rm -rf "$build_root"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

cd "$repo_root"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
executable="$bin_dir/CodexUsageAccessory"
[[ -f "$executable" && ! -L "$executable" ]] || {
  echo "release executable 缺失或为符号链接" >&2
  exit 1
}
executable_real="$(realpath "$executable")"
case "$executable_real" in
  "$repo_root/.build/"*) ;;
  *) echo "release executable 逃逸 .build" >&2; exit 1 ;;
esac

install -m 755 "$executable_real" "$bundle/Contents/MacOS/CodexUsageAccessory"
install -m 644 "$plist" "$bundle/Contents/Info.plist"

[[ -f "$icon_source" && ! -L "$icon_source" ]] || {
  echo "应用图标缺失或为符号链接" >&2
  exit 1
}
iconset="$build_root/CodexQuota.iconset"
mkdir -p "$iconset"
for specification in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size="${specification%% *}"
  name="${specification#* }"
  sips -z "$size" "$size" "$icon_source" --out "$iconset/$name" >/dev/null
done
iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/CodexQuota.icns"
rm -rf "$iconset"

test "$(plutil -extract LSUIElement raw -o - "$bundle/Contents/Info.plist")" = "true"
test "$(plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist")" = "com.ppfruit.codex-quota"
test "$(plutil -extract CFBundleExecutable raw -o - "$bundle/Contents/Info.plist")" = "CodexUsageAccessory"
test "$(plutil -extract CFBundleDisplayName raw -o - "$bundle/Contents/Info.plist")" = "Codex Quota"
test "$(plutil -extract CFBundleIconFile raw -o - "$bundle/Contents/Info.plist")" = "CodexQuota"
test -f "$bundle/Contents/Resources/CodexQuota.icns"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist")" = "0.1.1"
test "$(plutil -extract CFBundleVersion raw -o - "$bundle/Contents/Info.plist")" = "2"
test "$(plutil -extract LSMinimumSystemVersion raw -o - "$bundle/Contents/Info.plist")" = "26.0"

codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
echo "$bundle"
