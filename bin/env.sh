#!/usr/bin/env bash
# One environment per ticket. Per repo: the ticket's open PR image if there is
# one, otherwise the image production is already running.
#   env.sh up           <name> "<ENG-1 ENG-2>"
#   env.sh down         <name>
#   env.sh down-if-last <name> <ENG-1>
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$HERE/railway-map.sh"

OWNER=${OWNER:-lorenzotaylor-bluejay}
STACK=${STACK:-"shipflow-middleware shipflow-worker shipflow-frontend"}
LAST=${LAST:-shipflow-frontend}
REGISTRY=${REGISTRY:-ghcr.io}
DEPLOY_TIMEOUT=${DEPLOY_TIMEOUT:-600}
API=https://backboard.railway.com/graphql/v2
: "${RAILWAY_TOKEN:?RAILWAY_TOKEN is not set}"

gql() {
  local out
  out=$(curl -sS "$API" -H "Authorization: Bearer $RAILWAY_TOKEN" \
        -H 'content-type: application/json' \
        --data-binary "$(jq -nc --arg q "$1" --argjson v "${2:-null}" '{query:$q,variables:($v // {})}')")
  if jq -e 'has("errors")' <<<"$out" >/dev/null; then
    echo "railway: $(jq -c .errors <<<"$out")" >&2
    return 1
  fi
  printf '%s' "$out"
}

env_id() {
  gql 'query($p:String!){project(id:$p){environments{edges{node{id name}}}}}' \
      "$(jq -nc --arg p "$RAILWAY_PROJECT_ID" '{p:$p}')" \
    | jq -r --arg n "$1" 'first(.data.project.environments.edges[].node|select(.name==$n)|.id) // ""'
}

SERVICES=""
svc_id() {
  [ -n "$SERVICES" ] || SERVICES=$(gql 'query($p:String!){project(id:$p){services{edges{node{id name}}}}}' \
      "$(jq -nc --arg p "$RAILWAY_PROJECT_ID" '{p:$p}')")
  jq -r --arg n "$1" 'first(.data.project.services.edges[].node|select(.name==$n)|.id) // ""' <<<"$SERVICES"
}

instance() {
  gql 'query($s:String!,$e:String!){serviceInstance(serviceId:$s,environmentId:$e){source{image} domains{serviceDomains{domain}}}}' \
      "$(jq -nc --arg s "$1" --arg e "$2" '{s:$s,e:$e}')"
}

# Flat one-level yaml only, which is all .release/order.yml ever is. Keeps this
# runnable on a laptop without yq.
cfg() { sed -n "s/^$2:[[:space:]]*//p" <<<"$1" | head -1 | tr -d '"'"'"' '; }

order_yml() {
  gh api "repos/$OWNER/$1/contents/.release/order.yml?ref=main" -q .content 2>/dev/null | base64 -d || true
}

# The ticket id is the whole contract, so match it as a word: ENG-6 is not ENG-60.
# A branch ending in --np opts out. Skipped here as well as in preview.yml, because the
# environment is per TICKET: without this, a sibling repo's PR would still spin the
# environment up and pull the opted-out branch into it, which is the opposite of what
# someone asking for no preview meant.
pr_head() {
  local repo=$1 id
  shift
  for id in "$@"; do
    gh pr list -R "$OWNER/$repo" --state open --limit 50 --json number,title,headRefName,headRefOid \
      -q "first(.[]|select((.title|test(\"(^|[^A-Za-z0-9])$id([^0-9]|\$)\";\"i\")) and (.headRefName|endswith(\"--np\")|not))|.headRefOid) // \"\""
  done | grep -m1 . || true
}

prod_image() {
  local svc=$1 img
  img=$(instance "$svc" "$RAILWAY_ENVIRONMENT_ID" | jq -r '.data.serviceInstance.source.image // ""')
  [ -n "$img" ] && { echo "$img"; return; }
  echo "$REGISTRY/$OWNER/$2:main"
}

point_at() { # service env image
  local creds='null'
  [ -n "${GHCR_TOKEN:-}" ] && creds=$(jq -nc --arg u "${GHCR_USER:-$OWNER}" --arg p "$GHCR_TOKEN" '{username:$u,password:$p}')
  gql 'mutation($s:String!,$e:String!,$i:ServiceInstanceUpdateInput!){serviceInstanceUpdate(serviceId:$s,environmentId:$e,input:$i)}' \
      "$(jq -nc --arg s "$1" --arg e "$2" --arg img "$3" --argjson c "$creds" \
         '{s:$s,e:$e,i:({source:{image:$img},sleepApplication:true} + (if $c then {registryCredentials:$c} else {} end))}')" >/dev/null
}

# Railway's V2 runtime injects its own PORT. An image that honours PORT then listens
# somewhere the generated domain does not route to, and the edge answers 502 while the
# container is perfectly healthy and the deployment reports SUCCESS. Pin PORT to the port
# the domain targets so the two cannot disagree.
set_port() { # project env service port
  [ -n "$4" ] || return 0
  gql 'mutation($i:VariableUpsertInput!){variableUpsert(input:$i)}' \
      "$(jq -nc --arg p "$1" --arg e "$2" --arg s "$3" --arg v "$4" \
         '{i:{projectId:$p,environmentId:$e,serviceId:$s,name:"PORT",value:$v}}')" >/dev/null
}

