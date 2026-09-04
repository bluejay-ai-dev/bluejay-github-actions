#!/usr/bin/env bash
# Merge every PR on a ticket, in dependency order, or none of them.
#
#   enqueue.sh run <ENG-123> [order]     merge the batch
#   enqueue.sh check <ENG-123> [order]   what it would do, no writes
#   enqueue.sh tiers <ENG-123> [order]   just the resolved order
#   enqueue.sh aliases                   short names for the order field
#
# order overrides .release/order.yml for this run. The list IS the order: each entry waits
# for the one before it. Join with + to send several together, and use the short names:
#   "mw lk+tx fe"     is middleware, then livekit and text agent together, then frontend
# `enqueue.sh aliases` prints them. Merging triggers the deploy, so this is deploy order.
#
# Exit: 0 merged | 1 batch not ready | 2 usage | 3 a merge failed and was reverted
#
# Squash merges only, so a revert is one commit and not a -m 1 guess.
set -uo pipefail

ORG=${ORG:-bluejay-ai-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY_TIMEOUT=${DEPLOY_TIMEOUT:-900}
NO_SIGNAL_OK=${NO_SIGNAL_OK:-90}

# Short names, so nobody types bluejay_frontend_v2 into a form. Same prefixes we already
# use posting PRs to #pr-reviews.
alias_for() {
  case "$1" in
    mw)     echo bluejay_middleware ;;
    fe)     echo bluejay_frontend_v2 ;;
    lk)     echo livekit_agent ;;
    tx)     echo text_agent ;;
    ev)     echo evals ;;
    ld)     echo livekit_dispatcher ;;
    em)     echo emails-lambda ;;
    ga)     echo bluejay-github-actions ;;
    local)  echo bluejay-local ;;
    docs)   echo docs ;;
    *)      echo "$1" ;;
  esac
}
expand_order() { # rewrite short names, keep + and spacing
  local out="" tok part first
  for tok in $1; do
    part=""; first=1
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      [ "$first" = 1 ] && part="$(alias_for "$x")" || part="$part+$(alias_for "$x")"
      first=0
    done < <(tr '+' '\n' <<<"$tok")
    out="$out $part"
  done
  printf '%s' "${out# }"
}

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

open_prs() { # <ticket> -> "repo<TAB>number" for every OPEN PR carrying it
  gh search prs --owner "$ORG" --match title "$1" --state open --limit 50 \
     --json repository,number,title \
     -q ".[] | select(.title | test(\"\\\\b$1\\\\b\")) | [.repository.name, .number] | @tsv"
}

