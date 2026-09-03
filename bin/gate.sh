#!/usr/bin/env bash
# Release gating. One script, three commands, no state anywhere.
#   gate.sh siblings <repo> <pr>   PRs elsewhere sharing this PR's ticket
#   gate.sh closure  <repo>        repos+tickets a dev->main promotion pulls in
#   gate.sh page     [out.html]    what is sitting on dev, org-wide
set -euo pipefail

ORG=${ORG:-bluejay-ai-dev}
# Deploy order: whoever tolerates the other being old goes first. Frontend last.
ORDER=${ORDER:-"bluejay_middleware livekit_agent text_agent evals docs bluejay_frontend_v2"}

CACHE=${CACHE:-$(mktemp -d)}
# Search tokenizes on the hyphen, so always re-filter titles ourselves.
prs_for() {
  [ -s "$CACHE/$1" ] || \
  gh search prs --owner "$ORG" --match title "$1" --limit 50 \
     --json repository,number,state,title,url,labels \
     -q ".[] | select(.title | test(\"\\\\b$1\\\\b\")) |
         [.repository.name, .number, .state, .title,
          ([.labels[].name] | join(\",\"))] | @tsv" > "$CACHE/$1"
  cat "$CACHE/$1"
}
open_prs_for() { prs_for "$1" | awk -F'\t' 'tolower($3)=="open"'; }

tickets_on_dev() {
  gh api "repos/$ORG/$1/compare/main...dev" -q '.commits[].commit.message' 2>/dev/null \
    | grep -oE '\bENG-[0-9]+\b' | sort -u
}

order_repos() {  # stdin: repos. Unlisted land just before the frontend tier.
  local all; all=$(cat)
  for r in $ORDER; do grep -qx "$r" <<<"$all" && [ "$r" != bluejay_frontend_v2 ] && echo "$r"; done
  grep -vxF -f <(printf '%s\n' $ORDER) <<<"$all" || true
  grep -qx bluejay_frontend_v2 <<<"$all" && echo bluejay_frontend_v2 || true
}

cmd_siblings() {
  local title id
  title=$(gh pr view "$2" -R "$ORG/$1" --json title -q .title)
  id=$(grep -oE '\bENG-[0-9]+\b' <<<"$title" | head -1 || true)
  [ -z "$id" ] && { echo "no ticket in title, ungated"; return 0; }
  echo "$id  ($title)"
  open_prs_for "$id" | while IFS=$'\t' read -r repo num state _ labels; do
    [ "$repo/$num" = "$1/$2" ] && continue
    printf '  %-24s #%-6s %-6s %s\n' "$repo" "$num" "$state" "$labels"
  done
}

cmd_closure() {
  local repos="$1" quiet="${2:-}" seen="" changed=1 blocked=0
  while [ $changed = 1 ]; do
    changed=0
    for repo in $repos; do
      for id in $(tickets_on_dev "$repo"); do
        grep -qw "$id" <<<"$seen" && continue
        seen="$seen $id"; changed=1
        for r in $(prs_for "$id" | cut -f1 | sort -u); do
          grep -qw "$r" <<<"$repos" || { repos="$repos $r"; }
        done
      done
    done
  done

  if [ "$quiet" = --repos ]; then
    printf '%s\n' $repos | sort -u | order_repos | tr '\n' ' '; echo; return 0
  fi

  echo "tickets riding dev:"
  for id in $seen; do
    local hold open
    hold=$(prs_for "$id" | cut -f5 | grep -c do-not-promote || true)
    open=$(open_prs_for "$id" | wc -l | tr -d ' ')
    printf '  %-10s %-40s' "$id" "$(prs_for "$id" | head -1 | cut -f4 | cut -c1-40)"
    [ "$hold" -gt 0 ] && { printf ' HOLD'; blocked=1; }
    # Rolling tickets (relands, follow-ups) always have open PRs. Warn, do not block.
    [ "$open" -gt 0 ] && printf ' warn: %s still open' "$open"
    echo
  done
  echo
  echo "promote in this order:"
  printf '%s\n' $repos | sort -u | order_repos | sed 's/^/  /'
  [ $blocked = 1 ] && { echo; echo "BLOCKED"; return 1; }
  echo; echo "READY"
}

cmd_page() {
  local out=${1:-/tmp/release-gating.html}
  gh search prs --owner "$ORG" --state open --limit 100 \
     --json repository,number,title,url,labels,isDraft \
     -q '.[] | [.repository.name, .number, .title, .url,
                ([.labels[].name]|join(",")), (.isDraft|tostring)] | @tsv' > "$CACHE/open.tsv"

  # dev rows: anything promoted-pending, per repo
  : > "$CACHE/dev.tsv"
  for repo in $ORDER; do
    for id in $(tickets_on_dev "$repo"); do printf '%s\t%s\n' "$id" "$repo" >> "$CACHE/dev.tsv"; done
  done

  ORG="$ORG" python3 "$(dirname "$0")/page.py" "$CACHE/open.tsv" "$CACHE/dev.tsv" "$out"
  echo "$out"
}

case "${1:-}" in
  siblings) shift; cmd_siblings "$@" ;;
  closure)  shift; cmd_closure "$@" ;;
  page)     shift; cmd_page "$@" ;;
  *) sed -n '2,5p' "$0"; exit 1 ;;
esac
