# Curtain Deck

Stream Deck plugin for Curtain, the menu bar hider. Adds a **Curtain** category. Keys mirror the app's live state and show "no app" when Curtain isn't running (press to launch it).

| Action | Key |
|---|---|
| Show All Icons | Reveal every hidden icon (like option-clicking the arrow). Toggle, or force show / hide; optional "stay open". Lit while shown. |
| Hidden Icons Popout | Open / close the popout under the arrow. Title shows how many icons are hidden. |
| Open Menu Item | Open one item's menu (Wi-Fi, Dropbox…) whether it's hidden or not. Pick the item from a live list. |
| Keep on Bar | Switch one item between staying on the bar and hiding behind the arrow. Lit while on the bar. |
| Arrange | Arrange now, or rescan the bar. |
| Curtain Settings | Open the Settings window. |

## How it works

Curtain (1.12+) runs a loopback-only HTTP server on `127.0.0.1:8767` (`ControlServer` at the end of `Curtain.swift`). `bin/plugin.js` is plain Node (Stream Deck supplies Node 20; `ws` is vendored in `bin/node_modules`, no build step). It polls `GET /state` once a second and posts `/expand`, `/popout`, `/open`, `/visible`, `/arrange`, `/rescan`, `/settings`. Property inspectors in `ui/` are static HTML bound to settings by `ui/pi.js`; the item pickers are filled by the plugin via `sendToPropertyInspector`.

Icons are SVG in `imgs/`; `render-icons.sh` rasterises them (and the app icon, for the plugin icon) to PNG + @2x.

## Install

`../install.sh` installs the app and this plugin together.

## Test

```bash
node tools/test-plugin.js          # against tools/fake-curtain.js
node tools/test-plugin.js --live   # against the real, running Curtain
```
