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
| `nightly.yml` | 09:00 UTC | runs the suite against prod, pages on red, silent on amber |

## Scripts

| Script | Does |
| --- | --- |
| `bin/checks.sh` | one subcommand per deterministic check |
| `bin/gate.sh` | siblings, closure, and `order` (merge tiers from `.release/order.yml`) |
| `bin/enqueue.sh` | readiness, tier ordering, squash merge, deploy waits, rollback |
| `bin/suite.sh` | the integration suite, one subcommand per part |
| `bin/*.mjs` | playwright walks and their stub-server tests |

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

**Squash merges only**, so a revert is one commit and not a `-m 1` guess.

## Exit codes, shared by suite.sh and enqueue.sh

`0` pass, `1` regression, `2` usage, `3` fixtures or prereqs missing, `4` provider config
red, `5` amber. Fixture-missing is deliberately not a regression: if a data rebuild turns a
gate red, people learn to override it, and then it is worse than no gate.

## Before anything can actually run

- Org secrets `LINEAR_API_KEY`, `INFISICAL_TOKEN`, `RAILWAY_TOKEN`; `suite.sh preflight` is
  the manifest and cannot drift from the code.
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
