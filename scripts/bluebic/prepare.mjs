// prepares a bluebic run:
//   1. resolve the target repo from failure_mode (static allowlist) → step output `target_repo`.
//      unmapped (abandoned/none/null) → NO_FIX: write RESULT.json + emit target_repo="" so the
//      workflow skips checkout / agent / ship.
//   2. pull the failed-chat context (bluejay-mcp, with a supabase read fallback) and render the
//      transcript with the SAME numbered tool-I/O format the local runner + judge use.
//   3. read the engineer's free-text note (extra_context) from the bluejay_bluebic_jobs row.
//   4. write /tmp/bluebic/context.md and /tmp/bluebic/PROMPT.md.
//
// PROMPT.md = the goal-aware D.3-derived system prompt (mirrors the local runner's caged
// version, NOT the old MCP/self-PR one) + an honest GH-cage operational note + the injected
// "## CONTEXT" (numbered transcript + judge localization + engineer note).
//
// env: BLUEBIC_JOB_ID, BLUEBIC_CHAT_ID, BLUEBIC_ORG_ID, BLUEBIC_FAILURE_MODE,
//      BLUEJAY_MCP_URL, BLUEJAY_MCP_TOKEN (mcp read),
//      SUPABASE_URL, SUPABASE_SERVICE_KEY (degraded fallback read + extra_context; optional).
import { mkdirSync, writeFileSync } from "node:fs";
import * as core from "@actions/core";
import { resolveRepo } from "./repo-map.mjs";
import { renderTranscript } from "./transcript.mjs";

const OUT_DIR = "/tmp/bluebic";
const RESULT_PATH = `${OUT_DIR}/RESULT.json`;

// ── system prompt — the goal-aware D.3-derived version, mirroring the local runner's
//    coherent caged prompt (bluejay-ai-dashboard scripts/bluebic-runner.mjs). The agent
//    diagnoses + edits files (and, in CI, may git-commit + run scoped tests); the HARNESS
//    pushes + opens the DRAFT PR. No MCP/tolaria, no self-PR — the GH-cage note below states
//    exactly what this rig grants. ──────────────────────────────────────────────────────
const D3_SYSTEM_PROMPT = `ROLE
You are BlueBic, an autonomous Bluejay engineer. A production agent conversation FAILED.
Diagnose the root cause and implement a minimal, focused fix by EDITING FILES in the
repository you are working in. A human reviews your change as a DRAFT pull request before
anything merges — be precise and conservative.

CONTEXT YOU ARE GIVEN
- The failed conversation: transcript, the judge's failure mode, the customer's goal, the
  breakdown point, and supporting evidence.
- The Bluejay knowledge base is mounted as a readable directory. Read it FIRST for product
  and architecture context and for prior fixes to similar symptoms.

STEP 1 — GROUND YOURSELF IN THE KB (before reading code)
- Read the knowledge base for the relevant subsystem, the status/error taxonomy, and any
  bugfix notes for a similar symptom; reuse the established pattern.

STEP 2 — DIAGNOSE
- Form a SINGLE root-cause hypothesis tied to a file:line. Distinguish a genuine Bluejay
  CODE DEFECT (→ fix it) from an agent-misconfiguration or a provider outage (NOT a code
  bug → make NO edits and say so). Do not invent a fix for a non-code problem.

STEP 3 — FIX (minimal, scoped)
- Edit ONLY the files implicated by the root cause. Match house style (cut excess, DRY,
  comments explain *why*). If a test belongs with the fix, add the narrowest one.

RAILS
- Edit files only; keep the change minimal and reviewable.
- If the fix touches auth, secrets, env, migrations, or IAM, still make the edit but call
  it out explicitly in your ROOT CAUSE line so the human reviewer treats it carefully.
- If this is not a code bug, make NO edits and explain why in your ROOT CAUSE line.`;

