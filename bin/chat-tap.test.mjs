// Proves the chat tap against a stub, because getting it wrong fails open: an
// instrumentation bug and a model that called nothing produce the same empty arrays.
//
//   node chat-tap.test.mjs
import { createServer } from "node:http";
import { chromium } from "playwright";
import { installChatTap } from "./chat-tap.mjs";

const ev = (o) => JSON.stringify(o) + "\n";
const STREAM = [
  ev({ type: "message_start" }),
  ev({ type: "content_block_start", content_block: { type: "thinking" } }),
  // split across chunks on purpose: the parser has to buffer a partial line
  ev({ type: "content_block_start", content_block: { type: "mcp_tool_use", name: "update_digital_human" } }),
  ev({ type: "content_block_start", content_block: { type: "mcp_tool_result", is_error: false } }),
  ev({ type: "content_block_start", content_block: { type: "mcp_tool_use", name: "update_agent" } }),
  ev({ type: "content_block_start", content_block: { type: "mcp_tool_result", is_error: true, content: "unauthorized" } }),
  ev({ type: "message_stop" }),
].join("");

let mode = "ok";
const server = createServer(async (req, res) => {
  const url = req.url ?? "";
  if (url.startsWith("/api/chat-files/")) {
    res.writeHead(url.includes("boom") ? 500 : 200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ ok: true }));
  }
  if (url.startsWith("/api/chat")) {
    if (mode === "500") {
      res.writeHead(500, { "content-type": "application/json" });
      return res.end(JSON.stringify({ error: "MCP_SERVER_URL or DOCS_MCP_SERVER_URL is not configured" }));
    }
    res.writeHead(200, { "content-type": "application/x-ndjson" });
    // byte-by-byte-ish, so lines land split across reads
    for (let i = 0; i < STREAM.length; i += 7) {
      res.write(STREAM.slice(i, i + 7));
      await new Promise((r) => setTimeout(r, 1));
    }
    return res.end();
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end("<!doctype html><title>stub</title><body>stub</body>");
});
await new Promise((r) => server.listen(0, r));
const BASE = `http://127.0.0.1:${server.address().port}`;

let failed = 0;
const chk = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { console.error(`chat-tap: ${name} -> ${g}, want ${w}`); failed = 1; }
};

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext();
await installChatTap(ctx);
const page = await ctx.newPage();
await page.goto(BASE);

// happy path: a stream split across chunk boundaries still parses
await page.evaluate((b) => fetch(`${b}/api/chat`, { method: "POST" }).then((r) => r.text()), BASE);
await page.waitForFunction(() => window.__bjai?.done === true, null, { timeout: 15000 });
const s = await page.evaluate(() => window.__bjai);
chk("events", s.events.length, 7);
chk("tools", s.tools, ["update_digital_human", "update_agent"]);
chk("tool errors seen", s.toolErrors.length, 1);
chk("clean result not flagged", /unauthorized/.test(s.toolErrors[0] ?? ""), true);
chk("done", s.done, true);

// the page still gets its own copy: teeing must not consume the body
const seen = await page.evaluate((b) =>
  fetch(`${b}/api/chat`, { method: "POST" }).then((r) => r.text()).then((t) => t.split("\n").filter(Boolean).length), BASE);
chk("consumer still reads the stream", seen, 7);

// uploads are recorded, and a failing one keeps its body for the error line
await page.evaluate((b) => fetch(`${b}/api/chat-files/upload`, { method: "POST" }), BASE);
await page.evaluate((b) => fetch(`${b}/api/chat-files/boom`, { method: "POST" }), BASE);
const u = await page.evaluate(() => window.__bjai.uploads);
chk("upload recorded", u.some((x) => x.url === "/api/chat-files/upload" && x.status === 200), true);
chk("failing upload recorded", u.some((x) => x.status === 500), true);

// a 500 from the chat route keeps its body so the config case can be told apart
mode = "500";
const page2 = await ctx.newPage();
await page2.goto(BASE);
await page2.evaluate((b) => fetch(`${b}/api/chat`, { method: "POST" }).then((r) => r.text()), BASE);
const s2 = await page2.evaluate(() => window.__bjai);
chk("500 recorded", s2.chat[0]?.status, 500);
chk("config error body kept", /MCP_SERVER_URL/.test((s2.bodies ?? []).join(" ")), true);

await browser.close();
server.close();
if (failed) { console.error("FAIL chat-tap"); process.exit(1); }
console.log("ok   chat-tap  stream parsing, tee, uploads, 500 body");
