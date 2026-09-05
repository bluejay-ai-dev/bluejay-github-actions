// Bluejay AI, through the UI: ask it to build something, then check the records exist.
//
//   BJAI_TOKEN=.. node bluejay-ai.mjs <frontend_url>
//
// Exit: 0 ok | 1 regression | 3 fixture or prerequisite missing | 5 amber, it never built it
//
// The assertion is the database, not the transcript. Whether the model phrased its reply
// well is evals' problem; whether a customer's words reached MCP and created rows is this.
import { loggedInContext, die, need } from "./session.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
const TOKEN = process.env.BJAI_TOKEN ?? `bjai-${Date.now()}`;
if (!BASE) die("usage: bluejay-ai.mjs <frontend_url>", 3);
const API = need("SUITE_API_URL").replace(/\/$/, "");
const KEY = need("TEST_SUITE_BLUEJAY_API_KEY");

const E_FAIL = 1, E_AMBER = 5;
const DEADLINE_MS = Number(process.env.BJAI_DEADLINE_MS ?? 300_000);

const api = (path, init = {}) =>
  fetch(`${API}${path}`, { ...init, headers: { "X-API-Key": KEY, "Content-Type": "application/json" } });

const agents = async () =>
  api("/v1/all-agents").then(r => (r.ok ? r.json() : [])).catch(() => []);
const simsFor = async id =>
  api(`/v1/get-simulations-by-agent/${id}`).then(r => (r.ok ? r.json() : {})).catch(() => ({}));

const { browser, ctx } = await loggedInContext(BASE);
const page = await ctx.newPage();
page.setDefaultTimeout(45_000);

let agentId = null;
const cleanup = async () => {
  if (agentId) {
    const s = await simsFor(agentId);
    for (const sim of s.simulations ?? s ?? []) {
      if (sim?.id) await api(`/v1/simulation/${sim.id}`, { method: "DELETE" }).catch(() => {});
    }
    await api(`/v1/agent/${agentId}`, { method: "DELETE" }).catch(() => {});
  }
};
const fail = async (m, code = E_FAIL) => {
  await page.screenshot({ path: "/tmp/suite-bluejay-ai-fail.png" }).catch(() => {});
  await browser.close().catch(() => {});
  await cleanup();
  console.error(`FAIL ${m}`);
  console.error(`  url=${page.url().slice(0, 140)} shot=/tmp/suite-bluejay-ai-fail.png`);
  process.exit(code);
};

await page.goto(`${BASE}/bluejay-ai`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url().includes("/auth/")) await fail("bounced to login, session cookie rejected", 3);

// A first visit puts a welcome tour over everything, and it swallows pointer events, so
// nothing on the page is clickable until it is gone. A real user dismisses it too.
for (let i = 0; i < 12; i++) {
  const modal = page.locator("div.fixed.inset-0").first();
  if (!(await modal.count())) break;
  await page.keyboard.press("Escape").catch(() => {});
  await page.waitForTimeout(400);
  if (!(await page.locator("div.fixed.inset-0").count())) break;
  const next = modal.getByRole("button", { name: /next|done|finish|get started|skip/i }).first();
  if (await next.count()) { await next.click({ force: true }).catch(() => {}); }
  else { await modal.locator("button").first().click({ force: true }).catch(() => {}); }
  await page.waitForTimeout(600);
}
if (await page.locator("div.fixed.inset-0").count())
  await fail("a modal is covering the assistant and would not dismiss");

// tiptap in some states, a plain textarea in others.
const editor = page.locator(".ProseMirror").first();
const textarea = page.getByPlaceholder(/Ask Bluejay/i).first();
const useEditor = await editor.isVisible().catch(() => false);
if (!useEditor && !(await textarea.isVisible().catch(() => false)))
  await fail("composer never rendered on /bluejay-ai");

const prompt =
  `Create an agent called "${TOKEN}" with the contact email test@getbluejay.ai. ` +
  `Then create two simulations on that agent, named "${TOKEN}-a" and "${TOKEN}-b". ` +
  `Do not run them. Just create them and tell me when it is done.`;

// Focus rather than click. A wrapper around the composer intercepts pointer events, so
// clicking retries until it times out even though the editor is visible and enabled.
if (useEditor) {
  await editor.evaluate(el => el.focus());
  await page.keyboard.insertText(prompt);
} else {
  await textarea.fill(prompt);
}

const send = page.locator('[data-tour-id="chat-send"]').first();
if (!(await send.isEnabled().catch(() => false))) await fail("send button never became enabled");
await send.click();

// Poll the API, not the transcript. The assistant streams, retries and rephrases; the rows
// either exist or they do not.
const end = Date.now() + DEADLINE_MS;
let sims = [];
while (Date.now() < end) {
  const found = (await agents()).find(a => a?.name === TOKEN);
  if (found) {
    agentId = found.id;
    const s = await simsFor(agentId);
    sims = (s.simulations ?? s ?? []).filter(x => (x?.name ?? "").startsWith(TOKEN));
    if (sims.length >= 2) break;
  }
  await page.waitForTimeout(5000);
}

const replied = (await page.locator("body").innerText().catch(() => "")).length > 0
  && !(await page.locator("text=/something went wrong|failed to load/i").first().isVisible().catch(() => false));
if (!replied) await fail("the assistant page fell over while working");

if (!agentId) {
  await browser.close().catch(() => {});
  console.error(`AMBER bluejay-ai: replied but never created agent "${TOKEN}".`);
  console.error(`  If this repeats, check MCP_SERVER_URL is publicly reachable: Anthropic`);
  console.error(`  fetches it itself, and a dead tunnel leaves the model with no tools.`);
  process.exit(E_AMBER);
}
if (sims.length < 2) {
  await browser.close().catch(() => {});
  await cleanup();
  console.error(`AMBER bluejay-ai: created the agent but only ${sims.length} of 2 simulations`);
  process.exit(E_AMBER);
}

await browser.close().catch(() => {});
await cleanup();
console.log(`ok bluejay-ai: agent ${agentId} and ${sims.length} simulations created through the UI, then removed`);
