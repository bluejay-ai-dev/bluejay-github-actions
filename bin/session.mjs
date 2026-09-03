// Shared browser session for the gate's playwright walks.
//
// The session comes from a service-role generate_link plus verify, not a password: the
// dev and prod Supabase projects are captcha-gated, so a headless password grant always
// fails. Imported by core-path.mjs and bluejay-ai.mjs.
import { chromium } from "playwright";

export const die = (m, code = 1) => { console.error(`FAIL ${m}`); process.exit(code); };
export const need = (k) => process.env[k] ?? die(`missing ${k}`, 3);

export async function signIn(asEmail) {
  const supaUrl = need("SUITE_SUPABASE_URL").replace(/\/$/, "");
  const anon = need("SUITE_SUPABASE_ANON_KEY");
  const service = need("SUITE_SUPABASE_SERVICE_KEY");
  const email = asEmail ?? need("SUITE_USER_EMAIL");

  const gen = await fetch(`${supaUrl}/auth/v1/admin/generate_link`, {
    method: "POST",
    headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email }),
  }).then((r) => r.json());
  if (!gen.email_otp) die(`generate_link: ${JSON.stringify(gen).slice(0, 200)}`, 3);

  const ver = await fetch(`${supaUrl}/auth/v1/verify`, {
    method: "POST",
    headers: { apikey: anon, "Content-Type": "application/json" },
    body: JSON.stringify({ type: "magiclink", email, token: gen.email_otp }),
    redirect: "manual",
  });
  let session = await ver.json().catch(() => ({}));
  if (!session.access_token) {
    const frag = new URLSearchParams((ver.headers.get("location") ?? "").split("#")[1] ?? "");
    if (!frag.get("access_token")) die(`verify: ${JSON.stringify(session).slice(0, 200)}`, 3);
    const ttl = Number(frag.get("expires_in") ?? 3600);
    session = {
      access_token: frag.get("access_token"),
      refresh_token: frag.get("refresh_token"),
      expires_in: ttl,
      expires_at: Math.floor(Date.now() / 1000) + ttl,
      token_type: "bearer",
    };
  }
  if (!session.user) {
    session.user = await fetch(`${supaUrl}/auth/v1/user`, {
      headers: { apikey: anon, Authorization: `Bearer ${session.access_token}` },
    }).then((r) => r.json());
  }
  return { session, ref: new URL(supaUrl).hostname.split(".")[0] };
}

// The FE reads the session out of a cookie the server can see, and GoTrue's payload is
// over the 4096-byte cookie limit, so it has to go back in chunked exactly as supabase-js
// wrote it.
export function sessionCookies(session, ref, BASE) {
  const raw = "base64-" + Buffer.from(JSON.stringify(session)).toString("base64");
  const CHUNK = 3180;
  const host = new URL(BASE).hostname;
  const secure = BASE.startsWith("https");
  const cookies = [];
  for (let i = 0; i * CHUNK < raw.length; i++) {
    cookies.push({
      name: `sb-${ref}-auth-token.${i}`,
      value: raw.slice(i * CHUNK, (i + 1) * CHUNK),
      domain: host,
      path: "/",
      expires: Math.floor(Date.now() / 1000) + 3600,
      httpOnly: true,
      secure,
      sameSite: "Lax",
    });
  }
  return cookies;
}

// Returns a context already carrying a valid session, plus the browser to close.
export async function loggedInContext(BASE, { viewport = { width: 1600, height: 1000 }, email } = {}) {
  const { session, ref } = await signIn(email);
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport });
  await ctx.addCookies(sessionCookies(session, ref, BASE));
  return { browser, ctx, session };
}

// Admin helpers for the nightly, which needs a user that did not exist yesterday.
function adminHeaders() {
  const service = need("SUITE_SUPABASE_SERVICE_KEY");
  return { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json" };
}

export async function createUser(email, password) {
  const supaUrl = need("SUITE_SUPABASE_URL").replace(/\/$/, "");
  const r = await fetch(`${supaUrl}/auth/v1/admin/users`, {
    method: "POST", headers: adminHeaders(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  const b = await r.json().catch(() => ({}));
  if (!r.ok || !b.id) die(`create user ${email}: ${r.status} ${JSON.stringify(b).slice(0, 200)}`, 3);
  return b.id;
}

// Best effort on purpose: a nightly that fails because cleanup failed is a nightly people
// mute. The leak is one row, and the sweep below catches it tomorrow.
export async function deleteUser(id) {
  const supaUrl = need("SUITE_SUPABASE_URL").replace(/\/$/, "");
  await fetch(`${supaUrl}/auth/v1/admin/users/${id}`, { method: "DELETE", headers: adminHeaders() })
    .catch(() => {});
}
