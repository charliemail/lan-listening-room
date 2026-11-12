#!/bin/zsh
# Release-builds the production app and the dev app and packages each separately into release/
# as a drag-to-install DMG (create-dmg: arrow background, app + Applications shortcut).
# Refuses to package if RoomCore tests fail. On success release/ keeps only the DMGs just built.
# Build folders end in .noindex so Spotlight doesn't list build products next to the installed app.
# Needs: brew install create-dmg; Finder automation permission (create-dmg lays out the window via AppleScript).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ RoomCore tests"
(cd Packages/RoomCore && swift test 2>&1 | tail -1)

xcodegen generate >/dev/null
mkdir -p release build

bg=build/dmg-background.tiff
swiftc -O scripts/make-dmg-background.swift -o build/make-dmg-background
build/make-dmg-background build/dmg-bg.png 1
build/make-dmg-background build/dmg-bg@2x.png 2
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out "$bg" >/dev/null 2>&1
built=()

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

  stage="build/dmg.noindex/$scheme"
  rm -rf "$stage" && mkdir -p "$stage"
  ditto "$app" "$stage/$display.app"
  dmg="release/$name-$version.dmg"
  rm -f "$dmg"
  # Icon positions must match scripts/make-dmg-background.swift.
  create-dmg --volname "$display" --background "$bg" --window-pos 200 120 --window-size 640 400 \
    --icon-size 128 --text-size 13 --icon "$display.app" 160 180 --hide-extension "$display.app" \
    --app-drop-link 480 180 --filesystem HFS+ --format UDZO --hdiutil-quiet "$dmg" "$stage" >/dev/null
  rm -rf "$stage"
  built+=("$dmg")
  echo "✔ $dmg ($(du -h "$dmg" | cut -f1))"
done

for f in release/*(N); do
  (( ${built[(Ie)$f]} )) || { rm -f "$f"; echo "  removed old $f"; }
done
