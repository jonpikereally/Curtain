#!/bin/zsh
# Regenerate the plugin's PNG icons (144 + @2x) from the SVG sources, and the plugin icon from the app icon.
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/curtain-modcache"
BIN="${TMPDIR:-/tmp}/curtain-rasterize"
mkdir -p "$CACHE"
swiftc -module-cache-path "$CACHE" -o "$BIN" tools/rasterize.swift 2>&1 | grep -v xcrun_db || true
IMGS=com.jonpike.curtaindeck.sdPlugin/imgs
for f in $IMGS/*.svg; do
  "$BIN" "$f" "${f%.svg}"
done
"$BIN" ../icon_1024.png $IMGS/pluginIcon
echo "Rendered $(ls $IMGS/*.png | wc -l | tr -d ' ') PNGs"
