#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
cd "$repo_dir"

version="${1:-${GIT_REVIEW_VERSION:-}}"
if [[ -z "$version" ]]; then version="$(< "${repo_dir}/VERSION")"; fi
version="${version#v}"

swift build -c release

app_name="Git Review"
app_dir=".build/${app_name}.app"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
iconset_dir=".build/AppIcon.iconset"

rm -rf "$app_dir" "$iconset_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp ".build/release/GitReview" "${macos_dir}/GitReview"
swift Tools/generate-app-icon.swift "$iconset_dir"
iconutil -c icns "$iconset_dir" -o "${resources_dir}/AppIcon.icns"

cat > "${contents_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>GitReview</string>
    <key>CFBundleIdentifier</key><string>local.git-review</string>
    <key>CFBundleName</key><string>Git Review</string>
    <key>CFBundleDisplayName</key><string>Git Review</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "Built ${app_dir}"
