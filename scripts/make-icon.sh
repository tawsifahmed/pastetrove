#!/bin/bash
# Regenerates Resources/AppIcon.icns and docs/images/icon.svg from BrandMark.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/make-icon" scripts/make-icon/main.swift Sources/PasteTrove/BrandMark.swift
"$TMP/make-icon" "$TMP/icon_1024.png" docs/images/icon.svg
mkdir -p "$TMP/AppIcon.iconset" docs/images
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/icon_1024.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/icon_1024.png" "${1:-/dev/null}" 2>/dev/null || true
echo "OK: Resources/AppIcon.icns, docs/images/icon.svg"
