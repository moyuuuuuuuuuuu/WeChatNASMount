#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/dist"
app="$build_root/.stage.noindex/WeChat NAS Mount.app"

cd "$project_root"
swift build -c release

if [[ -e "$app" ]]; then
  [[ ! -L "$app" ]] || { echo "Refusing symlink staging bundle"; exit 1; }
  mkdir -p "$build_root/archives"
  previous="$build_root/archives/WeChat-NAS-Mount-previous-$(date +%Y%m%d%H%M%S).zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$previous"
  unzip -tqq "$previous"
  rm -rf -- "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/WeChatNASMount" "$app/Contents/MacOS/WeChatNASMount"
cp "$project_root/Support/Info.plist" "$app/Contents/Info.plist"
iconset="$build_root/.stage.noindex/AppIcon.iconset"
swift "$project_root/scripts/make-icon.swift" "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$build_root/WeChat-NAS-Mount-macOS-arm64.zip"
echo "$app"
