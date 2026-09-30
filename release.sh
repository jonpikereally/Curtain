#!/bin/zsh
# Build a release: universal (Apple Silicon + Intel) app with an installer, written to
# updates/Curtain.zip + updates/latest.json. Committing and pushing updates/ ships it:
# every installed copy's "Check for Updates" reads latest.json from this repo on GitHub.
#   1. bump CFBundleVersion/CFBundleShortVersionString in Info.plist
#   2. UPDATE_NOTES="What changed" ./release.sh
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
CACHE="${TMPDIR:-/tmp}/curtain-modcache"
mkdir -p "$CACHE" "$CACHE-x86"
echo "Building arm64…"
swiftc -O -target arm64-apple-macos14 -module-cache-path "$CACHE" \
  -o "$CACHE/Curtain-arm64" -parse-as-library Curtain.swift Updater.swift
echo "Building x86_64…"
swiftc -O -target x86_64-apple-macos14 -module-cache-path "$CACHE-x86" \
  -o "$CACHE/Curtain-x86_64" -parse-as-library Curtain.swift Updater.swift

DIST="$CACHE/dist"
rm -rf "$DIST"
APP="$DIST/Curtain/Curtain.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Curtain" "$CACHE/Curtain-arm64" "$CACHE/Curtain-x86_64"
cp Info.plist "$APP/Contents/Info.plist"
cp Curtain.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

cat > "$DIST/Curtain/Install Curtain.command" <<'INSTALL'
#!/bin/bash
# Curtain installer: copies the app to /Applications and launches it.
cd "$(dirname "$0")"
echo "Installing Curtain…"
pkill -x Curtain 2>/dev/null; sleep 0.5
rm -rf /Applications/Curtain.app
ditto --norsrc Curtain.app /Applications/Curtain.app
# Clear the download quarantine and re-sign locally so macOS trusts it on this Mac.
xattr -dr com.apple.quarantine /Applications/Curtain.app 2>/dev/null
codesign --force --sign - /Applications/Curtain.app
tccutil reset Accessibility com.jonpike.curtain >/dev/null 2>&1
tccutil reset ScreenCapture com.jonpike.curtain >/dev/null 2>&1
open /Applications/Curtain.app
echo
echo "Done! Look for the ‹ arrow in your menu bar."
echo "Grant Accessibility when asked (System Settings → Privacy & Security → Accessibility)."
echo "Optional: Screen Recording, so the popout shows the real icons."
INSTALL
chmod +x "$DIST/Curtain/Install Curtain.command"

cat > "$DIST/Curtain/README.txt" <<README
Curtain v$VERSION — a menu bar hider for macOS (14+)
https://github.com/jonpikereally/Curtain

INSTALL
1. Double-click "Install Curtain.command".
   If macOS blocks it: right-click it, choose Open, then Open again.
2. Grant Accessibility when prompted (System Settings → Privacy & Security →
   Accessibility). Curtain needs it to read the menu bar.
3. Optional: Screen Recording, so the popout shows the real icons.

USE
• Click the ‹ arrow to see hidden icons (popout or on the bar; choose in Settings).
  Option-click does the other one.
• Right-click the arrow for Settings, Check for Updates and Quit.
• Show all icons, then hold ⌘ and drag an icon across the ≡ divider to hide or keep it.

PRIVACY
Everything stays on your Mac. The only thing Curtain fetches from the internet is a
small version file from the GitHub repo above, to see whether an update exists.
README

mkdir -p updates
(cd "$DIST" && ditto -c -k --norsrc --noextattr --noqtn --keepParent Curtain "$OLDPWD/updates/Curtain.zip.tmp")
mv -f updates/Curtain.zip.tmp updates/Curtain.zip
# Manifest last, so a checking app never sees it pointing at a half-written zip.
/usr/bin/python3 -c 'import json,sys; print(json.dumps({"version": sys.argv[1], "url": "Curtain.zip", "notes": sys.argv[2]}))' \
  "$VERSION" "${UPDATE_NOTES:-}" > updates/latest.json.tmp
mv -f updates/latest.json.tmp updates/latest.json

./build.sh >/dev/null
echo "Release v$VERSION written to updates/. Ship it by committing and pushing updates/."
