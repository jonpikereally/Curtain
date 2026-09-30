# Curtain

A small menu bar hider for macOS: a replacement for Bartender and Ice. Icons you don't need sit behind a `‹` arrow. Click it to show them in a popout (or on the bar itself), and click one to open its menu. It's one Swift file with no Xcode project and no dependencies.

Originally written by Chris (with Claude) for macOS 26; this fork runs on macOS 15 and adds the changes below.

## Using it

- **Click the arrow** to open the popout of hidden icons, or to show them on the menu bar. You choose which in Settings, and **Option-click** does the other.
- **Right-click the arrow** for Settings and Quit.
- **Drag icons in the popout** to reorder it.
- **Never move the mouse** (on by default): Curtain never drags icons or fakes clicks. You arrange the bar yourself by showing all icons and ⌘-dragging an icon left of the `≡` divider to hide it, or right of it to keep it. The Settings list follows what you do. Turn the setting off and Curtain drags icons into place itself when you flip a switch or press Arrange now, taking over the mouse for a moment each time.

## Build and install

```bash
./build.sh      # swiftc → Curtain.app, ad-hoc signed
./install.sh    # copies to /Applications, installs the Stream Deck plugin, launches
```

Requires the Command Line Tools. Run `install.sh` from Terminal.

### Updates

Curtain checks `updates/latest.json` in this repo shortly after launch and every 6 hours. When a newer version exists, the arrow gets a filled circle and the right-click menu shows **Install Update to vX…**. Installing downloads `updates/Curtain.zip`, quits Curtain, swaps the app in place and reopens it. **Update Source…** in the menu can point it at a different feed, such as a local file for testing.

To ship a release:

```bash
# 1. bump CFBundleVersion and CFBundleShortVersionString in Info.plist
UPDATE_NOTES="What changed" ./release.sh   # universal build → updates/Curtain.zip + updates/latest.json
# 2. commit and push, including updates/
```

`raw.githubusercontent.com` caches for about 5 minutes, so a fresh release can take a moment to show up. Update checks only work while the repo is public.

### Permissions

- **Accessibility** (required): reads and moves menu bar items.
- **Screen Recording** (optional): the popout shows the real icons instead of app icons.

The app is signed ad-hoc, so **every rebuild voids both grants** while System Settings still shows them on. `install.sh` resets them (`tccutil reset`), so re-enable both after each install, then quit and reopen Curtain. Signing with a real certificate would stop this.

### Icon

`Curtain.icns` is prebuilt. To regenerate it: `swiftc icon.swift -o mkicon && ./mkicon` writes `icon_1024.png`. Then build the iconset with `sips` and run `iconutil -c icns`.

## Changes from Chris's original

- **Multi-display item matching.** With two displays every status item has a window on each menu bar, and many items' Accessibility frames are just the 24pt button inside a 38pt window. Items are now matched to the window that contains them, which fixes items that showed "no menu bar window, cannot be moved".
- **Never move the mouse**, as described above. Nothing is dragged at launch or when new items appear.
- **The arrow stays leftmost** when Curtain arranges the bar (with the mouse setting off).
- **Click behaviour setting:** a plain click opens the popout or shows the bar, and Option-click does the other.
- **Screen capture prompts don't pile up** on macOS 15: one capture at a time, with a pause after a failure.
- **The Screen Recording button opens System Settings**, since macOS only shows its own prompt once.
- **A loopback control server** on `127.0.0.1:8767` for the Stream Deck plugin.

## Stream Deck

`streamdeck/` holds the **Curtain Deck** plugin: Show All Icons, Hidden Icons Popout, Open Menu Item, Keep on Bar, Arrange, and Settings. See [streamdeck/README.md](streamdeck/README.md).

## Debugging

```bash
defaults write com.jonpike.curtain DebugLog -bool true   # then read ~/Library/Logs/Curtain.log
```
