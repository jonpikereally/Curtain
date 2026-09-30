// Fake Stream Deck: hosts the websocket the plugin registers on, sends it willAppear/keyDown events,
// and checks what the plugin sends back. Uses tools/fake-curtain.js unless --live (real Curtain running).
const path = require("path");
const { spawn } = require("child_process");
const WebSocket = require(path.join(__dirname, "../com.jonpike.curtaindeck.sdPlugin/bin/node_modules/ws"));
const live = process.argv.includes("--live");
const fake = live ? null : require("./fake-curtain");

let failures = 0;
const check = (label, cond) => { console.log((cond ? "PASS " : "FAIL ") + label); if (!cond) failures++; };
const A = (s) => `com.jonpike.curtaindeck.${s}`;

function run() {
  const wss = new WebSocket.Server({ host: "127.0.0.1", port: 0 });
  wss.on("listening", () => {
    const plugin = spawn("node", [path.join(__dirname, "../com.jonpike.curtaindeck.sdPlugin/bin/plugin.js"),
      "-port", String(wss.address().port), "-pluginUUID", "TESTUUID", "-registerEvent", "registerPlugin", "-info", "{}"], { stdio: "inherit" });

    wss.on("connection", async (ws) => {
      const inbox = [];
      ws.on("message", (raw) => inbox.push(JSON.parse(raw)));
      const send = (o) => ws.send(JSON.stringify(o));
      const wait = (ms) => new Promise((r) => setTimeout(r, ms));
      const last = (event, context) => [...inbox].reverse().find((m) => m.event === event && (!context || m.context === context));
      const key = (context, action, settings) => send({ event: "keyDown", context, action: A(action), payload: { settings } });
      const appear = (context, action, settings = {}) => send({ event: "willAppear", context, action: A(action), payload: { settings, controller: "Keypad" } });

      await wait(300);
      check("plugin registered", inbox.some((m) => m.event === "registerPlugin" && m.uuid === "TESTUUID"));

      appear("c_exp", "expand");
      await wait(400);
      const before = last("setState", "c_exp")?.payload.state;
      check("expand key reflects state", before === 0 || before === 1);
      key("c_exp", "expand", {});
      await wait(400);
      check("expand toggles", last("setState", "c_exp")?.payload.state === 1 - before);
      key("c_exp", "expand", { mode: "hide" });
      await wait(400);
      check("expand mode=hide → off", last("setState", "c_exp")?.payload.state === 0);

      appear("c_pop", "popout", { showCount: true });
      await wait(400);
      check("popout title shows hidden count", /^\d+ hidden$/.test(last("setTitle", "c_pop")?.payload.title || ""));

      appear("c_none", "open", {});
      await wait(400);
      check("open key without item asks to pick", last("setTitle", "c_none")?.payload.title === "pick\nan item");
      key("c_none", "open", {});
      await wait(200);
      check("pressing unconfigured key alerts", !!last("showAlert", "c_none"));

      send({ event: "propertyInspectorDidAppear", context: "c_none", action: A("open"), payload: {} });
      await wait(400);
      const pi = last("sendToPropertyInspector", "c_none");
      check("PI gets item list", Array.isArray(pi?.payload.items) && pi.payload.items.length > 0);

      if (!live) {
        appear("c_open", "open", { key: "Dropbox", label: "Dropbox – Up to date" });
        await wait(400);
        check("open key titled with short app name", last("setTitle", "c_open")?.payload.title === "Dropbox");
        key("c_open", "open", { key: "Dropbox" });
        await wait(300);
        check("open sends the item key", fake.calls.some(([r, j]) => r === "/open" && j.key === "Dropbox"));

        appear("c_vis", "visible", { key: "Dropbox" });
        await wait(400);
        check("visible key off while hidden", last("setState", "c_vis")?.payload.state === 0);
        key("c_vis", "visible", { key: "Dropbox" });
        await wait(400);
        check("visible toggle → on", last("setState", "c_vis")?.payload.state === 1);
        key("c_vis", "visible", { key: "Dropbox", mode: "hide" });
        await wait(400);
        check("visible mode=hide → off", last("setState", "c_vis")?.payload.state === 0);

        appear("c_gone", "open", { key: "Bartender", label: "Bartender 5" });
        await wait(400);
        check("missing app shows (off)", last("setTitle", "c_gone")?.payload.title === "Bartender\n(off)" || (last("setTitle", "c_gone")?.payload.title || "").endsWith("(off)"));

        key("c_arr", "arrange", { mode: "rescan" });
        key("c_arr", "arrange", {});
        key("c_set", "settings", {});
        await wait(400);
        const routes = fake.calls.map(([r]) => r);
        check("rescan, arrange, settings routes hit", ["/rescan", "/arrange", "/settings"].every((r) => routes.includes(r)));

        fake.server.close();
        appear("c_off", "settings", {});
        await wait(1500);
        check("app gone → key says no app / starting", /no app|starting/.test(last("setTitle", "c_off")?.payload.title || ""));
      }

      console.log(failures ? `${failures} FAILED` : "ALL PASS");
      plugin.kill();
      process.exit(failures ? 1 : 0);
    });
  });
}

if (fake) fake.server.listen(8767, "127.0.0.1", run); else run();
