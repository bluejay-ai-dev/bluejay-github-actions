// prepares a bluebic run:
//   1. resolve the target repo from failure_mode (static map) → step output `target_repo`
//   2. pull the failed-chat context (bluejay-mcp, with a supabase read fallback)
//   3. write /tmp/bluebic/context.md and /tmp/bluebic/PROMPT.md
//
// PROMPT.md = the VERBATIM D.3 system prompt + a "## CONTEXT" section (transcript +
// error fields) + the working-dir / kb-pointer note adapting D.3 to this CI rig.
//
// env: BLUEBIC_CHAT_ID, BLUEBIC_ORG_ID, BLUEBIC_FAILURE_MODE,
//      BLUEJAY_MCP_URL, BLUEJAY_MCP_TOKEN (mcp read),
//      SUPABASE_URL, SUPABASE_SERVICE_KEY (degraded fallback read; optional).
import { mkdirSync, writeFileSync } from "node:fs";
import * as core from "@actions/core";
import { resolveRepo } from "./repo-map.mjs";

const OUT_DIR = "/tmp/bluebic";

// ── the verbatim D.3 system prompt (blueprint section D.3, lines 572-621) ──────────
const D3_SYSTEM_PROMPT = `ROLE
You are BlueBic, an autonomous Bluejay engineer. A production agent conversation FAILED.
Diagnose the root cause and open ONE focused PR that fixes it. You are AFK-trusted but
rail-guarded.

CONTEXT YOU ARE GIVEN
- Failed conversation: transcript, test_result.status, error_code, error_message,
  error_details, custom-metric reasoning, agent config (prompt + KB + connection type).
- Target repo cloned at <path>, on a fresh branch off origin/dev.
- MCP access: bluejay-mcp (call logs, agents, KBs, metrics — org-scoped) and
  tolaria (the Bluejay knowledge base).

STEP 1 — GROUND YOURSELF IN THE KB (do this BEFORE reading code)
- Read knowledge_base/AGENTS.md, then simulations/status-and-error-taxonomy.md.
  Map the error_code to its bucket, likely subsystem, and known write sites.
- tolaria search_notes on {error_code, key symptom phrases}; read matches + wikilinks.
- Scan bugfixes/ for a prior fix to a similar symptom — reuse the pattern.

STEP 2 — DIAGNOSE
- Form a SINGLE root-cause hypothesis tied to a file:line. Distinguish:
  agent-misconfig (NOT a code bug → status=NO_FIX, explain) vs provider outage
  (NOT a code bug → NO_FIX) vs genuine Bluejay code defect (→ fix).
- If it's not a code bug, STOP and report NO_FIX with the reason. Do not invent a fix.

STEP 3 — FIX (minimal, scoped)
- Branch already off dev. Edit ONLY files implicated by the root cause.
- Match house style (reference_clean_code: cut excess, DRY, comments explain why).
- Add/adjust the narrowest test that reproduces the failure.

STEP 4 — VERIFY
- Run ONLY the targeted tests for files you touched. Respect CLAUDE.md guardrails
  (never broad pytest, never run livekit_agent tests broadly, OOM rails).
- git diff --stat — confirm only expected files moved.

STEP 5 — SHIP
- Commit (new commits, scoped staging — never add -A, never amend, never --no-verify).
- Footer: Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
- Push branch; open PR targeting dev. PR body: root cause, the failed conversation link,
  KB notes consulted, what changed, how verified. End with the Generated-with-Claude-Code footer.

HARD RAILS
- NEVER push to main/dev/master/prod. Only the BlueBic feature branch.
- NEVER --force, --no-verify, or amend.
- If the fix touches auth*, secrets*, env*, migrations, or IAM → set status=NEEDS_REVIEW,
  open the PR as DRAFT, and flag for a human. Do not auto-merge anything, ever.
- Cap: one diagnosis + up to 3 fix/verify cycles. If still red, open a DRAFT PR with the
  partial diagnosis and stop.

OUTPUT (write to job row)
status, root_cause (1-2 sentences, file:line), diagnosis_summary, pr_url, error_code, kb_notes_used.`;