// ── GH-cage operational note: states this CI rig's ACTUAL cage honestly. Unlike the local
//    runner (file edits only, runner does all git), the GH agent may git-commit + run the
//    scoped test commands the workflow allowlists — but it still may NOT push or open the PR
//    (the harness does that), and there is NO MCP/tolaria (KB is files at ../knowledge_base). ──
function ghCageNote(targetRepo) {
  return `## HOW THIS RUN IS WIRED (this CI rig's cage)
- Your working directory is the CI workspace root. The target repo "${targetRepo}" is checked out in the \`target/\` subdirectory, already on a fresh BlueBic branch off \`dev\`. Do ALL code work inside \`target/\` (edit files there, and run any \`git\`/test commands with that as the repo root, e.g. \`git -C target ...\`).
- The Bluejay knowledge base is checked out as files in the \`knowledge_base/\` subdirectory (a sibling of \`target/\`) — there is NO live MCP or tolaria server. To "ground in the KB", Read/Grep the files: start at \`knowledge_base/AGENTS.md\`, then the status/error taxonomy, then scan \`knowledge_base/bugfixes/\` for a similar symptom.
- You MAY run \`git status\` / \`git diff\` (to self-check your change) and the scoped test commands the harness allowlists (npm test / npx tsc / pytest on the files you touched). You do NOT need to stage, commit, push, or open the PR — a harness step commits your working-tree edits, builds the branch, and opens the DRAFT PR after you finish. Just leave your minimal edits in \`target/\`. Never run broad test suites.
- The failed-conversation context (numbered transcript + judge localization + the engineer's note) is inline below under "## CONTEXT". There is no MCP to fetch more — diagnose from what's here plus the target repo's code and the KB.
- Write your conclusion to \`/tmp/bluebic/RESULT_NOTE.md\`: a one-line \`root_cause:\` (cite file:line), the verdict (FIX | NO_FIX | NEEDS_REVIEW), a short diagnosis summary, and the KB notes you consulted.
- If this is NOT a code bug (agent-misconfig or provider outage), make NO edits, leave the working tree clean, and record NO_FIX — the harness detects an empty diff as NO_FIX.
- HARD RAILS: scoped edits only; never auto-merge; the harness only ever pushes the BlueBic feature branch and opens a DRAFT PR against \`dev\` (never \`main\`/\`master\`). If your fix touches auth/secrets/env/migrations/IAM, still make the edit but record NEEDS_REVIEW in RESULT_NOTE.md so the harness opens the PR as a DRAFT.`;
}

// ── failed-chat context: bluejay-mcp first, supabase read as a degraded fallback ────

// pulls transcript + latest eval row. bluejay-mcp is the FastMCP server on middleware
// (org-scoped, supabase-jwt authed). exact tool surface varies, so this is best-effort:
// any failure falls through to the supabase read.
async function fetchViaMcp(chatId, orgId) {
  const base = process.env.BLUEJAY_MCP_URL;
  const token = process.env.BLUEJAY_MCP_TOKEN;
  if (!base || !token) return null;

  const res = await fetch(`${base.replace(/\/$/, "")}/bluebic/chat-context`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ chat_id: chatId, organization_id: orgId || null }),
  });
  if (!res.ok) {
    core.warning(`bluebic: MCP context fetch HTTP ${res.status}; falling back to supabase read`);
    return null;
  }
  return res.json();
}

// degraded fallback: read the chat row + latest eval directly from supabase via the
// rest endpoint. unblocks when MCP is unreachable. read-only, no new plumbing.
async function fetchViaSupabase(chatId) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return null;

  const headers = { apikey: key, Authorization: `Bearer ${key}` };
  const get = async (path) => {
    const res = await fetch(`${url.replace(/\/$/, "")}/rest/v1/${path}`, { headers });
    return res.ok ? res.json() : [];
  };

  const [chat] = await get(`chats?id=eq.${chatId}&select=id,title,messages,organization_id`);
  const [evalRow] = await get(
    `bluejay_ai_chat_evals?chat_id=eq.${chatId}&select=failure_mode,verdict,breakdown_turn,breakdown_point,inferred_goal,evidence,llm_judge_reasoning&order=ingest_date.desc&limit=1`,
  );
  if (!chat && !evalRow) return null;
  return { chat: chat ?? null, eval: evalRow ?? null, source: "supabase-fallback" };
}

// the engineer's modal note lives ONLY on the bluebic job row (it's in no other table). read
// it from supabase by job_id. best-effort: a missing key / column just yields no note.
async function fetchExtraContext(jobId) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_KEY;
  if (!jobId || !url || !key) return null;
  const headers = { apikey: key, Authorization: `Bearer ${key}` };
  try {
    const res = await fetch(
      `${url.replace(/\/$/, "")}/rest/v1/bluejay_bluebic_jobs?id=eq.${jobId}&select=extra_context`,
      { headers },
    );
    if (!res.ok) return null;
    const [row] = await res.json();
    return row?.extra_context ?? null;
  } catch (err) {
    core.warning(`bluebic: extra_context read failed: ${err.message ?? err}`);
    return null;
  }
}

