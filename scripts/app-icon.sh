#!/bin/zsh
# Regenerates the App icon from design/app-icon-source.* (any opaque square artwork on a black
# background): cuts the corners transparent, places it on the macOS 824-on-1024 grid, writes all sizes.
set -euo pipefail
cd "$(dirname "$0")/.."

src=${1:-$(ls design/app-icon-source.* | head -1)}
set_dir=LANListen/Assets.xcassets/AppIcon.appiconset
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

swiftc -O scripts/make-app-icon.swift -o "$tmp/make-app-icon"
"$tmp/make-app-icon" "$src" "$tmp/icon_1024.png"

mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  sips -z $size $size "$tmp/icon_1024.png" --out "$set_dir/icon_${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$tmp/icon_1024.png" --out "$set_dir/icon_${size}@2x.png" >/dev/null
done
echo "✔ $set_dir"
