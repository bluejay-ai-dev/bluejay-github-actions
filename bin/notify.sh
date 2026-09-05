#!/usr/bin/env bash
# Tells the person who shipped, and moves their ticket.
#
#   notify.sh merged <ENG-123> <repo...>        DM the authors, ticket -> Needs Prod Testing
#   notify.sh kicked-back <ENG-123> <reason>    DM the authors, ticket stays put
#   notify.sh render <ENG-123> <repo...>        print the message, send nothing
#
# Never fatal. A batch that merged has merged; failing the run because Slack was down
# would be a lie about what happened.
set -uo pipefail

ORG=${ORG:-bluejay-ai-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
# Optional. Only used to surface an author we have no Slack mapping for; prod health
# pages through its own path and does not come here.
CHANNEL=${SLACK_FALLBACK_CHANNEL:-}
NEEDS_PROD_TESTING=e502e9ad-e870-4c68-9454-50bcfeb72451

warn() { printf '%s\n' "$*" >&2; }

slack_for() { # <github login> -> slack user id, or empty
  awk -F'\t' -v u="$(tr '[:upper:]' '[:lower:]' <<<"$1")" \
    'tolower($1)==u {print $2; exit}' "$HERE/people.tsv" 2>/dev/null
}

authors_of() { # <ticket> -> github logins of everyone with an open or merged PR on it
  gh search prs --owner "$ORG" --match title "$1" --limit 50 --json author,title \
    -q ".[] | select(.title | test(\"\\\\b$1\\\\b\")) | .author.login" 2>/dev/null | sort -u
}

post() { # <slack target> <text>
  [ -n "${SLACK_BOT_TOKEN:-}" ] || { warn "SLACK_BOT_TOKEN unset, nobody was told"; return 0; }
  curl -sS --max-time 20 https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H 'Content-type: application/json; charset=utf-8' \
    -d "$(jq -nc --arg c "$1" --arg t "$2" '{channel:$c,text:$t}')" \
    | jq -e '.ok' >/dev/null || warn "slack rejected the post to $1"
}

# DM everyone who has a PR on the ticket; fall back to the channel for anyone unmapped, so
# an unknown author is visible rather than silently unreachable.
tell() { # <ticket> <text>
  local id=$1 text=$2 login target unmapped=""
  while read -r login; do
    [ -n "$login" ] || continue
    target=$(slack_for "$login")
    if [ -n "$target" ]; then post "$target" "$text"
    else unmapped="$unmapped $login"; fi
  done < <(authors_of "$id")
  [ -z "$unmapped" ] || {
    warn "no slack mapping for:$unmapped"
    [ -n "$CHANNEL" ] && post "$CHANNEL" "$text (could not DM:$unmapped)"
  }
}

linear_state() { # <ticket> <state id>
  [ -n "${LINEAR_API_KEY:-}" ] || { warn "LINEAR_API_KEY unset, ticket not moved"; return 0; }
  # The query lives in its own quoted variable. Inline, the shell brace-expands
  # `{issueUpdate(id:$i,input:...)}` at the comma and runs jq twice on two half-programs.
  local r q
  q='mutation($i:String!,$s:String!){issueUpdate(id:$i,input:{stateId:$s}){success}}'
  r=$(curl -sS --max-time 20 https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" -H 'content-type: application/json' \
    -d "$(jq -nc --arg q "$q" --arg i "$1" --arg s "$2" \
      '{query:$q,variables:{i:$i,s:$s}}')")
  jq -e '.data.issueUpdate.success' <<<"$r" >/dev/null \
    || warn "linear did not move $1: $(jq -c '.errors[0].message // .' <<<"$r" 2>/dev/null)"
}

# Any state, because by the time this runs the PRs are merged and closed.
prs_for() { # <ticket> -> "<repo>#<num> <url>" per line
  gh search prs --owner "$ORG" --match title "$1" --limit 50 --json repository,number,title,url \
    -q ".[] | select(.title | test(\"\\\\b$1\\\\b\")) | \"\(.repository.name)#\(.number) \(.url)\"" 2>/dev/null | sort
}

links_for() { # <ticket> -> indented list, empty when the search fails
  local out; out=$(prs_for "$1")
  [ -n "$out" ] || return 0
  printf '\n\n'; while read -r ref url; do printf '%s\n' "$url"; done <<<"$out"
}

run_link() {
  [ -n "${GITHUB_RUN_ID:-}" ] || return 0
  printf '\n%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-}" "$GITHUB_RUN_ID"
}

msg_merged() {
  printf ':white_check_mark: %s shipped, please test in production https://app.getbluejay.ai\n%s' \
    "$1" "$(links_for "$1")"
}
msg_kicked_back() {
  # STILL_ON_MAIN breaks the terse format on purpose: a revert that failed means main is
  # carrying code nobody signed off, and that must not be one line in a log somewhere.
  printf ':x: %s kicked back%s\n%s' "$1" \
    "${STILL_ON_MAIN:+ :rotating_light: could not revert:$STILL_ON_MAIN}" "$(links_for "$1")"
}

case "${1:-}" in
  merged)
    id=${2:?ticket}; shift 2
    tell "$id" "$(msg_merged "$id" "$*")"
    linear_state "$id" "$NEEDS_PROD_TESTING" ;;
  kicked-back)
    id=${2:?ticket}; shift 2
    tell "$id" "$(msg_kicked_back "$id" "$*")" ;;
  render)
    id=${2:?ticket}; shift 2
    echo "--- to: $(authors_of "$id" | tr '\n' ' ')"
    msg_merged "$id" "$*"; echo ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