# Green means every check reported success. A null conclusion is a check still running,
# which is not success; treating it as one is how a gate passes a batch nobody validated.
pr_state() { # <repo> <num> -> "mergeable review failing"
  gh pr view "$2" -R "$ORG/$1" \
    --json mergeable,reviewDecision,statusCheckRollup \
    -q '[(.mergeable // "UNKNOWN"),
         ((.reviewDecision // "") | if . == "" then "NONE" else . end),
         ([.statusCheckRollup[]? | (.conclusion // .state // "PENDING") | ascii_upcase
           | select(IN("SUCCESS","NEUTRAL","SKIPPED") | not)] | length | tostring)]
        | @tsv'
}

ready() { # <ticket> -> 0 when every sibling can merge
  local id=$1 bad=0 this repo num st mergeable review failing n=0
  while IFS=$'\t' read -r repo num; do
    [ -n "${repo:-}" ] || continue
    n=$((n + 1)); this=0
    st=$(pr_state "$repo" "$num") || { warn "$repo#$num: cannot read state"; bad=1; continue; }
    IFS=$'\t' read -r mergeable review failing <<<"$st"
    [ "$mergeable" = MERGEABLE ] || { warn "$repo#$num: $mergeable"; this=1; }
    [ "$review" = APPROVED ]     || { warn "$repo#$num: review $review"; this=1; }
    [ "$failing" = 0 ]           || { warn "$repo#$num: $failing checks not green"; this=1; }
    [ "$this" = 0 ] && say "  ok $repo#$num" || bad=1
  done < <(open_prs "$id")
  # No PRs at all is not a ready batch: it means the id is wrong.
  [ "$n" -gt 0 ] || { warn "no open PRs carry $id"; return 1; }
  return $bad
}

# Some repos never deploy: docs publishes through Mintlify and has no workflows at all,
# and most of the org is the same. Waiting on a signal that cannot arrive costs every batch
# the grace period and teaches people that a skipped wait is normal.
deploys() { # <repo> -> 0 when this repo is expected to produce a deploy signal
  local v
  v=$(gh api "repos/$ORG/$1/contents/.release/order.yml" --jq .content 2>/dev/null \
      | base64 -d 2>/dev/null | sed -n 's/^deploys:[[:space:]]*//p' | tr -d '[:space:]')
  [ "$v" != false ]
}

# Poll by sha. No signal is a warning, not a pass: a repo whose deploy never starts looks
# identical to one that has none for the first minute, which is what `deploys` settles.
wait_deploy() { # <repo> <sha>
  local repo=$1 sha=$2 end=$((SECONDS + DEPLOY_TIMEOUT)) seen=0 st
  while [ $SECONDS -lt "$end" ]; do
    st=$(gh run list -R "$ORG/$repo" --commit "$sha" --limit 20 \
         --json status,conclusion -q '[.[]|select(.status!="completed")]|length' 2>/dev/null)
    if [ -n "${st:-}" ]; then
      seen=1
      if [ "$st" = 0 ]; then
        local bad
        bad=$(gh run list -R "$ORG/$repo" --commit "$sha" --limit 20 --json conclusion \
              -q '[.[]|select(.conclusion!=null and .conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral")]|length' 2>/dev/null)
        [ "${bad:-1}" = 0 ] && { say "  $repo deploy green"; return 0; }
        warn "  $repo has $bad failing run(s) on $sha"; return 1
      fi
    fi
    [ "$seen" = 0 ] && [ $SECONDS -gt $((end - DEPLOY_TIMEOUT + NO_SIGNAL_OK)) ] && {
      say "  $repo reports no deploy signal, continuing"; return 0; }
    sleep 10
  done
  warn "  $repo deploy did not finish in ${DEPLOY_TIMEOUT}s"
  return 1
}

# Reverse order, and only what actually landed. A squash merge is one commit, so this is a
# plain revert with no parent to guess at.
rollback() { # <"repo:sha" ...>
  local entry repo sha i
  for (( i=$#; i>0; i-- )); do
    entry=${!i}; repo=${entry%%:*}; sha=${entry##*:}
    warn "reverting $repo $sha"
    local d; d=$(mktemp -d)
    if git clone -q --depth 20 "https://x-access-token:${GH_TOKEN}@github.com/$ORG/$repo" "$d" 2>/dev/null \
       && git -C "$d" revert --no-edit "$sha" >/dev/null 2>&1 \
       && git -C "$d" push -q origin HEAD:main 2>/dev/null; then
      warn "  reverted $repo"
    else
      warn "  COULD NOT REVERT $repo $sha, main still carries it"
    fi
    rm -rf "$d"
  done
}

# Declared order unless the caller named one. An override is echoed in full so the run
# log says which order was used, rather than leaving it to whoever reads it later.
tiers_for() { # <ticket> [override]
  local id=$1 override=${2:-} repos named missing t
  if [ -z "$override" ]; then
    ORG="$ORG" "$HERE/gate.sh" order "$id"
    return
  fi
  override=$(expand_order "$override")
  repos=$(open_prs "$id" | cut -f1 | sort -u)
  named=$(tr '+' ' ' <<<"$override" | tr -s ' ' '\n' | sed '/^$/d' | sort -u)
  # A typo here would silently drop a repo out of the batch, so refuse instead.
  for t in $named; do
    grep -qx "$t" <<<"$repos" || { warn "override names $t, which has no open PR on $id"; return 1; }
  done
  missing=$(comm -23 <(printf '%s\n' $repos) <(printf '%s\n' $named))
  [ -z "$missing" ] || { warn "override leaves out: $(tr '\n' ' ' <<<"$missing")"; return 1; }
  tr -s ' ' '\n' <<<"$override" | sed '/^$/d' | tr '+' ' '
}

cmd_check() {
  local id=${1:-}; [ -n "$id" ] || { warn "usage: enqueue.sh check <ENG-123> [order]"; exit 2; }
  say "batch $id"
  ready "$id" || die "batch is not ready"
  say "merge and deploy order${2:+ (overridden)}:"
  tiers_for "$id" "${2:-}" | nl -ba -w4 -s'  ' || die "bad order"
}

cmd_run() {
  local id=${1:-}; [ -n "$id" ] || { warn "usage: enqueue.sh run <ENG-123> [order]"; exit 2; }
  say "batch $id"
  ready "$id" || die "batch is not ready, nothing merged"

  # The design says a batch is proved against an environment before it merges. That
  # environment does not exist yet (previews moved to full stacks, blocked on the CI IAM
  # role), so this is opt-in rather than pretended: set SUITE_URL and it runs, leave it
  # unset and enqueue merges on the PR checks alone and says so.
  if [ -n "${SUITE_URL:-}" ]; then
    say "proving the batch against $SUITE_URL"
    "$HERE/suite.sh" run "$SUITE_URL" "${SUITE_API_URL:-}" || {
      "$HERE/notify.sh" kicked-back "$id" "the suite failed against $SUITE_URL" || true
      die "suite failed, nothing merged"; }
  else
    say "no SUITE_URL: merging on PR checks alone, the batch is not proved against an environment"
  fi

  local -a landed=()
  local tier repo num sha
  while read -r tier; do
    [ -n "$tier" ] || continue
    say "tier: $tier"
    for repo in $tier; do
      num=$(open_prs "$id" | awk -F'\t' -v r="$repo" '$1==r{print $2; exit}')
      [ -n "$num" ] || { say "  $repo has no PR on $id, skipping"; continue; }
      if ! gh pr merge "$num" -R "$ORG/$repo" --squash --delete-branch >/dev/null 2>&1; then
        warn "  $repo#$num FAILED to merge"
        rollback "${landed[@]}"
        "$HERE/notify.sh" kicked-back "$id" "$repo#$num would not merge; anything already landed was reverted" || true
        exit 3
      fi
      sha=$(gh api "repos/$ORG/$repo/commits/main" -q .sha 2>/dev/null)
      landed+=("$repo:$sha")
      say "  merged $repo#$num as $sha"
    done
    for repo in $tier; do
      grep -q "^$repo:" <<<"$(printf '%s\n' "${landed[@]}")" || continue
      sha=$(printf '%s\n' "${landed[@]}" | awk -F: -v r="$repo" '$1==r{print $2}' | tail -1)
      if deploys "$repo"; then
        wait_deploy "$repo" "$sha" || {
          rollback "${landed[@]}"
          "$HERE/notify.sh" kicked-back "$id" "$repo did not deploy cleanly; the batch was reverted" || true
          exit 3; }
      else
        say "  $repo does not deploy, not waiting"
      fi
    done
  done < <(tiers_for "$id" "${2:-}")

  say "batch $id merged: ${#landed[@]} repo(s)"
  # Told last, and never fatal: the batch has merged either way, and failing the run
  # because Slack was down would misreport what happened.
  "$HERE/notify.sh" merged "$id" "$(printf '%s ' "${landed[@]%%:*}")" || true
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  tiers) shift; tiers_for "$@" ;;
  aliases) for a in mw fe lk tx ev ld em ga local docs; do printf '  %-6s %s\n' "$a" "$(alias_for "$a")"; done ;;
  check) shift; cmd_check "$@" ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
