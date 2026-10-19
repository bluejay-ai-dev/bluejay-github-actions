// Sign up and onboarding, end to end, with a brand new account every run.
//
//   node signup.mjs <frontend_url>
//
// Exit: 0 | 1 regression | 3 fixture or prerequisite missing
//
// Turnstile gates the public form's submit, and no headless browser can solve it, so the account
// comes from the admin API and the browser takes over at the email confirm link: the same
// /auth/confirm a real signup lands on, which creates the org, workspace and membership. The
// captcha itself is watched every minute by watchdog-service.
//
// The address is watchdog-signup+<ts>@example.com. allowed_signups needs one row,
// watchdog-signup@example.com, or the signup gate blocks every run after the first. @example.com
// skips billing, the newsletter, the welcome email, Slack and Clay.
//
// The run is recorded. A pass deletes the video; a fail keeps it in the artifact for the page.
import { chromium } from "playwright";
import { mkdirSync, rmSync } from "node:fs";
import { die, need } from "./session.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
if (!BASE) die("usage: signup.mjs <frontend_url>", 3);
const SUPA = need("SUITE_SUPABASE_URL").replace(/\/$/, "");
const SERVICE = need("SUITE_SUPABASE_SERVICE_KEY");
const admin = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" };

const email = `watchdog-signup+${Date.now()}@example.com`;
const VIDEO = "/tmp/suite-signup-video";
rmSync(VIDEO, { recursive: true, force: true });
mkdirSync(VIDEO, { recursive: true });

let userId = null, browser = null, page = null, failed = null;

async function rest(method, path) {
  const r = await fetch(`${SUPA}/rest/v1/${path}`, { method, headers: { ...admin, Prefer: "return=minimal" } });
  if (!r.ok) throw new Error(`${method} ${path.split("?")[0]}: ${r.status} ${(await r.text()).slice(0, 160)}`);
  return method === "GET" ? r.json() : null;
}

// Org delete is blocked by agents, api_keys and a few billing and support tables, so those go
// first; the org then cascades through members, workspaces, dashboards, metrics and phone rows.
async function cleanup() {
  if (!userId) return;
  const memberships = await rest("GET", `organization_memberships?user_id=eq.${userId}&select=organization_id`);
  for (const { organization_id: org } of memberships) {
    for (const t of ["agents", "api_keys", "invites", "monthly_billing_usage", "support_access_sessions",
                     "bluejay_bluebic_jobs", "workflows_v2"]) {
      await rest("DELETE", `${t}?organization_id=eq.${org}`);
    }
    await rest("DELETE", `organizations?id=eq.${org}`);
  }
  await rest("DELETE", `users?id=eq.${userId}`);
  const r = await fetch(`${SUPA}/auth/v1/admin/users/${userId}`, { method: "DELETE", headers: admin });
  if (!r.ok) throw new Error(`delete login: ${r.status}`);
}

async function finish() {
  const video = page && await page.video()?.path().catch(() => null);
  if (browser) await browser.close().catch(() => {});
  let cleanupError = null;
  try { await cleanup(); } catch (e) { cleanupError = e.message; }
  if (failed || cleanupError) {
    if (page) console.error(`  url=${page.url().slice(0, 140)}`);
    if (video) console.error(`  video=${video}`);
    console.error(`FAIL signup ${failed ?? `cleanup left rows behind: ${cleanupError}`}`);
    process.exit(1);
  }
  rmSync(VIDEO, { recursive: true, force: true });
  console.log(`ok signup: form renders with captcha, new account onboarded to ${landed}, cleaned up`);
  process.exit(0);
}
const fail = async (m) => { failed = m; await finish(); };
let landed = "/";

browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1600, height: 1000 }, recordVideo: { dir: VIDEO } });
page = await ctx.newPage();
page.setDefaultTimeout(45_000);

// 1. the public form renders, with its captcha
await page.goto(`${BASE}/auth/sign-up`, { waitUntil: "domcontentloaded" }).catch(() => {});
await page.waitForTimeout(6000);
const form = await page.locator("body").innerText().catch(() => "");
if (!/sign ?up|create.*account|get started/i.test(form)) await fail("sign up page did not render a sign up form");
if ((await page.locator('input[name="cf-turnstile-response"]').count()) === 0)
  await fail("sign up form rendered with no Turnstile widget");

// 2. a new account, then the confirm link a real signup clicks
const gen = await fetch(`${SUPA}/auth/v1/admin/generate_link`, {
  method: "POST", headers: admin,
  body: JSON.stringify({ type: "signup", email, password: `Watchdog-${crypto.randomUUID()}`,
                         data: { first_name: "Watchdog", last_name: "Signup" } }),
}).then((r) => r.json());
const token = gen.hashed_token ?? gen.properties?.hashed_token;
userId = gen.id ?? gen.user?.id ?? null;
if (!token) await fail(`could not create the account: ${JSON.stringify(gen).slice(0, 160)}`);

await page.goto(`${BASE}/auth/confirm?token_hash=${token}&type=signup&next=/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(10000);
const url = page.url();
if (url.includes("/access-denied")) await fail("signup was denied: is watchdog-signup@example.com in allowed_signups?");
if (url.includes("/auth/")) await fail(`new account bounced to ${url.replace(BASE, "")}`);
const text = await page.locator("body").innerText().catch(() => "");
for (const bad of [/something went wrong/i, /internal server error/i, /application error/i, /unhandled/i])
  if (bad.test(text)) await fail(`new account landed on an error page: ${text.slice(0, 160).replace(/\s+/g, " ")}`);

// 3. onboarding finished: the org exists and a reload settles in the app, not a login loop
const orgs = await rest("GET", `organization_memberships?user_id=eq.${userId}&select=organization_id`).catch(() => []);
if (!orgs.length) await fail("account confirmed but no organization was created");
landed = url.replace(BASE, "") || "/";
await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url().includes("/auth/")) await fail(`new account settles nowhere: ${landed}, then ${page.url().replace(BASE, "")}`);

await finish();
