// ships the bluebic fix: inspect the diff, push the branch, open the PR.
// runs with cwd = ./target (the checked-out target repo, on the bluebic branch).
//
// outcomes (written to /tmp/bluebic/RESULT.json for report.mjs --from-result):
//   NO_FIX        empty diff → not a code bug; no branch, no PR
//   NEEDS_REVIEW  diff touches sensitive paths → DRAFT PR
//   PR_OPEN       normal fix → PR opened against dev
//   FAILED        push or pr-create errored
//
// env: GH_TOKEN (gh auth), BLUEBIC_CHAT_ID, BLUEBIC_JOB_ID, BLUEBIC_FAILURE_MODE,
//      BLUEBIC_TARGET_REPO, BLUEBIC_RUN_URL.
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";

const RESULT_PATH = "/tmp/bluebic/RESULT.json";
const NOTE_PATH = "/tmp/bluebic/RESULT_NOTE.md";
const BASE_BRANCH = "dev"; // house rule: branch off + target dev

// paths that demand a human: open the PR as DRAFT, status NEEDS_REVIEW.
// kept in lockstep with the local runner's SENSITIVE_RE (dashboard scripts/bluebic-runner.mjs).
const SENSITIVE = [/auth/i, /secret/i, /\.env/i, /migration/i, /iam/i, /credential/i];

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

function writeResult(result) {
  mkdirSync("/tmp/bluebic", { recursive: true });
  writeFileSync(RESULT_PATH, JSON.stringify(result, null, 2));
  console.log(`bluebic: ship result = ${result.status}`);
}

// pull the agent's recorded root_cause from RESULT_NOTE.md (free text); fall back to
// the diffstat. never fatal — the note is advisory.
function readNote() {
  if (!existsSync(NOTE_PATH)) return "";
  try {
    return readFileSync(NOTE_PATH, "utf8").trim();
  } catch {
    return "";
  }
}

function firstRootCauseLine(note) {
  const m = note.match(/root[_ ]?cause[:\s]*(.+)/i);
  return m ? m[1].trim().slice(0, 300) : note.split("\n")[0]?.slice(0, 300) ?? "";
}

function main() {
  const chatId = process.env.BLUEBIC_CHAT_ID ?? "";
  const failureMode = process.env.BLUEBIC_FAILURE_MODE || "unknown";
  const targetRepo = process.env.BLUEBIC_TARGET_REPO ?? "";
  const runUrl = process.env.BLUEBIC_RUN_URL ?? "";
  const branch = git(["rev-parse", "--abbrev-ref", "HEAD"]);
  const note = readNote();
  const rootCause = firstRootCauseLine(note);

  // hard rail: refuse to ship if we somehow ended up on a protected branch.
  if (["main", "dev", "master"].includes(branch)) {
    writeResult({ status: "FAILED", error: `refusing to ship from protected branch "${branch}"`, run_url: runUrl });
    return;
  }

  // the harness owns the commit (mirrors the local runner): if the agent left edits in the
  // working tree without committing, stage + commit them here so the diff below is
  // authoritative. scoped to tracked changes + new files; never amend, never --no-verify.
  // a clean tree (NO_FIX) is the no-op case — `commit` errors out and we fall through.
  if (git(["status", "--porcelain"])) {
    git(["add", "-A"]);
    const msg = `BlueBic: fix ${failureMode} from chat ${chatId.replace(/-/g, "").slice(0, 8)}\n\n${rootCause || "AI-diagnosed fix."}\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`;
    try {
      git(["commit", "-m", msg]);
    } catch {
      // nothing staged (e.g. only ignored files) → leave HEAD as-is; the diff check is NO_FIX.
    }
  }

  // empty diff vs dev → no code change was made → NO_FIX.
  const diffStat = git(["diff", "--stat", `${BASE_BRANCH}...HEAD`]);
  if (!diffStat) {
    writeResult({
      status: "NO_FIX",
      target_repo: targetRepo,
      root_cause: rootCause || "no code change — diagnosed as agent-misconfig or provider issue, not a Bluejay code bug.",
      run_url: runUrl,
    });
    return;
  }

  // sensitive-path detection over the changed files.
  const changed = git(["diff", "--name-only", `${BASE_BRANCH}...HEAD`]).split("\n").filter(Boolean);
  const sensitiveHits = changed.filter((f) => SENSITIVE.some((re) => re.test(f)));
  const needsReview = sensitiveHits.length > 0;
  const status = needsReview ? "NEEDS_REVIEW" : "PR_OPEN";

  const title = `BlueBic: fix ${failureMode} in ${targetRepo.split("/").pop()}`;
  const bodyLines = [
    `## BlueBic auto-fix`,
    ``,
    `**Root cause:** ${rootCause || "(see diagnosis note below)"}`,
    ``,
    `**Failed chat:** \`${chatId}\``,
    `**Judge failure_mode:** \`${failureMode}\``,
    runUrl ? `**Runner:** ${runUrl}` : ``,
    ``,
    `### Diagnosis`,
    note || "(no diagnosis note recorded)",
    ``,
    `### Changed files`,
    "```",
    diffStat,
    "```",
  ];
  if (needsReview) {
    bodyLines.push(
      ``,
      `> ⚠️ **NEEDS REVIEW** — touches sensitive paths (${sensitiveHits.join(", ")}). Opened as a DRAFT; a human must review before merge. Never auto-merged.`,
    );
  }
  bodyLines.push(``, `🤖 Generated with [Claude Code](https://claude.com/claude-code)`);
  const body = bodyLines.filter((l) => l !== undefined).join("\n");

  try {
    // push the bluebic branch (plain push — never --force).
    execFileSync("git", ["push", "origin", branch], { stdio: "inherit" });

    const prArgs = [
      "pr", "create",
      "--repo", targetRepo,
      // always open as DRAFT — BlueBic PRs are AI-generated and reviewed before merge (matches the
      // local runner). needsReview (sensitive paths) additionally flags via status/NEEDS_REVIEW.
      "--draft",
      "--base", BASE_BRANCH,
      "--head", branch,
      "--title", title,
      "--body", body,
    ];

    const prUrl = execFileSync("gh", prArgs, { encoding: "utf8" }).trim().split("\n").pop();

    writeResult({
      status,
      target_repo: targetRepo,
      branch,
      pr_url: prUrl,
      root_cause: rootCause,
      run_url: runUrl,
    });
  } catch (err) {
    writeResult({
      status: "FAILED",
      target_repo: targetRepo,
      branch,
      root_cause: rootCause,
      error: (err.message ?? String(err)).slice(0, 500),
      run_url: runUrl,
    });
  }
}

main();
