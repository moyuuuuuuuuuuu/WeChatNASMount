#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/dist"
app="$build_root/WeChat NAS Mount.app"

cd "$project_root"
swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/WeChatNASMount" "$app/Contents/MacOS/WeChatNASMount"
cp "$project_root/Support/Info.plist" "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$build_root/WeChat-NAS-Mount-macOS-arm64.zip"
echo "$app"
