// reports bluebic job status back to the dashboard via the PATCH callback.
//
// two modes:
//   node report.mjs RUNNING --run-url <url>     literal status + optional run url
//   node report.mjs --from-result               reads /tmp/bluebic/RESULT.json for the terminal status
//
// auth is a shared secret header (X-Bluebic-Token), NOT a dashboard cookie — CI has
// no session. env: BLUEBIC_JOB_ID, BLUEBIC_CALLBACK_URL, BLUEBIC_CALLBACK_TOKEN.
import { readFileSync } from "node:fs";

const RESULT_PATH = "/tmp/bluebic/RESULT.json";
const VALID_STATUSES = new Set([
  "QUEUED", "RUNNING", "PR_OPEN", "NO_FIX", "NEEDS_REVIEW", "FAILED",
]);

function arg(name) {
  const i = process.argv.indexOf(name);
  return i !== -1 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined;
}

function buildBody() {
  // --from-result wins: the ship step has written the terminal outcome.
  if (process.argv.includes("--from-result")) {
    let result;
    try {
      result = JSON.parse(readFileSync(RESULT_PATH, "utf8"));
    } catch {
      // ship.mjs never ran (an earlier step failed) → report FAILED so the job
      // doesn't hang in RUNNING forever.
      return { status: "FAILED", error: "runner ended before producing a result" };
    }
    return result;
  }

  // literal status mode — first positional arg is the status.
  const status = process.argv[2];
  if (!VALID_STATUSES.has(status)) {
    throw new Error(`report.mjs: unknown status "${status}"`);
  }
  const body = { status };
  const runUrl = arg("--run-url");
  if (runUrl) body.run_url = runUrl;
  return body;
}

async function main() {
  const jobId = process.env.BLUEBIC_JOB_ID;
  const base = process.env.BLUEBIC_CALLBACK_URL;
  const token = process.env.BLUEBIC_CALLBACK_TOKEN;
  if (!jobId || !base || !token) {
    throw new Error("report.mjs: BLUEBIC_JOB_ID, BLUEBIC_CALLBACK_URL, BLUEBIC_CALLBACK_TOKEN all required");
  }

  const body = buildBody();
  const url = `${base.replace(/\/$/, "")}/api/bluebic/jobs/${jobId}`;
  const res = await fetch(url, {
    method: "PATCH",
    headers: {
      "Content-Type": "application/json",
      "X-Bluebic-Token": token,
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`report.mjs: callback failed HTTP ${res.status} — ${text.slice(0, 200)}`);
  }
  console.log(`bluebic: reported status=${body.status} for job ${jobId}`);
}

main().catch((err) => {
  console.error(err.message ?? String(err));
  process.exit(1);
});
