// Stand-in for Curtain's control server on 127.0.0.1:8767, for testing the plugin without the app.
const http = require("http");
const s = { running: true, expanded: false, popout: false, trusted: true, screenRecording: true, status: "",
  items: [
    { key: "Dropbox", label: "Dropbox – Up to date", visible: false, movable: true },
    { key: "com.apple.menuextra.wifi", label: "Wi-Fi", visible: true, movable: true },
    { key: "AlDente", label: "AlDente", visible: false, movable: false },
  ] };
const calls = [];
const state = (error) => ({ ...s, hiddenCount: s.items.filter((i) => !i.visible).length, ...(error ? { error } : {}) });
function handle(route, j) {
  calls.push([route, j]);
  const item = s.items.find((i) => i.key === j.key);
  switch (route) {
    case "/state": return state();
    case "/expand": s.expanded = j.toggle ? !s.expanded : (j.on ?? !s.expanded); return state();
    case "/popout": s.popout = !s.popout; return state();
    case "/open": return item ? state() : state("unknown item");
    case "/visible": if (!item) return state("unknown item"); item.visible = j.on ?? !item.visible; return state();
    case "/arrange": case "/rescan": case "/settings": return state();
    default: return state(`unknown route ${route}`);
  }
}
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    let j = {}; try { j = JSON.parse(body || "{}"); } catch {}
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(handle(req.url.split("?")[0], j)));
  });
});
module.exports = { server, calls, s };
if (require.main === module) server.listen(8767, "127.0.0.1", () => console.log("fake Curtain on 8767"));
