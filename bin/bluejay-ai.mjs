// Bluejay AI: the composer, the attachment path, and the MCP round trip it writes through.
//
//   BJAI_DH_1=.. BJAI_DH_2=.. BJAI_AGENT_ID=.. BJAI_TOKEN=.. node bluejay-ai.mjs <frontend_url>
//
// Exit: 0 ok | 1 regression | 3 fixture missing | 4 chat not configured | 5 amber, no tool call
//
// Asserts plumbing, never answer quality; suite.sh reads the database afterwards.
// The attachment is not the carrier for the values written: extraction takes 2-15 minutes
// and proves nothing more about the upload path than `complete` returning does.
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loggedInContext, die } from "./session.mjs";
import { installChatTap } from "./chat-tap.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
const DH1 = process.env.BJAI_DH_1;
const DH2 = process.env.BJAI_DH_2;
const AGENT = process.env.BJAI_AGENT_ID;
const TOKEN = process.env.BJAI_TOKEN;
if (!BASE || !DH1 || !DH2 || !AGENT || !TOKEN)
  die("usage: bluejay-ai.mjs <frontend_url>, with BJAI_DH_1, BJAI_DH_2, BJAI_AGENT_ID, BJAI_TOKEN", 3);

const E_FAIL = 1, E_CONFIG = 4, E_AMBER = 5;
const DEADLINE_MS = Number(process.env.BJAI_DEADLINE_MS ?? 240_000);

// The composer only accepts .pdf/.doc/.docx/.csv/.xlsx.
const csv = join(tmpdir(), `bluejay-ai-${TOKEN}.csv`);
writeFileSync(csv,
  "name,persona,note\n" +
  `${TOKEN}-1,"Calm and brief","gate fixture, safe to change"\n` +
  `${TOKEN}-2,"Impatient and terse","gate fixture, safe to change"\n`);

const { browser, ctx } = await loggedInContext(BASE);

await installChatTap(ctx);

const page = await ctx.newPage();
page.setDefaultTimeout(45_000);

const shot = "/tmp/suite-bluejay-ai-fail.png";
const fail = async (m, code = E_FAIL) => {
  await page.screenshot({ path: shot }).catch(() => {});
  const s = await page.evaluate(() => window.__bjai ?? {}).catch(() => ({}));
  await browser.close();
  console.error(`FAIL ${m}`);
  console.error(`  url=${(page.url() ?? "").slice(0, 140)} shot=${shot}`);
  console.error(`  chat=${JSON.stringify(s.chat ?? [])} uploads=${JSON.stringify(s.uploads ?? [])}`);
  console.error(`  blocks=${(s.blocks ?? []).join(",") || "none"} tools=${(s.tools ?? []).join(",") || "none"}`);
  for (const b of (s.bodies ?? []).slice(0, 2)) console.error(`  body: ${b.slice(0, 300)}`);
  for (const e of (s.toolErrors ?? []).slice(0, 3)) console.error(`  tool error: ${e}`);
  process.exit(code);
};

await page.goto(`${BASE}/bluejay-ai`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url().includes("/auth/")) await fail("bounced to login, session cookie rejected", 3);

// tiptap in some states, a plain textarea in others.
const editor = page.locator(".ProseMirror").first();
const textarea = page.getByPlaceholder(/Ask Bluejay/i).first();
const useEditor = await editor.isVisible().catch(() => false);
if (!useEditor && !(await textarea.isVisible().catch(() => false)))
  await fail("composer never rendered on /bluejay-ai");

// The input is hidden behind a paperclip button; setting it is what a click does anyway.
const fileInput = page.locator('input[type="file"]').first();
if ((await fileInput.count()) === 0) await fail("no file input on the composer, attachments are gone");
await fileInput.setInputFiles(csv);

