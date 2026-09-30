// Minimal Property Inspector plumbing — no CDN, no build step.
// Any <input>/<select>/<textarea> with a name attribute is bound to the setting of that name.
// A <select data-items> is filled with Curtain's menu bar items, sent over by the plugin.
let socket, uuid, settings = {};
let lastItems = "";

window.connectElgatoStreamDeckSocket = (port, inUUID, registerEvent, info, actionInfo) => {
  uuid = inUUID;
  try { settings = JSON.parse(actionInfo).payload.settings || {}; } catch { settings = {}; }
  socket = new WebSocket(`ws://127.0.0.1:${port}`);
  socket.onopen = () => { socket.send(JSON.stringify({ event: registerEvent, uuid })); hydrate(); };
  socket.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.event === "didReceiveSettings") { settings = msg.payload.settings || {}; hydrate(); }
    if (msg.event === "sendToPropertyInspector") fillItems(msg.payload);
  };
};

function save() {
  socket?.send(JSON.stringify({ event: "setSettings", context: uuid, payload: settings }));
}

function coerce(el) {
  return el.type === "number" || el.type === "range" ? Number(el.value) : el.value;
}

function hydrate() {
  for (const el of document.querySelectorAll("[name]")) {
    const v = settings[el.name];
    if (v !== undefined && v !== null) {
      if (el.type === "checkbox") el.checked = !!v; else el.value = v;
    } else if (el.dataset.default !== undefined) {
      if (el.type === "checkbox") el.checked = el.dataset.default === "true"; else el.value = el.dataset.default;
      settings[el.name] = el.type === "checkbox" ? el.checked : coerce(el);
    }
  }
  reveal();
  save();
}

/// Rows tagged data-show-when="mode=set" only appear when that setting has that value.
function reveal() {
  for (const row of document.querySelectorAll("[data-show-when]")) {
    const [k, v] = row.dataset.showWhen.split("=");
    row.style.display = String(settings[k]) === v ? "" : "none";
  }
}

/// Rebuilds the item picker only when the list actually changed, so the poll never yanks an open menu.
/// The saved item stays selectable even while its app isn't running.
function fillItems({ running, items }) {
  const sig = JSON.stringify([running, items.map((i) => [i.key, i.label])]);
  if (sig === lastItems) return;
  lastItems = sig;
  for (const sel of document.querySelectorAll("select[data-items]")) {
    sel.innerHTML = "";
    const add = (value, text) => { const o = document.createElement("option"); o.value = value; o.textContent = text; sel.appendChild(o); };
    add("", running ? "Choose an item…" : "Curtain isn't running");
    for (const i of items) add(i.key, i.label + (i.movable === false && sel.dataset.items === "movable" ? " (can't move)" : ""));
    if (settings.key && !items.some((i) => i.key === settings.key)) add(settings.key, `${settings.label || settings.key} (not running)`);
    sel.value = settings.key || "";
  }
}

document.addEventListener("input", (e) => {
  const el = e.target;
  if (!el.name) return;
  settings[el.name] = el.type === "checkbox" ? el.checked : coerce(el);
  if (el.dataset.items !== undefined) settings.label = (el.selectedOptions[0]?.textContent || "").replace(/ \((not running|can't move)\)$/, "");
  reveal();
  save();
});
