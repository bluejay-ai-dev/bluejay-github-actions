// Drives bluejay-ai.mjs end to end against a stub of the frontend and Supabase, to prove
// the four outcomes map to the four exit codes. Without this nothing exercises the
// classification until it runs against a real deployment, where a wrong code either
// blocks a good batch or waves a broken one through.
//
//   node bluejay-ai.test.mjs
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const ev = (o) => JSON.stringify(o) + "\n";

const streams = {
  ok: [
    ev({ type: "message_start" }),
    ev({ type: "content_block_start", content_block: { type: "mcp_tool_use", name: "update_digital_human" } }),
    ev({ type: "content_block_start", content_block: { type: "mcp_tool_result", is_error: false } }),
    ev({ type: "message_stop" }),
  ].join(""),
  notools: [
    ev({ type: "message_start" }),
    ev({ type: "content_block_start", content_block: { type: "text" } }),
    ev({ type: "message_stop" }),
  ].join(""),
  toolerror: [
    ev({ type: "message_start" }),
    ev({ type: "content_block_start", content_block: { type: "mcp_tool_use", name: "update_agent" } }),
    ev({ type: "content_block_start", content_block: { type: "mcp_tool_result", is_error: true, content: "unauthorized" } }),
    ev({ type: "message_stop" }),
  ].join(""),
};

let mode = "ok";
const PAGE = `<!doctype html><title>stub</title><body>
<div class="ProseMirror" contenteditable="true"></div>
<input type="file" accept=".pdf,.doc,.docx,.csv,.xlsx" multiple style="display:none">
<button data-tour-id="chat-send">send</button>
<script>
document.querySelector('input[type=file]').addEventListener('change', async () => {
  await fetch('/api/chat-files/upload', { method: 'POST' });
  await fetch('/api/chat-files/complete', { method: 'POST' });
});
document.querySelector('[data-tour-id=chat-send]').addEventListener('click', async () => {
  const r = await fetch('/api/chat', { method: 'POST' });
  if (r.body) { const rd = r.body.getReader(); for(;;){ const {done} = await rd.read(); if (done) break; } }
});
</script></body>`;

const server = createServer(async (req, res) => {
  const url = (req.url ?? "").split("?")[0];
  const json = (code, o) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(o)); };
  if (url === "/auth/v1/admin/generate_link") return json(200, { email_otp: "123456" });
  if (url === "/auth/v1/verify")
    return json(200, { access_token: "a.b.c", refresh_token: "r", expires_in: 3600, token_type: "bearer", user: { id: "u" } });
  if (url === "/auth/v1/user") return json(200, { id: "u" });
  if (url.startsWith("/api/chat-files/")) return json(200, { ok: true });
  if (url === "/api/chat") {
    if (mode === "config500")
      return json(500, { error: "MCP_SERVER_URL or DOCS_MCP_SERVER_URL is not configured" });
    res.writeHead(200, { "content-type": "application/x-ndjson" });
    const body = streams[mode] ?? streams.ok;
    for (let i = 0; i < body.length; i += 9) { res.write(body.slice(i, i + 9)); await new Promise((r) => setTimeout(r, 1)); }
    return res.end();
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(PAGE);
});
await new Promise((r) => server.listen(0, r));
const BASE = `http://127.0.0.1:${server.address().port}`;

const run = () => new Promise((resolve) => {
  const p = spawn(process.execPath, [join(HERE, "bluejay-ai.mjs"), BASE], {
    env: { ...process.env,
      SUITE_SUPABASE_URL: BASE, SUITE_SUPABASE_ANON_KEY: "anon",
      SUITE_SUPABASE_SERVICE_KEY: "service", SUITE_USER_EMAIL: "gate@example.com",
      BJAI_DH_1: "1", BJAI_DH_2: "2", BJAI_AGENT_ID: "3", BJAI_TOKEN: "tok",
      BJAI_DEADLINE_MS: "20000" },
  });
  let out = "";
  p.stdout.on("data", (d) => (out += d));
  p.stderr.on("data", (d) => (out += d));
  p.on("close", (code) => resolve({ code, out }));
});

let failed = 0;
const chk = async (name, m, want) => {
  mode = m;
  const { code, out } = await run();
  if (code !== want) { console.error(`bluejay-ai: ${name} -> exit ${code}, want ${want}\n${out.split("\n").slice(0, 6).join("\n")}`); failed = 1; }
};

await chk("tool called and stream finished", "ok", 0);
await chk("no tool call is amber", "notools", 5);
await chk("MCP tool error is a regression", "toolerror", 1);
await chk("unconfigured chat route is config", "config500", 4);

// missing fixtures must be 3, never a regression
const bare = await new Promise((resolve) => {
  const p = spawn(process.execPath, [join(HERE, "bluejay-ai.mjs")], { env: { ...process.env, BJAI_DH_1: "" } });
  p.on("close", (code) => resolve(code));
});
if (bare !== 3) { console.error(`bluejay-ai: no args -> exit ${bare}, want 3`); failed = 1; }

server.close();
if (failed) { console.error("FAIL bluejay-ai"); process.exit(1); }
console.log("ok   bluejay-ai  exit codes for pass, amber, tool error, misconfig, no fixtures");
