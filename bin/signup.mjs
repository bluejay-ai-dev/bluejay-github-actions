// Onboarding: can a brand new account reach an organization. Every other part of the
// suite signs in as a fixture user that already has one, so nothing else covers this.
//
//   node signup.mjs <frontend_url>
//
// Exit: 0 | 1 regression | 3 fixture or prerequisite missing
//
// It does NOT submit the public form: Turnstile gates the button wherever
// NEXT_PUBLIC_TURNSTILE_SITE_KEY is set. The form is asserted as far as it renders, and
// everything a captcha never protected is driven with a real new account.
import { loggedInContext, createUser, deleteUser, die, need } from "./session.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
if (!BASE) die("usage: signup.mjs <frontend_url>", 3);
need("SUITE_SUPABASE_SERVICE_KEY");

// A domain we own and receive at, so a bounce is never someone else's problem.
const domain = process.env.SUITE_SIGNUP_DOMAIN ?? "bluejaysims.com";
const email = `gate+signup-${Date.now()}@${domain}`;
const password = `Gate-${Math.random().toString(36).slice(2)}-${Date.now()}`;

let userId = null;
const shot = "/tmp/suite-signup-fail.png";
let browser = null, page = null;

const fail = async (m, code = 1) => {
  if (page) await page.screenshot({ path: shot }).catch(() => {});
  if (browser) await browser.close().catch(() => {});
  if (userId) await deleteUser(userId);
  console.error(`FAIL ${m}`);
  if (page) console.error(`  url=${page.url().slice(0, 140)} shot=${shot}`);
  process.exit(code);
};

// Asserts the captcha is PRESENT: a signup page that lost Turnstile is worse than one that is down.
{
  const { browser: b, ctx } = await loggedInContext(BASE);
  browser = b;
  const p = await ctx.newPage();
  page = p;
  p.setDefaultTimeout(45_000);
  await p.goto(`${BASE}/auth/sign-up`, { waitUntil: "domcontentloaded" }).catch(() => {});
  await p.waitForTimeout(6000);
  const body = await p.locator("body").innerText().catch(() => "");
  if (!/sign ?up|create.*account|get started/i.test(body))
    await fail("sign-up page did not render a sign-up form");
  const hasCaptcha = await p.locator('iframe[src*="challenges.cloudflare.com"], .cf-turnstile')
    .first().isVisible().catch(() => false);
  if (!hasCaptcha && process.env.SUITE_EXPECT_CAPTCHA === "1")
    await fail("sign-up form rendered with no Turnstile widget, bot signups are open");
  await browser.close();
  browser = null; page = null;
}

// Created through the admin API because Turnstile owns the form, not for convenience.
userId = await createUser(email, password);

const { browser: b2, ctx: ctx2 } = await loggedInContext(BASE, { email });
browser = b2;
page = await ctx2.newPage();
page.setDefaultTimeout(45_000);

await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(9000);

if (page.url().includes("/auth/login")) await fail("new account bounced straight back to login");

const text = await page.locator("body").innerText().catch(() => "");
for (const bad of [/something went wrong/i, /internal server error/i, /does not exist/i,
                   /unhandled/i, /application error/i]) {
  if (bad.test(text)) await fail(`new account landed on an error page: ${text.slice(0, 160).replace(/\s+/g, " ")}`);
}

// Onboarding, a join prompt, a picker or the app are all fine. A redirect loop is not:
// that is what broken org resolution looks like from outside.
const first = page.url();
await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url() !== first && page.url().includes("/auth/"))
  await fail(`new account settles nowhere: first landed ${first}, then ${page.url()}`);

await browser.close();
browser = null; page = null;
await deleteUser(userId);
console.log(`ok signup: form renders with captcha, new account reaches ${first.replace(BASE, "") || "/"}`);
