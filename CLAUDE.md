# bluejay-github-actions

Shared CI for the org. Nothing here runs on its own: the workflows are `workflow_call`,
`workflow_dispatch` or `schedule`, and app repos hold a thin caller that is dormant behind
a `gating-trial` label.

## The flow, end to end

Branch off `main` → one PR per repo, each titled `[ENG-123]` → `pr-checks` refuses to pass
any of them until every sibling on that id is green → reviewer approves each → run
`enqueue` with the ticket → it merges them all in dependency order or none of them →
`nightly` runs the suite against prod afterwards.

The ticket id in the PR title is the only thing that groups PRs across repos. There is no
manifest and nothing external in the merge path.

## Workflows

| File | Trigger | Does |
| --- | --- | --- |
| `pr-checks.yml` | `workflow_call` | ticket gate, sibling gate, build, deterministic checks |
| `enqueue.yml` | manual | merges a whole ticket in order, or nothing |
| `hotfix.yml` | manual | one PR straight to main, for incidents, still needs green checks |
| `nightly.yml` | manual only | runs the suite against prod. The 09:00 UTC schedule is commented out until `TEST_SUITE_*` exists, because a run with no fixtures dies at preflight and a workflow that goes red every morning teaches people to ignore red |

## Scripts

| Script | Does |
| --- | --- |
| `bin/checks.sh` | one subcommand per deterministic check |
| `bin/gate.sh` | siblings, closure, and `order` (merge tiers from `.release/order.yml`) |
| `bin/enqueue.sh` | readiness, tier ordering, squash merge, deploy waits, rollback |
| `bin/suite.sh` | the integration suite, one subcommand per part |
| `bin/notify.sh` | DMs the authors on a ticket and moves it to Needs Prod Testing |
| `bin/people.tsv` | github login to slack user id; a missing row falls back to the channel |
| `bin/*.mjs` | playwright walks |

## Things that will bite you

**A reusable workflow's `actions/checkout` fetches the CALLER, not this repo.** `pr-checks`
checks this repo out separately at `${{ github.job_workflow_sha }}` and runs
`.gating/bin/checks.sh`. That is also what stops a PR editing the script that holds the
secrets. Do not "simplify" it back to one checkout.

**Never interpolate `${{ github.event.* }}` or `${{ inputs.* }}` into a `run:` block.** Put
it in `env:` and reference the variable. Both have been live injection holes here.

**A null `conclusion` is a check still running, not a pass.** Anything reading
`statusCheckRollup` must use `(.conclusion // .state // "PENDING")`. Treating null as
success is how the sibling gate passed batches nobody had validated.

**Fail closed.** A gate that cannot determine an answer must fail, not pass. `|| true` on a
`gh search` once turned the cross-repo gate into a no-op that reported green.

**`need` inside `$( )` exits the subshell, not the script.** Write
`x=$(need FOO) || return $E_FIXTURE`.

**Squash is NOT enforced.** All nine repos still allow merge commits, so `enqueue.sh`
counts a commit's parents and passes `-m 1` only when it has two. Do not simplify that away
until a ruleset actually enforces squash.

**The runner's awk is mawk, which has no `\<` `\>` word boundaries.** A filter using them
matched zero rows, so the cross-repo sibling check silently passed with `found=0` for its
whole life. Use `(^|[^A-Z0-9])ID([^0-9]|$)`. This is the single worst bug this gate has had,
and it looked healthy the entire time.

**Compare like with like against Linear.** Attachments stay on a ticket after its PR merges,
so comparing them to open PRs only makes every shipped ticket look like it is hiding work.
The search side has to span every state.

**Prisma needs `DIRECT_URL` as well as `DATABASE_URL`.** `prisma.config` resolves it and
throws when unset even though `generate` never connects, which killed `codegen` with a bare
exit 2 and no message, and killed `build` inside `npm ci`'s postinstall.

## Exit codes, shared by suite.sh and enqueue.sh

`0` pass, `1` regression, `2` usage, `3` fixtures or prereqs missing, `4` provider config
red, `5` amber. Fixture-missing is deliberately not a regression: if a data rebuild turns a
gate red, people learn to override it, and then it is worse than no gate.

## How the callers are wired right now

Every caller reads `pr-checks.yml@main`, not a pinned sha, so anything merged here reaches
all eight repos immediately. That is deliberate: a pin froze the gate at the commit it
shipped on. The tradeoff is real, `secrets: inherit` means whoever can push this repo's main
can change the code receiving every secret in those repos. It is acceptable only while the
`gating-trial` label keeps the gate off ordinary PRs. Pin a sha again before that label
comes off.

A re-run replays the workflow version pinned when the run was created, so `@main` does not
re-resolve on a re-run. Push an empty commit to get a fresh one.

## Merging from the dashboard

The internal dashboard has a **Releases** page under Development. Search a ticket, a number,
a repo or words from a PR title, drag the sequence to change merge order, and dispatch with
dry run on by default. It fires this repo's `enqueue` workflow, so it is the same code path
as the Actions tab. Reads use `GITHUB_TOKEN`, the dispatch uses `BLUEBIC_DISPATCH_TOKEN`,
which is `actions:write` on this repo only and cannot read anything else.

## Before anything can actually run

- `LINEAR_API_KEY` and `SANDBOX_GH_TOKEN` are set on all eight app repos. Without them the
  gate fails closed and says which one is missing, rather than passing blind.
- `INFISICAL_TOKEN` and `RAILWAY_TOKEN` are still unset. The build job skips the Infisical
  step when absent, so this degrades rather than breaking.
- `suite.sh preflight` is the manifest for the suite's own fixtures and cannot drift from
  the code. `TEST_SUITE_*` does not exist yet, which is why the nightly schedule is
  commented out.
- A GitHub App as the only bypass actor on the main ruleset, `MERGE_APP_ID` and
  `MERGE_APP_PRIVATE_KEY`. Without it `enqueue check` works and `enqueue run` cannot merge.
- Neither middleware nor the frontend exposes a deployed SHA, so `suite.sh sha` exits 3
  rather than passing. It fails closed on purpose.

## Testing without touching anything

```
bin/suite.sh selftest              offline, no fixtures, no credentials
bin/enqueue.sh check ENG-123       readiness and resolved order, no writes
bin/enqueue.sh tiers ENG-123       just the order
bin/gate.sh order ENG-123          merge tiers from each repo's order.yml
```
