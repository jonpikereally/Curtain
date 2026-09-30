#!/bin/zsh
# Rebuild Curtain.app from Curtain.swift. Command Line Tools only, no Xcode.
# Curtain.icns is prebuilt from icon.swift (see README); iconutil/sips don't run in every sandbox.
set -e
cd "$(dirname "$0")"
CACHE="${TMPDIR:-/tmp}/curtain-modcache"
mkdir -p "$CACHE" Curtain.app/Contents/MacOS Curtain.app/Contents/Resources
cp Info.plist Curtain.app/Contents/
cp Curtain.icns Curtain.app/Contents/Resources/
swiftc -O -module-cache-path "$CACHE" -parse-as-library Curtain.swift Updater.swift -o Curtain.app/Contents/MacOS/Curtain
xattr -cr Curtain.app
codesign --force --sign - Curtain.app
echo "Built Curtain.app $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
