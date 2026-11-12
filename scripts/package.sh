#!/bin/zsh
# Release-builds the production app and the dev app and zips each separately into release/.
# Refuses to package if the RoomCore tests fail.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ RoomCore tests"
(cd Packages/RoomCore && swift test 2>&1 | tail -1)

xcodegen generate >/dev/null
mkdir -p release build

for scheme in LANListen LANListenDev; do
  echo "▶ Release build: $scheme"
  xcodebuild -project LANListen.xcodeproj -scheme "$scheme" -configuration Release \
    -derivedDataPath build/ReleaseDerivedData build > "build/release-$scheme.log" 2>&1 \
    || { echo "✘ build failed, see build/release-$scheme.log"; exit 1; }

  app="build/ReleaseDerivedData/Build/Products/Release/$scheme.app"
  codesign --verify --deep --strict "$app"
  version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")-$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
  name=$([[ $scheme == LANListenDev ]] && echo "LANListen-Dev" || echo "LANListen")
  zip="release/$name-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  echo "✔ $zip ($(du -h "$zip" | cut -f1))"
done
