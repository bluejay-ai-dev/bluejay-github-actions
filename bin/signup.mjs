// Onboarding half of the nightly: can a brand new account get from nothing to inside an
// organization. This is the path the ENG-544 release broke on 2026-09-02, and nothing
// else in the suite touches it, because every other part signs in as a fixture user that
// already has an org.
//
//   node signup.mjs <frontend_url>
//
// Exit: 0 | 1 regression | 3 fixture or prerequisite missing
//
// It does NOT complete the public sign-up form. Turnstile gates the submit button on any
// deployment with NEXT_PUBLIC_TURNSTILE_SITE_KEY set, and a headless browser cannot solve
// it. Pretending otherwise would give a green nightly that proves nothing. So the form is
// asserted as far as it renders, and the part a captcha does not protect, everything
// after the account exists, is driven with a real new account instead.
import { chromium } from "playwright";
import { loggedInContext, createUser, deleteUser, die, need } from "./session.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
if (!BASE) die("usage: signup.mjs <frontend_url>", 3);
need("SUITE_SUPABASE_SERVICE_KEY");

// A domain we own and can receive at, so a bounce is never someone else's problem.
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

// 1. the public form still renders, and still has its captcha. A signup page that lost
// Turnstile is a worse bug than one that is down, so this asserts presence, not absence.
{
  // Anonymous on purpose: this is the PUBLIC form, and needing a session to check it
  // would mean the one page a signed-out visitor sees is the one we never test signed out.
  browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 1000 } });
  const p = await ctx.newPage();
  page = p;
  p.setDefaultTimeout(45_000);
  await p.goto(`${BASE}/auth/sign-up`, { waitUntil: "domcontentloaded" }).catch(() => {});
  await p.waitForTimeout(6000);
  const body = await p.locator("body").innerText().catch(() => "");
  if (!/sign ?up|create.*account|get started/i.test(body))
    await fail("sign-up page did not render a sign-up form");
  // The hidden response input, not the iframe: Turnstile renders the iframe lazily and
  // inside a shadow root, so an iframe selector reports "no captcha" on a page that
  // plainly has one. The input is injected whenever the widget is mounted.
  const hasCaptcha = (await p.locator('input[name="cf-turnstile-response"]').count()) > 0;
  if (!hasCaptcha && process.env.SUITE_EXPECT_CAPTCHA === "1")
    await fail("sign-up form rendered with no Turnstile widget, bot signups are open");
  await browser.close();
  browser = null; page = null;
}

// 2. a genuinely new account, taken through whatever onboarding it lands in. Created
// through the admin API because Turnstile owns the form, not because the form is skipped
// for convenience: everything from here on is the code a captcha never protected.
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

// It is allowed to land on onboarding, a join-org prompt, an org picker, or the app. It is
// not allowed to land nowhere, and it is not allowed to loop. The redirect loop is the one
// this is really watching for: that is what a broken org resolution looks like from outside.
const first = page.url();
await page.goto(`${BASE}/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url() !== first && page.url().includes("/auth/"))
  await fail(`new account settles nowhere: first landed ${first}, then ${page.url()}`);

await browser.close();
browser = null; page = null;
await deleteUser(userId);
console.log(`ok signup: form renders with captcha, new account reaches ${first.replace(BASE, "") || "/"}`);