// build the "## CONTEXT" block: judge localization (goal/breakdown/evidence) + the numbered
// transcript (renderTranscript — same format the local runner + judge use) + the engineer note.
function renderContext(chatId, failureMode, data, extraContext) {
  const lines = [
    `Failed chat id: ${chatId}`,
    `Judge failure_mode: ${failureMode || "(none provided)"}`,
  ];

  if (data) {
    lines.push("", `Context source: ${data.source ?? "bluejay-mcp"}`);

    const judge = data.eval ?? data.judge ?? null;
    if (judge) {
      lines.push("", "### Judge localization");
      for (const [label, k] of [
        ["VERDICT", "verdict"],
        ["CUSTOMER GOAL", "inferred_goal"],
        ["BREAKDOWN TURN", "breakdown_turn"],
        ["BREAKDOWN POINT", "breakdown_point"],
        ["EVIDENCE", "evidence"],
        ["JUDGE REASONING", "llm_judge_reasoning"],
      ]) {
        if (judge[k] != null) lines.push(`- ${label}: ${judge[k]}`);
      }
    }

    const messages = data.chat?.messages ?? data.transcript ?? null;
    const transcript = renderTranscript(messages);
    lines.push(
      "",
      "### Failed conversation (turns numbered; tool calls show name, state, input → output)",
      transcript || "(transcript unavailable)",
    );
  } else {
    lines.push(
      "",
      "Context source: UNAVAILABLE — neither bluejay-mcp nor the supabase fallback returned data.",
      "Diagnose from the failure_mode, the target repo code, and the KB taxonomy. If you cannot",
      "form a confident, code-grounded root cause without the transcript, record NO_FIX rather than guessing.",
    );
  }

  if (extraContext) {
    lines.push(
      "",
      "### ADDITIONAL CONTEXT FROM THE ENGINEER (information that may not be in the transcript)",
      extraContext,
    );
  }
  return lines.join("\n");
}

// unmapped failure_mode → NO_FIX without ever checking out a repo or running the agent.
// emit target_repo="" so the workflow's downstream steps (checkout / agent / ship) skip,
// and pre-write RESULT.json so report.mjs --from-result reports NO_FIX.
function emitNoFix(failureMode) {
  core.setOutput("target_repo", "");
  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(
    RESULT_PATH,
    JSON.stringify(
      {
        status: "NO_FIX",
        root_cause: `No code target for failure_mode="${failureMode || "unknown"}" — likely agent-misconfig, provider outage, or abandoned. No repo checked out, no PR opened.`,
      },
      null,
      2,
    ),
  );
  core.info(`bluebic: failure_mode="${failureMode}" maps to no repo → NO_FIX`);
}

async function main() {
  const jobId = process.env.BLUEBIC_JOB_ID || "";
  const chatId = process.env.BLUEBIC_CHAT_ID;
  const orgId = process.env.BLUEBIC_ORG_ID || "";
  const failureMode = process.env.BLUEBIC_FAILURE_MODE || "";
  if (!chatId) throw new Error("prepare.mjs: BLUEBIC_CHAT_ID required");

  const [targetRepo] = resolveRepo(failureMode);
  if (!targetRepo) {
    emitNoFix(failureMode);
    return;
  }
  core.setOutput("target_repo", targetRepo);
  core.info(`bluebic: failure_mode="${failureMode}" → target_repo=${targetRepo}`);

  const data = (await fetchViaMcp(chatId, orgId)) ?? (await fetchViaSupabase(chatId));
  const extraContext = await fetchExtraContext(jobId);
  const context = renderContext(chatId, failureMode, data, extraContext);

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(`${OUT_DIR}/context.md`, context);

  const prompt = [
    D3_SYSTEM_PROMPT,
    "",
    "---",
    "",
    ghCageNote(targetRepo),
    "",
    "---",
    "",
    "## CONTEXT",
    "",
    context,
  ].join("\n");
  writeFileSync(`${OUT_DIR}/PROMPT.md`, prompt);

  core.info(`bluebic: wrote ${OUT_DIR}/PROMPT.md and ${OUT_DIR}/context.md`);
}

main().catch((err) => {
  core.setFailed(err.message ?? String(err));
});
