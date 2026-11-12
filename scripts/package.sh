#!/bin/zsh
# Release-builds the production app and the dev app and packages each separately into release/
# as a drag-to-install DMG (app + Applications shortcut). Refuses to package if RoomCore tests fail.
# Build folders end in .noindex so Spotlight doesn't list build products next to the installed app.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ RoomCore tests"
(cd Packages/RoomCore && swift test 2>&1 | tail -1)

xcodegen generate >/dev/null
mkdir -p release build

for scheme in LANListen LANListenDev; do
  echo "▶ Release build: $scheme"
  xcodebuild -project LANListen.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/ReleaseDerivedData.noindex build > "build/release-$scheme.log" 2>&1 \
    || { echo "✘ build failed, see build/release-$scheme.log"; exit 1; }

  app="build/ReleaseDerivedData.noindex/Build/Products/Release/$scheme.app"
  codesign --verify --deep --strict "$app"
  plist="$app/Contents/Info.plist"
  version="$(plutil -extract CFBundleShortVersionString raw "$plist")-$(plutil -extract CFBundleVersion raw "$plist")"
  display="$(plutil -extract CFBundleDisplayName raw "$plist")"
  name=$([[ $scheme == LANListenDev ]] && echo "LANListen-Dev" || echo "LANListen")

  # ponytail: plain Finder window (no background art / icon layout); add a styled .DS_Store if it matters.
  stage="build/dmg.noindex/$scheme"
  rm -rf "$stage" && mkdir -p "$stage"
  ditto "$app" "$stage/$display.app"
  ln -s /Applications "$stage/Applications"
  dmg="release/$name-$version.dmg"
  rm -f "$dmg"
  hdiutil create -volname "$display" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  rm -rf "$stage"
  echo "✔ $dmg ($(du -h "$dmg" | cut -f1))"
done
