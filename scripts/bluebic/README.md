# BlueBic Runner

The agentic half of **BlueBic** — "Cubic, but for Bluejay." When an engineer clicks
**Fix with BlueBic** on a failed chat in the observability dashboard, the dashboard
fires this workflow via `workflow_dispatch`. The runner diagnoses the failure with
headless Claude Code, opens **one** fix PR against the target repo's `dev` branch, and
reports status back to the dashboard.

v1 ships **reviewable code on feature branches only**: never auto-merges, opens a
**draft** PR for anything touching auth / secrets / env / migrations / IAM, and is hard
walled at 30 minutes.

## Flow

```
dashboard  POST /api/bluebic/jobs {chatId}
  → INSERT bluejay_bluebic_jobs (status=QUEUED)
  → workflow_dispatch → BlueBic Runner (this workflow)
       1. report.mjs RUNNING                    → dashboard PATCH (status=RUNNING)
       2. prepare.mjs                            → resolve target repo + build PROMPT.md
       3. checkout target repo @ dev + KB @ main
       4. git checkout -b bluebic/<chat8>-<job8>
       5. anthropics/claude-code-action@v1       → diagnose + edit files in target/ (model: claude-opus-4-8)
       6. ship.mjs                               → commit edits + push branch + gh pr create → RESULT.json
       7. report.mjs --from-result               → dashboard PATCH (PR_OPEN | NO_FIX | NEEDS_REVIEW | FAILED)
  → dashboard polls GET /api/bluebic/jobs/{id}, renders the status chip
```

The dashboard side (the `POST`/`GET`/`PATCH` routes, the `BlueBicButton`, and the
`bluejay_bluebic_jobs` migration) lives in the dashboard + ingest-service repos.

## Files

| File | Role |
|---|---|
| `.github/workflows/bluebic-runner.yml` | `workflow_dispatch` entrypoint + step orchestration |
| `scripts/bluebic/prepare.mjs` | resolve target repo (unmapped → NO_FIX); pull failed-chat context (MCP, supabase fallback) + the engineer note (`extra_context`); assemble `/tmp/bluebic/PROMPT.md` (goal-aware D.3 prompt + GH-cage note + numbered transcript) |
| `scripts/bluebic/transcript.mjs` | port of the dashboard's `renderTranscript` — numbered `[Tn]` tool-I/O transcript (same format the local runner + judge see) |
| `scripts/bluebic/ship.mjs` | commit the agent's working-tree edits, inspect the diff, detect sensitive paths, push the branch, `gh pr create`; write `/tmp/bluebic/RESULT.json` |
| `scripts/bluebic/report.mjs` | PATCH the dashboard callback with status |
| `scripts/bluebic/repo-map.mjs` | static `failure_mode → target repo` allowlist (mirrors the local runner; unmapped → NO_FIX) |

## Job status machine

```
QUEUED ─(runner claims)→ RUNNING → PR_OPEN        fix shipped, PR open
                                 ├→ NO_FIX         not a code bug (provider/misconfig); empty diff
                                 ├→ NEEDS_REVIEW   touched auth/secrets/env/migrations/IAM → DRAFT PR
                                 └→ FAILED         runner error / 3 cycles still red, no PR
```

## Target-repo allowlist

`repo-map.mjs` only ever emits three repos, all owned by `bluejay-ai-dev`. The map mirrors
the local runner's allowlist (`bluejay-ai-dashboard scripts/bluebic-runner.mjs`) so both
backends route a given `failure_mode` to the same repo:

| `failure_mode` | target repo | why |
|---|---|---|
| `tool_error`, `handoff_failure` | `bluejay_middleware` | tool/integration call sites, escalation routing |
| `knowledge_gap` | `knowledge_base` | KB/RAG/grounding content |
| `ignored_instruction`, `over_refusal`, `looped` | `bluejay_frontend_v2` | these dashboard chats are the platform/text assistant, whose system prompt + behavior live in `bluejay_frontend_v2` — NOT the voice `livekit_agent` |
| `abandoned`, `none`, null, unknown | *(none → NO_FIX)* | not mapped: the runner reports NO_FIX without checking out a repo or running the agent |

Keeping the map to these three keeps `BLUEBIC_GH_TOKEN`'s repo scope minimal and auditable —
the PAT must be scoped to exactly `bluejay_middleware`, `knowledge_base`, `bluejay_frontend_v2`.

