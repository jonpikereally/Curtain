#!/bin/zsh
# Install Curtain to /Applications and launch it. Run from Terminal.app: apps can't run from
# inside Dropbox, and Claude's sandbox can't write to /Applications.
set -e
cd "$(dirname "$0")"
APP=/Applications/Curtain.app
pkill -x Curtain 2>/dev/null || true
sleep 0.5
rm -rf ~/Applications/Curtain.app   # earlier installs went here
rm -rf "$APP"
ditto --norsrc Curtain.app "$APP"
# Sign outside Dropbox, after stripping xattrs, so the sync client can't slip any in between.
xattr -cr "$APP"
codesign --force --sign - "$APP"
# Ad-hoc signing changes identity on every rebuild, which silently voids the old grants.
tccutil reset Accessibility com.jonpike.curtain >/dev/null 2>&1 || true
tccutil reset ScreenCapture com.jonpike.curtain >/dev/null 2>&1 || true
echo "Installed $APP"

# --- Stream Deck plugin ---------------------------------------------------------
PLUGINS="$HOME/Library/Application Support/com.elgato.StreamDeck/Plugins"
PLUGIN="com.jonpike.curtaindeck.sdPlugin"
if [[ -d "$PLUGINS/$PLUGIN" ]] && diff -rq "streamdeck/$PLUGIN" "$PLUGINS/$PLUGIN" >/dev/null 2>&1; then
  echo "Stream Deck plugin unchanged, left as is."
elif [[ -d "$PLUGINS" && -d "streamdeck/$PLUGIN" ]]; then
  if pgrep -xq "Stream Deck"; then
    echo "Quitting Stream Deck to swap the plugin…"
    osascript -e 'quit app id "com.elgato.StreamDeck"' || true
    for i in {1..20}; do pgrep -xq "Stream Deck" || break; sleep 0.5; done
  fi
  rm -rf "$PLUGINS/$PLUGIN"
  ditto "streamdeck/$PLUGIN" "$PLUGINS/$PLUGIN"
  echo "Installed $PLUGINS/$PLUGIN"
  open -b com.elgato.StreamDeck || echo "Start Stream Deck manually to load the plugin."
else
  echo "Stream Deck (or the streamdeck/ folder) not found — skipped the plugin."
fi

open "$APP"
echo
echo "Curtain launched. Grant Accessibility when asked (System Settings > Privacy & Security),"
echo "and optionally Screen Recording for real icons in the popout."
echo "Then right-click the ‹ arrow > Settings > turn on 'Open Curtain at login'."
echo "In Stream Deck, the actions are under the “Curtain” category."
