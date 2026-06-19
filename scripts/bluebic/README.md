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
       5. anthropics/claude-code-action@v1       → diagnose + edit + commit (model: claude-opus-4-8)
       6. ship.mjs                               → push branch + gh pr create → RESULT.json
       7. report.mjs --from-result               → dashboard PATCH (PR_OPEN | NO_FIX | NEEDS_REVIEW | FAILED)
  → dashboard polls GET /api/bluebic/jobs/{id}, renders the status chip
```

The dashboard side (the `POST`/`GET`/`PATCH` routes, the `BlueBicButton`, and the
`bluejay_bluebic_jobs` migration) lives in the dashboard + ingest-service repos.

## Files

| File | Role |
|---|---|
| `.github/workflows/bluebic-runner.yml` | `workflow_dispatch` entrypoint + step orchestration |
| `scripts/bluebic/prepare.mjs` | resolve target repo; pull failed-chat context (MCP, supabase fallback); assemble `/tmp/bluebic/PROMPT.md` (verbatim system prompt + injected context) |
| `scripts/bluebic/ship.mjs` | inspect the committed diff, detect sensitive paths, push the branch, `gh pr create`; write `/tmp/bluebic/RESULT.json` |
| `scripts/bluebic/report.mjs` | PATCH the dashboard callback with status |
| `scripts/bluebic/repo-map.mjs` | static `failure_mode → target repo` map (the BlueBic allowlist) |

## Job status machine

```
QUEUED ─(runner claims)→ RUNNING → PR_OPEN        fix shipped, PR open
                                 ├→ NO_FIX         not a code bug (provider/misconfig); empty diff
                                 ├→ NEEDS_REVIEW   touched auth/secrets/env/migrations/IAM → DRAFT PR
                                 └→ FAILED         runner error / 3 cycles still red, no PR
```

## Target-repo allowlist

`repo-map.mjs` only ever emits two repos, both owned by `bluejay-ai-dev`:

- `bluejay_middleware` — tool/integration, prompt/instruction-following, guardrails, handoff, state-tracking, triage
- `knowledge_base` — KB/RAG/grounding content (`knowledge_gap`)

Keeping the map to these two keeps `BLUEBIC_GH_TOKEN`'s repo scope minimal and
auditable. Expand the map later from the live `ErrorCode` distribution.

## Required CI secrets (names only — set these on the `bluejay-github-actions` repo)

| Name | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Claude Code Action auth (the agentic step) |
| `BLUEBIC_GH_TOKEN` | PAT with `contents:write` + `pull_requests:write` on the repo allowlist, and `read` on `knowledge_base` — checkout, push, `gh pr create` |
| `BLUEBIC_CALLBACK_URL` | Dashboard base URL the runner PATCHes (e.g. `https://<dashboard-host>`) |
| `BLUEBIC_CALLBACK_TOKEN` | Shared secret for the PATCH callback — **must equal** the dashboard's `BLUEBIC_CALLBACK_TOKEN` |
| `BLUEJAY_MCP_URL` | Bluejay MCP server base URL (transcript + metrics read) |
| `BLUEJAY_MCP_TOKEN` | Scoped Supabase bearer for the runner's data read |
| `SUPABASE_URL` | *(optional)* degraded fallback read when MCP is unreachable |
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

- Never pushes to `main` / `dev` / `master` — `ship.mjs` refuses to ship from a protected branch, and the prompt forbids it.
- Never `--force` / `--no-verify` / `--amend`; plain `git push` only.
- One diagnosis + ≤3 fix/verify cycles, enforced by `--max-turns 40` + the 30-minute `timeout-minutes` wall.
- Sensitive paths (`auth*`, `*secret*`, `*env*`, `migrations/`, `*iam*`) → DRAFT PR + `NEEDS_REVIEW`.
- Empty diff → `NO_FIX` (the agent is told to make no edits when the failure isn't a Bluejay code bug).
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
