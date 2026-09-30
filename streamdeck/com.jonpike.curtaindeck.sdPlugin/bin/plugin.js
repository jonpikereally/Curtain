// Curtain Deck — Stream Deck plugin for the Curtain menu bar hider.
// Drives the app's loopback control server (127.0.0.1:8767) and mirrors its state onto the keys.

const WebSocket = require("ws");
const { execFile } = require("child_process");

const BASE = "http://127.0.0.1:8767";
const BUNDLE_ID = "com.jonpike.curtain";
const POLL_MS = 1000;

// --- Stream Deck registration -------------------------------------------------

const argv = {};
for (let i = 2; i < process.argv.length; i += 2) {
  argv[process.argv[i].replace(/^-+/, "")] = process.argv[i + 1];
}
const ws = new WebSocket(`ws://127.0.0.1:${argv.port}`);
const send = (obj) => ws.readyState === WebSocket.OPEN && ws.send(JSON.stringify(obj));
ws.on("open", () => send({ event: argv.registerEvent, uuid: argv.pluginUUID }));
const log = (msg) => send({ event: "logMessage", payload: { message: `[curtaindeck] ${msg}` } });

// --- App control surface ------------------------------------------------------

let app = null;                 // last state from the app, or null when unreachable
let launching = false;
const contexts = new Map();
const inspectors = new Map();   // context -> action, for property inspectors that are open

async function call(path, body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 2500);
  try {
    const res = await fetch(BASE + path, {
      method: body ? "POST" : "GET",
      headers: body ? { "Content-Type": "application/json" } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    app = await res.json();
    launching = false;
    return app;
  } catch {
    app = null;
    return null;
  } finally {
    clearTimeout(timer);
  }
}

function launchApp() {
  if (launching) return;
  launching = true;
  execFile("open", ["-b", BUNDLE_ID], (err) => {
    if (err) { log(`launch failed: ${err.message}`); launching = false; }
  });
  setTimeout(() => { launching = false; }, 8000);
}

setInterval(() => {
  if (contexts.size) call("/state").then(() => { renderAll(); pushItems(); });
}, POLL_MS);

// --- Rendering ----------------------------------------------------------------

const offline = () => (launching ? "starting…" : "no app");

/// Item names on a key: the app part only ("Dropbox", not "Dropbox – Up to date"), wrapped to two lines.
function shortName(label) {
  const name = String(label || "").split(" – ")[0].trim();
  if (name.length <= 9) return name;
  const words = name.split(/\s+/);
  if (words.length > 1) return `${words[0].slice(0, 9)}\n${words.slice(1).join(" ").slice(0, 9)}`;
  return `${name.slice(0, 8)}…`;
}

const itemFor = (key) => app?.items?.find((i) => i.key === key);

function renderAll() {
  for (const [context, entry] of contexts) render(context, entry);
}

function render(context, entry) {
  const { action, settings } = entry;
  const short = action.split(".").pop();
  const setState = (on) => send({ event: "setState", context, payload: { state: on ? 1 : 0 } });
  const setTitle = (title) => send({ event: "setTitle", context, payload: { title } });

  switch (short) {
    case "expand":
      setState(!!app && app.expanded);
      setTitle(app ? "" : offline());
      break;
    case "popout":
      if (!app) setTitle(offline());
      else setTitle(settings.showCount === false ? "" : `${app.hiddenCount} hidden`);
      break;
    case "open":
    case "visible": {
      const item = itemFor(settings.key);
      if (short === "visible") setState(!!item && item.visible);
      if (!app) setTitle(offline());
      else if (!settings.key) setTitle("pick\nan item");
      else if (settings.showName === false) setTitle(item ? "" : "not\nrunning");
      else setTitle(item ? shortName(item.label) : `${shortName(settings.label || settings.key)}\n(off)`);
      break;
    }
    case "arrange":
    case "settings":
      setTitle(app ? "" : offline());
      break;
  }
}

/// Gives open property inspectors the current item list for their item picker.
function pushItems() {
  for (const [context, action] of inspectors) {
    send({
      event: "sendToPropertyInspector",
      context,
      action,
      payload: { running: !!app, items: app?.items ?? [] },
    });
  }
}

// --- Input --------------------------------------------------------------------

async function act(context, path, body) {
  const result = await call(path, body ?? {});
  if (!result) {
    // Curtain isn't running: launch it and let the poll pick it up.
    launchApp();
    send({ event: "showAlert", context });
  } else if (result.error) {
    log(`${path}: ${result.error}`);
    send({ event: "showAlert", context });
  }
  renderAll();
}

ws.on("message", async (raw) => {
  let msg;
  try { msg = JSON.parse(raw); } catch { return; }
  const { event, context, action, payload = {} } = msg;
  const settings = payload.settings || {};
  const short = (action || "").split(".").pop();

  switch (event) {
    case "willAppear":
      contexts.set(context, { action, settings });
      await call("/state");
      renderAll();
      break;

    case "willDisappear":
      contexts.delete(context);
      inspectors.delete(context);
      break;

    case "didReceiveSettings": {
      const entry = contexts.get(context);
      if (entry) entry.settings = settings;
      renderAll();
      break;
    }

    case "propertyInspectorDidAppear":
      inspectors.set(context, action);
      await call("/state");
      pushItems();
      break;

    case "propertyInspectorDidDisappear":
      inspectors.delete(context);
      break;

    case "keyDown": {
      const mode = settings.mode || "toggle";
      switch (short) {
        case "expand":
          await act(context, "/expand", {
            ...(mode === "toggle" ? { toggle: true } : { on: mode === "show" }),
            ...(settings.stay ? { stay: true } : {}),
          });
          break;
        case "popout":
          await act(context, "/popout");
          break;
        case "open":
          if (!settings.key) { send({ event: "showAlert", context }); break; }
          await act(context, "/open", { key: settings.key });
          break;
        case "visible":
          if (!settings.key) { send({ event: "showAlert", context }); break; }
          await act(context, "/visible", { key: settings.key, ...(mode === "toggle" ? {} : { on: mode === "show" }) });
          break;
        case "arrange":
          await act(context, settings.mode === "rescan" ? "/rescan" : "/arrange");
          break;
        case "settings":
          await act(context, "/settings");
          break;
      }
      break;
    }
  }
});

ws.on("error", (e) => log(`socket error: ${e.message}`));
