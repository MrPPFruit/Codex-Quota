#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
artifacts_dir="$repo_root/artifacts"
release_dir="$artifacts_dir/release"
bundle="$artifacts_dir/build/Codex Quota.app"

[[ ! -L "$artifacts_dir" && ! -L "$release_dir" ]] || {
  echo "拒绝使用符号链接发布目录" >&2
  exit 1
}

cd "$repo_root"
npm run build:accessory

version="$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist")"
package_version="$(node -p 'JSON.parse(require("fs").readFileSync("package.json", "utf8")).version')"
[[ "$version" == "$package_version" ]] || {
  echo "应用版本与 package.json 不一致" >&2
  exit 1
}

codesign --verify --deep --strict "$bundle"
signature="$(codesign -dv --verbose=4 "$bundle" 2>&1)"
architecture="$(file "$bundle/Contents/MacOS/CodexUsageAccessory")"
grep -q 'Signature=adhoc' <<< "$signature"
grep -q 'Mach-O.*arm64' <<< "$architecture"

rm -rf "$release_dir"
mkdir -p "$release_dir"
[[ "$(realpath "$release_dir")" == "$repo_root/artifacts/release" ]] || {
  echo "发布目录逃逸工作区" >&2
  exit 1
}

archive_name="Codex-Quota-v${version}-preview.1-macos-arm64.zip"
archive="$release_dir/$archive_name"
staging="$(mktemp -d "$release_dir/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

ditto -c -k --norsrc --noextattr --noacl --noqtn --keepParent "$bundle" "$staging/$archive_name"
mv "$staging/$archive_name" "$archive"

if unzip -Z1 "$archive" | grep -Eq '(^|/)\._|(^|/)__MACOSX(/|$)|\.DS_Store$'; then
  echo "发布包包含 AppleDouble 或 Finder 元数据" >&2
  exit 1
fi

verification_dir="$staging/verification"
mkdir -p "$verification_dir"
ditto -x -k --norsrc --noextattr --noacl --noqtn "$archive" "$verification_dir"
verified_bundle="$verification_dir/Codex Quota.app"
verified_executable="$verified_bundle/Contents/MacOS/CodexUsageAccessory"

[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$verified_bundle/Contents/Info.plist")" == "$version" ]]
[[ "$(plutil -extract CFBundleVersion raw -o - "$verified_bundle/Contents/Info.plist")" == "2" ]]
codesign --verify --deep --strict "$verified_bundle"
verified_signature="$(codesign -dv --verbose=4 "$verified_bundle" 2>&1)"
verified_architecture="$(file "$verified_executable")"
grep -q 'Signature=adhoc' <<< "$verified_signature"
grep -q 'Mach-O.*arm64' <<< "$verified_architecture"
if spctl --assess --type execute "$verified_bundle" >/dev/null 2>&1; then
  echo "未公证预览包不应通过 Gatekeeper 评估" >&2
  exit 1
fi

shasum -a 256 "$archive" | awk -v name="$archive_name" '{print $1 "  " name}' > "$staging/$archive_name.sha256"
mv "$staging/$archive_name.sha256" "$archive.sha256"

echo "$archive"
echo "$archive.sha256"
