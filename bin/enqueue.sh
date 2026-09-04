#!/usr/bin/env bash
# Merge every PR on a ticket, in dependency order, or none of them.
#
#   enqueue.sh run <ENG-123>     merge the batch
#   enqueue.sh check <ENG-123>   what it would do, no writes
#
# Exit: 0 merged | 1 batch not ready | 2 usage | 3 a merge failed and was reverted
#
# Squash merges only, so a revert is one commit and not a -m 1 guess.
set -uo pipefail

ORG=${ORG:-bluejay-ai-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY_TIMEOUT=${DEPLOY_TIMEOUT:-900}
NO_SIGNAL_OK=${NO_SIGNAL_OK:-90}

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

# Poll by sha. No signal at all is a warning, not a pass: a repo with no deploy is normal,
# a repo whose deploy never starts is not, and the two look identical for the first minute.
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

cmd_check() {
  local id=${1:-}; [ -n "$id" ] || { warn "usage: enqueue.sh check <ENG-123>"; exit 2; }
  say "batch $id"
  ready "$id" || die "batch is not ready"
  say "merge order:"
  ORG="$ORG" "$HERE/gate.sh" order "$id" | nl -ba -w4 -s'  '
}

cmd_run() {
  local id=${1:-}; [ -n "$id" ] || { warn "usage: enqueue.sh run <ENG-123>"; exit 2; }
  say "batch $id"
  ready "$id" || die "batch is not ready, nothing merged"

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
        exit 3
      fi
      sha=$(gh api "repos/$ORG/$repo/commits/main" -q .sha 2>/dev/null)
      landed+=("$repo:$sha")
      say "  merged $repo#$num as $sha"
    done
    for repo in $tier; do
      grep -q "^$repo:" <<<"$(printf '%s\n' "${landed[@]}")" || continue
      sha=$(printf '%s\n' "${landed[@]}" | awk -F: -v r="$repo" '$1==r{print $2}' | tail -1)
      wait_deploy "$repo" "$sha" || { rollback "${landed[@]}"; exit 3; }
    done
  done < <(ORG="$ORG" "$HERE/gate.sh" order "$id")

  say "batch $id merged: ${#landed[@]} repo(s)"
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