ensure_domain() { # service env port
  local d
  d=$(instance "$1" "$2" | jq -r 'first(.data.serviceInstance.domains.serviceDomains[].domain) // ""')
  if [ -z "$d" ] && [ -n "$3" ]; then
    d=$(gql 'mutation($i:ServiceDomainCreateInput!){serviceDomainCreate(input:$i){domain}}' \
        "$(jq -nc --arg s "$1" --arg e "$2" --argjson p "$3" '{i:{serviceId:$s,environmentId:$e,targetPort:$p}}')" \
        | jq -r '.data.serviceDomainCreate.domain')
  fi
  echo "$d"
}

# A fresh Railway domain needs its certificate issued, which takes a minute or two and
# looks like a hang, so this polls rather than asking once.
answers() { # host
  local i c
  for i in $(seq 1 30); do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$1/" 2>/dev/null || echo 000)
    case "$c" in 000|502|503|504) ;; *) return 0 ;; esac
    sleep 10
  done
  return 1
}

deploy() {
  gql 'mutation($s:String!,$e:String!){serviceInstanceDeployV2(serviceId:$s,environmentId:$e)}' \
      "$(jq -nc --arg s "$1" --arg e "$2" '{s:$s,e:$e}')" | jq -r '.data.serviceInstanceDeployV2'
}

wait_deploy() { # deployment-id label
  local deadline=$(( $(date +%s) + DEPLOY_TIMEOUT )) st
  while [ "$(date +%s)" -lt "$deadline" ]; do
    st=$(gql 'query($d:String!){deployment(id:$d){status}}' "$(jq -nc --arg d "$1" '{d:$d}')" \
         | jq -r '.data.deployment.status')
    case "$st" in
      SUCCESS|SLEEPING) echo "  $2 $st"; return 0 ;;
      FAILED|CRASHED|REMOVED) echo "  $2 $st" >&2; return 1 ;;
    esac
    sleep 5
  done
  echo "  $2 timed out after ${DEPLOY_TIMEOUT}s" >&2
  return 1
}

up() {
  local name=$1 tickets=$2 eid repo yml svc sid pid sha img port dep url frontend=""
  eid=$(env_id "$name")
  if [ -z "$eid" ]; then
    eid=$(gql 'mutation($i:EnvironmentCreateInput!){environmentCreate(input:$i){id}}' \
      "$(jq -nc --arg p "$RAILWAY_PROJECT_ID" --arg n "$name" --arg s "$RAILWAY_ENVIRONMENT_ID" \
         '{i:{projectId:$p,name:$n,sourceEnvironmentId:$s,skipInitialDeploys:true}}')" \
      | jq -r '.data.environmentCreate.id')
    echo "created environment $name"
  else
    echo "reusing environment $name"
  fi

  local -a pending=()
  for repo in $STACK; do
    yml=$(order_yml "$repo")
    [ "$(cfg "$yml" preview)" = true ] || { echo "$repo: previews off"; continue; }
    svc=$(cfg "$yml" service)
    port=$(cfg "$yml" port)
    sid=$(svc_id "$svc-dev")
    pid=$(svc_id "$svc-prod")
    # A repo that opts into previews with no Railway service silently serves
    # prod forever, which reads as "my change did nothing". Fail instead.
    [ -n "$sid" ] || { echo "::error::$repo says preview: true but there is no Railway service '$svc-dev'"; return 1; }

    sha=$(pr_head "$repo" $tickets)
    if [ -n "$sha" ]; then
      img="$REGISTRY/$OWNER/$repo:$sha"
      echo "$repo: PR $sha"
    else
      img=$(prod_image "$pid" "$repo")
      echo "$repo: prod $img"
    fi

    point_at "$sid" "$eid" "$img"
    set_port "$RAILWAY_PROJECT_ID" "$eid" "$sid" "$port"
    url=$(ensure_domain "$sid" "$eid" "$port")
    dep=$(deploy "$sid" "$eid")
    pending+=("$dep|$repo|$url")
  done

  local ok=0 row
  for row in "${pending[@]}"; do
    IFS='|' read -r dep repo url <<<"$row"
    wait_deploy "$dep" "$repo" || ok=1
    # A SUCCESS deployment is not a working URL. A port mismatch, an unissued
    # certificate and a container that never binds all report SUCCESS and then serve
    # nothing, and handing someone a dead preview link is worse than failing here.
    if [ -n "$url" ] && ! answers "$url"; then
      echo "$repo: deployed but https://$url does not answer"
      ok=1
    fi
    [ -n "$url" ] && echo "$repo https://$url"
    [ "$repo" = "$LAST" ] && [ -n "$url" ] && frontend="https://$url"
  done
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "frontend_url=$frontend" >> "$GITHUB_OUTPUT"
  return $ok
}

down() {
  local eid; eid=$(env_id "$1")
  [ -n "$eid" ] || { echo "no environment $1"; return 0; }
  gql 'mutation($id:String!){environmentDelete(id:$id)}' "$(jq -nc --arg id "$eid" '{id:$id}')" >/dev/null
  echo "deleted environment $1"
}

down_if_last() {
  local repo n=0
  for repo in $STACK; do
    n=$(( n + $(gh pr list -R "$OWNER/$repo" --state open --limit 50 --json title \
        -q "[.[]|select(.title|test(\"(^|[^A-Za-z0-9])$2([^0-9]|\$)\";\"i\"))]|length") ))
  done
  [ "$n" = 0 ] || { echo "$2 still has $n open PRs, keeping $1"; return 0; }
  down "$1"
}

case "${1:-}" in
  up)           shift; up "$1" "$2" ;;
  down)         shift; down "$1" ;;
  down-if-last) shift; down_if_last "$1" "$2" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
