// viewer-harness.cjs — render ReMynd's moment viewer in real Chrome the way an
// MCP Apps host does: fetch the ui:// resource and a real show_moment result
// from the server over stdio, load the viewer in a sandboxed iframe under the
// spec's default CSP, answer ui/initialize, send tool-input then tool-result,
// resize the iframe on size-changed, and screenshot the "chat".
//
//   node viewer-harness.cjs <outDir> <remynd-mcp binary>
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const OUT = process.argv[2];
const MCP = process.argv[3];
fs.mkdirSync(OUT, { recursive: true });

function startServer() {
  const p = spawn(MCP, [], { stdio: ["pipe", "pipe", "ignore"], env: { HOME: process.env.HOME, PATH: "/usr/bin:/bin" } });
  let buf = "";
  const waiters = new Map();
  p.stdout.on("data", (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      try {
        const o = JSON.parse(line);
        const w = waiters.get(o.id);
        if (w) { waiters.delete(o.id); w(o); }
      } catch (_) {}
    }
  });
  let id = 0;
  return {
    call(method, params) {
      const my = ++id;
      p.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: my, method, params }) + "\n");
      return new Promise((r) => waiters.set(my, r));
    },
    kill() { p.kill(); },
  };
}

(async () => {
  const s = startServer();
  const init = await s.call("initialize", {
    protocolVersion: "2025-06-18",
    capabilities: { extensions: { "io.modelcontextprotocol/ui": { mimeTypes: ["text/html;profile=mcp-app"] } } },
    clientInfo: { name: "viewer-harness", version: "1" },
  });
  console.log("server", JSON.stringify(init.result.serverInfo), "capabilities", JSON.stringify(init.result.capabilities));
  const tools = (await s.call("tools/list", {})).result.tools;
  const sm = tools.find((t) => t.name === "show_moment");
  const uri = sm._meta.ui.resourceUri;
  const read = (await s.call("resources/read", { uri })).result.contents[0];
  console.log("resource", uri, read.mimeType, read.text.length, "chars");

  const args = {
    moments: [
      { at: "2026-09-11 11:25:51", label: "Julian call: Boris walking him through the new settings" },
      { at: "2026-09-14 15:40:14", label: "Cascades Builder in Claude", app: "Chrome" },
    ],
  };
  const t0 = Date.now();
  const result = (await s.call("tools/call", { name: "show_moment", arguments: args })).result;
  const imgs = result.content.filter((b) => b.type === "image");
  console.log("show_moment", ((Date.now() - t0) / 1000).toFixed(1) + "s", "images", imgs.length,
    "frames", ((result.structuredContent || {}).frames || []).length,
    "payload", Math.round(JSON.stringify(result).length / 1024) + "KB");
  s.kill();

  const csp = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' data:; connect-src 'none';">`;
  const viewer = read.text.replace(/<head>/i, "<head>" + csp);

  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const cases = [["desktop-light", 760, "light"], ["desktop-dark", 760, "dark"], ["narrow", 420, "light"]];
  for (const [name, width, theme] of cases) {
    const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme: theme });
    page.on("console", (m) => { if (m.type() === "error") console.log(name, "console error:", m.text()); });
    page.on("pageerror", (e) => console.log(name, "page error:", e.message));
    const ink = theme === "dark" ? "#e8e6e1" : "#2b2a28";
    await page.setContent(`<!doctype html><html><body style="margin:0;padding:24px 16px;background:${theme === "dark" ? "#262624" : "#faf9f5"};font:15px/1.5 -apple-system,sans-serif;color:${ink}">
      <div style="max-width:720px;margin:0 auto">
        <div style="font-size:13px;opacity:.7;margin:0 0 10px">remynd · Show moment</div>
        <iframe id="v" sandbox="allow-scripts" style="width:100%;height:80px;border:0;display:block"></iframe>
        <p style="margin:14px 0 0">The most important thing you did last Friday was the call with Julian…</p>
      </div></body></html>`);
    const report = await page.evaluate(({ viewer, args, result, theme }) => new Promise((resolve) => {
      const iframe = document.getElementById("v");
      const log = [];
      const send = (o) => iframe.contentWindow.postMessage(Object.assign({ jsonrpc: "2.0" }, o), "*");
      window.addEventListener("message", (e) => {
        if (e.source !== iframe.contentWindow) return;
        const m = e.data;
        log.push(m.method ? m.method + (m.params && m.params.height ? "(" + m.params.height + ")" : "") : "response#" + m.id);
        if (m.method === "ui/initialize") {
          send({ id: m.id, result: { protocolVersion: "2026-01-26", hostInfo: { name: "harness", version: "1" },
            hostCapabilities: { serverTools: {} },
            hostContext: { theme, displayMode: "inline", availableDisplayModes: ["inline", "fullscreen"], platform: "desktop" } } });
        }
        if (m.method === "ui/notifications/initialized") {
          send({ method: "ui/notifications/tool-input", params: { arguments: args } });
          setTimeout(() => send({ method: "ui/notifications/tool-result", params: result }), 400);
        }
        if (m.method === "ui/notifications/size-changed" && m.params.height) iframe.style.height = m.params.height + "px";
      });
      iframe.srcdoc = viewer;
      setTimeout(() => {
        let imgs = [];
        try { imgs = [...iframe.contentDocument.querySelectorAll("img")].map((i) => [i.naturalWidth, i.clientWidth, i.clientHeight]); } catch (_) {}
        resolve({ log, iframeHeight: iframe.style.height, iframeWidth: iframe.clientWidth, imgs });
      }, 4500);
    }), { viewer, args, result, theme });
    console.log(name, JSON.stringify(report));
    await page.screenshot({ path: path.join(OUT, name + ".png"), fullPage: true });
    await page.close();
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