// ── operating notes: reconcile D.3 (which assumes MCP + the agent ships its own PR)
//    with this CI rig (KB mounted as files, transcript injected, harness ships) ──────
function operatingNotes(targetRepo, confident) {
  const confidenceNote = confident
    ? `The target repo is "${targetRepo}".`
    : `The failure_mode did not map to a specific repo, so the target defaults to "${targetRepo}". State this low confidence in your RESULT.json root_cause; if the bug clearly belongs elsewhere, say so and prefer NO_FIX over forcing a fix into the wrong repo.`;

  return `## HOW THIS RUN IS WIRED (adapts the steps above to this environment)
- The target repo is checked out at \`./target\`, already on a fresh BlueBic branch off \`dev\`. Do all code work there. ${confidenceNote}
- The Bluejay knowledge base is checked out as files at \`../knowledge_base\` (relative to ./target) — there is NO live MCP or tolaria server in this run. Wherever Step 1 says "tolaria search_notes", instead Read/Grep the files: start at \`../knowledge_base/AGENTS.md\`, then \`../knowledge_base/simulations/status-and-error-taxonomy.md\`, then scan \`../knowledge_base/bugfixes/\`, following the index and wikilinks.
- The failed-conversation context (transcript + error fields) is provided inline below under "## CONTEXT" — there is no MCP to fetch more. Diagnose from what's here plus the target repo's code and the KB.
- DO NOT push or open the PR yourself — a harness step does that after you finish. Your job is: ground in the KB, diagnose, make the minimal scoped edits in \`./target\`, add the narrowest test, verify, and commit your changes (scoped staging, never \`add -A\`, never amend, never \`--no-verify\`). The harness reads your committed diff to build the branch and PR.
- INSTEAD of "write to job row", write your conclusion to \`/tmp/bluebic/RESULT_NOTE.md\` with: a one-line root_cause (file:line), the failure verdict (FIX | NO_FIX | NEEDS_REVIEW), a short diagnosis_summary, and the KB notes you consulted. If it is NOT a code bug (agent-misconfig or provider outage), make NO edits, leave the working tree clean, and record NO_FIX with the reason — the harness detects an empty diff as NO_FIX.
- Stay inside the hard rails above: scoped edits only, never touch \`main\`/\`dev\`, never auto-merge. If you must touch auth/secrets/env/migrations/IAM, still make the edit but record NEEDS_REVIEW in RESULT_NOTE.md so the harness opens a DRAFT PR.`;
}

// ── failed-chat context: bluejay-mcp first, supabase read as a degraded fallback ────

// pulls transcript + latest eval row + agent config. bluejay-mcp is the FastMCP server
// on middleware (org-scoped, supabase-jwt authed). exact tool surface varies, so this
// is best-effort: any failure falls through to the supabase read.
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
    `bluejay_ai_chat_evals?chat_id=eq.${chatId}&select=failure_mode,verdict,breakdown_turn,breakdown_point,inferred_goal,llm_judge_reasoning&order=ingest_date.desc&limit=1`,
  );
  if (!chat && !evalRow) return null;
  return { chat: chat ?? null, eval: evalRow ?? null, source: "supabase-fallback" };
}

function renderContext(chatId, failureMode, data) {
  const lines = [
    `Failed chat id: ${chatId}`,
    `Judge failure_mode: ${failureMode || "(none provided)"}`,
  ];

  if (!data) {
    lines.push(
      "",
      "Context source: UNAVAILABLE — neither bluejay-mcp nor the supabase fallback returned data.",
      "Diagnose from the failure_mode, the target repo code, and the KB taxonomy. If you cannot",
      "form a confident, code-grounded root cause without the transcript, record NO_FIX rather than guessing.",
    );
    return lines.join("\n");
  }

  lines.push("", `Context source: ${data.source ?? "bluejay-mcp"}`);

  const judge = data.eval ?? data.judge ?? null;
  if (judge) {
    lines.push("", "### Judge verdict");
    for (const k of ["verdict", "failure_mode", "inferred_goal", "breakdown_turn", "breakdown_point", "llm_judge_reasoning"]) {
      if (judge[k] != null) lines.push(`- ${k}: ${judge[k]}`);
    }
  }

  for (const k of ["test_result_status", "error_code", "error_message", "error_details"]) {
    if (data[k] != null) lines.push(`- ${k}: ${data[k]}`);
  }

  const messages = data.chat?.messages ?? data.transcript ?? null;
  if (messages != null) {
    lines.push("", "### Transcript (raw)", "```json", JSON.stringify(messages, null, 2), "```");
  }
  if (data.agent_config != null) {
    lines.push("", "### Agent config", "```json", JSON.stringify(data.agent_config, null, 2), "```");
  }
  return lines.join("\n");
}

async function main() {
  const chatId = process.env.BLUEBIC_CHAT_ID;
  const orgId = process.env.BLUEBIC_ORG_ID || "";
  const failureMode = process.env.BLUEBIC_FAILURE_MODE || "";
  if (!chatId) throw new Error("prepare.mjs: BLUEBIC_CHAT_ID required");

  const [targetRepo, confident] = resolveRepo(failureMode);
  core.setOutput("target_repo", targetRepo);
  core.info(`bluebic: failure_mode="${failureMode}" → target_repo=${targetRepo} (confident=${confident})`);

  const data = (await fetchViaMcp(chatId, orgId)) ?? (await fetchViaSupabase(chatId));
  const context = renderContext(chatId, failureMode, data);

  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(`${OUT_DIR}/context.md`, context);

  const prompt = [
    D3_SYSTEM_PROMPT,
    "",
    "---",
    "",
    operatingNotes(targetRepo, confident),
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