// Wait on presign/PUT/complete, not on the attachment chip, which is cosmetic.
const uploadOk = await page
  .waitForFunction(() => {
    const u = window.__bjai?.uploads ?? [];
    return u.some((x) => /upload/.test(x.url)) && u.some((x) => /complete/.test(x.url));
  }, null, { timeout: 90_000 })
  .then(() => true)
  .catch(() => false);

const up = await page.evaluate(() => window.__bjai?.uploads ?? []);
const badUpload = up.find((x) => x.status >= 400);
if (badUpload) {
  // 401/403 is the fixture user losing access, not the product breaking.
  const code = [401, 403].includes(badUpload.status) ? 3 : E_FAIL;
  await fail(`chat file ${badUpload.url} -> ${badUpload.status}`, code);
}
if (!uploadOk) await fail(`attachment never completed: ${JSON.stringify(up)}`);

// Ids are named explicitly: this gates whether a tool call lands, not whether the model guesses.
const prompt =
  `Use your Bluejay tools to make these exact changes, then stop. ` +
  `1) Update digital human ${DH1}: set its name to "${TOKEN}-1". ` +
  `2) Update digital human ${DH2}: set its name to "${TOKEN}-2". ` +
  `3) Update agent ${AGENT}: set its keyterms to exactly ["${TOKEN}"]. ` +
  `The attached CSV is context for a release gate. Do not ask me to confirm, just make the three changes.`;

if (useEditor) { await editor.click(); await page.keyboard.type(prompt, { delay: 0 }); }
else { await textarea.click(); await textarea.fill(prompt); }

const send = page.locator('[data-tour-id="chat-send"]').first();
if (!(await send.isEnabled().catch(() => false))) await fail("send button never became enabled");
await send.click();

const opened = await page
  .waitForFunction(() => (window.__bjai?.chat ?? []).length > 0, null, { timeout: 60_000 })
  .then(() => true).catch(() => false);
if (!opened) await fail("the composer never called /api/chat");

const chat = await page.evaluate(() => window.__bjai.chat);
const bad = chat.find((c) => c.status >= 400);
if (bad) {
  const bodies = await page.evaluate(() => window.__bjai.bodies ?? []);
  const text = bodies.join(" ");
  // No MCP URLs wired is the environment being wrong, not the code.
  if (/MCP_SERVER_URL|DOCS_MCP_SERVER_URL/.test(text))
    await fail(`chat route is not configured for MCP: ${text.slice(0, 200)}`, E_CONFIG);
  await fail(`/api/chat -> ${bad.status}`);
}

// Whichever lands first: a tool call already proves what this part exists to prove.
await page
  .waitForFunction(() => window.__bjai?.done === true || (window.__bjai?.tools ?? []).length > 0,
    null, { timeout: DEADLINE_MS })
  .catch(() => {});
if (await page.evaluate(() => (window.__bjai?.tools ?? []).length > 0 && !window.__bjai.done))
  await page.waitForFunction(() => window.__bjai?.done === true, null, { timeout: 90_000 }).catch(() => {});

const s = await page.evaluate(() => window.__bjai);

// is_error means the MCP server refused us: bad token, unreachable, or gone. All regressions.
if (s.toolErrors.length) await fail(`MCP tool returned an error: ${s.toolErrors[0]}`);
if (!s.events.length) await fail("the chat stream produced no events");

await browser.close();

if (!s.tools.length) {
  // Nothing broke, the model just did not call a tool. Amber retries once.
  console.error(`AMBER bluejay-ai: stream ran (${s.events.length} events, blocks: ` +
    `${s.blocks.join(",") || "none"}) but no MCP tool was called`);
  process.exit(E_AMBER);
}
// Lets suite.sh tell "never tried" (amber) from "said it wrote, nothing changed" (red).
writeFileSync("/tmp/suite.bjai.env", `BJAI_TOOLS='${s.tools.join(",").replace(/'/g, "")}'\n`);
console.log(`ok bluejay-ai: attachment uploaded, ${s.events.length} stream events, ` +
  `tools called: ${s.tools.join(", ")}`);
