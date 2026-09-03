// Browser half of the gate (A6): can the FE read what the backend just wrote.
// Plain playwright, no test runner, matching shared/playwright. Exits 1 on failure.
//
//   SUITE_SIM_ID=.. SUITE_RUN_ID=.. SUITE_RESULT_ID=.. node core-path.mjs <frontend_url>
//
// Sign-in lives in session.mjs, shared with bluejay-ai.mjs.
import { loggedInContext, die } from "./session.mjs";

const BASE = (process.argv[2] ?? "").replace(/\/$/, "");
const { SUITE_SIM_ID: SIM, SUITE_RUN_ID: RUN, SUITE_RESULT_ID: RESULT } = process.env;
if (!BASE || !SIM || !RUN) die("usage: core-path.mjs <frontend_url>, with SUITE_SIM_ID and SUITE_RUN_ID", 3);

const { browser, ctx } = await loggedInContext(BASE);
const page = await ctx.newPage();
page.setDefaultTimeout(45000);

const fail = async (m) => {
  await page.screenshot({ path: `/tmp/suite-browser-fail.png` }).catch(() => {});
  await browser.close();
  die(`${m} (url=${page.url().slice(0, 140)}, shot=/tmp/suite-browser-fail.png)`);
};

// 1. list renders and we are actually logged in. The waits are not decoration: the list
// is client-fetched, and an auth bounce lands after hydration, not at domcontentloaded.
await page.goto(`${BASE}/simulations`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url().includes("/auth/")) await fail("bounced to login, session cookie rejected");
if (!(await page.getByRole("row").first().isVisible().catch(() => false)) &&
    !(await page.getByText(/simulation/i).first().isVisible().catch(() => false))) {
  await fail("simulations list never rendered");
}

// 2. the run the API half just created
await page.goto(`${BASE}/simulations/${SIM}/runs/${RUN}${RESULT ? `?result=${RESULT}` : ""}`,
  { waitUntil: "domcontentloaded" });
await page.waitForTimeout(7000);
if (page.url().includes("/auth/")) await fail("run page bounced to login");
const errored = await page.getByText(/something went wrong|failed to load|404/i).first()
  .isVisible().catch(() => false);
if (errored) await fail("run page rendered an error state");

// 3. transcript tab, which is the read that actually crosses into storage
const tab = page.getByRole("tab", { name: "Transcript" }).first();
if (await tab.isVisible().catch(() => false)) await tab.click();
await page.waitForTimeout(6000);
const body = await page.locator("body").innerText();
for (const bad of ["Error loading transcript", "No transcript available"]) {
  if (body.includes(bad)) await fail(`transcript pane says "${bad}"`);
}
// The one assertion that proves the FE read what the backend wrote, rather than just
// rendering a shell: a turn the API half already saw has to be on the page.
const expect = process.env.SUITE_EXPECT_TEXT ?? "";
if (expect && !body.includes(expect)) await fail(`transcript missing the turn the API returned: "${expect}"`);
console.log(`ok browser: list, run ${RUN}, transcript rendered${expect ? " with the expected turn" : ""}`);

await browser.close();