## Required CI secrets (names only — set these on the `bluejay-github-actions` repo)

| Name | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude Code Action auth — the prod analogue of the local machine keyring (no keyring in CI) |
| `BLUEBIC_GH_TOKEN` | PAT with `contents:write` + `pull-requests:write` scoped to exactly `bluejay_middleware`, `knowledge_base`, `bluejay_frontend_v2`, and `read` on `knowledge_base` — checkout target + KB, push, `gh pr create` |
| `BLUEBIC_CALLBACK_URL` | Dashboard base URL the runner PATCHes (e.g. `https://<dashboard-host>`) |
| `BLUEBIC_CALLBACK_TOKEN` | Shared secret for the PATCH callback — **must equal** the dashboard's `BLUEBIC_CALLBACK_TOKEN` |
| `BLUEJAY_MCP_URL` | Bluejay MCP server base URL (primary transcript + metrics read) |
| `BLUEJAY_MCP_TOKEN` | Scoped Supabase bearer for the runner's data read |
| `SUPABASE_URL` | *(optional)* degraded fallback read when MCP is unreachable — also reads the job row's `extra_context` (engineer note) |
| `SUPABASE_SERVICE_KEY` | *(optional)* paired with `SUPABASE_URL` for the fallback read |

The matching dashboard-side secrets are `BLUEBIC_DISPATCH_TOKEN` (a PAT with
`actions:write` on this repo, used to fire `workflow_dispatch`) and the same
`BLUEBIC_CALLBACK_TOKEN`.

## How the dashboard triggers it

`POST /api/bluebic/jobs` fires the dispatch with a server-side PAT
(`BLUEBIC_DISPATCH_TOKEN`):

```
POST https://api.github.com/repos/bluejay-ai-dev/bluejay-github-actions/actions/workflows/bluebic-runner.yml/dispatches
Authorization: Bearer <BLUEBIC_DISPATCH_TOKEN>
{ "ref": "main", "inputs": { "job_id", "chat_id", "organization_id", "failure_mode" } }
```

`workflow_dispatch` returns no run id, so correlation is by the `job_id` input: the
runner reports `run_url` on the RUNNING callback and the dashboard deep-links it.

> While `bluebic-runner.yml` is on the `rg-bluebic` branch, dispatch against `ref: rg-bluebic`. Switch the dashboard's dispatch `ref` to `main` once this merges.

## Guardrails (baked into the system prompt + `ship.mjs`)

- The agent only edits files + runs read-only git / scoped tests — it never pushes, commits, or opens the PR. The harness (`ship.mjs`) owns staging, the single scoped commit (`Co-Authored-By: Claude Opus 4.8`), the push, and `gh pr create`.
- Never pushes to `main` / `dev` / `master` — `ship.mjs` refuses to ship from a protected branch, and the prompt forbids it.
- Never `--force` / `--no-verify` / `--amend`; plain `git push` only; base = `dev`.
- Bounded by `--max-turns 40` + the 30-minute `timeout-minutes` wall.
- Sensitive paths (`auth`, `secret`, `.env`, `migration`, `iam`, `credential`) → DRAFT PR + `NEEDS_REVIEW` (lockstep with the local runner's `SENSITIVE_RE`).
- Empty diff → `NO_FIX` (the agent is told to make no edits when the failure isn't a Bluejay code bug). Unmapped `failure_mode` → `NO_FIX` before any checkout.
- Never auto-merges, ever.

## Production upgrade (not built in v1)

This v1 authenticates with **PATs** (`BLUEBIC_GH_TOKEN` for git/PR, `BLUEBIC_DISPATCH_TOKEN`
for dispatch) to avoid registering a GitHub App. The production identity is a **GitHub
App** with least-privilege `contents:write` + `pull_requests:write` on a fixed repo
allowlist — `BLUEBIC_GH_APP_ID` / `BLUEBIC_GH_APP_PRIVATE_KEY` / `BLUEBIC_GH_APP_INSTALLATION_ID`.
Swap the token inputs for an app-token mint step (e.g. `actions/create-github-app-token`)
and nothing else in the runner changes.

**Scale path:** when volume or runtime outgrows the 30-minute Actions cap, replace
`workflow_dispatch` → GitHub Actions with `POST /jobs` → SQS → Fargate (one task per
job). The `bluejay_bluebic_jobs` row and the PATCH callback contract are unchanged —
only the dispatch + host swap.
