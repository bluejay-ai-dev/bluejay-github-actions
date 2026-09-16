#!/usr/bin/env bash
# Runs ON a preview box. Builds the same artifacts prod builds and points them at the
# sandbox cloud services, so the box is a mirror of prod rather than a dev stack.
#
# Deliberately NOT `just start`. That boots local Supabase, localstack and a ministack,
# which tells you the code compiles and nothing about whether it works in production.
#
# From user-data: TICKET, OVERRIDES ("repo branch" per line), PRS ("repo num" per line),
# GH_TOKEN (installation token), RAILWAY_TOKEN (reads the sandbox variable set).
set -uo pipefail

TICKET="${TICKET:?}"; ORG="${ORG:-bluejay-ai-dev}"
WS="$HOME/preview"
LOG="$HOME/preview-boot.log"
exec > >(tee -a "$LOG") 2>&1
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

RAILWAY_API=https://backboard.railway.com/graphql/v2
PROJECT=7047af18-477f-42e0-a905-f2e8f7ccac0f
ENVIRONMENT=295835e8-7292-4682-a629-b515e7cebe74
MW_SANDBOX=3dfb8899-e5f3-4b57-a551-a805d6e1ef1a
FE_SANDBOX=7f2975a2-7f14-4a6f-af79-93a0e60b0b3e

comment() {
  local r n
  while read -r r n; do
    [ -n "${r:-}" ] || continue
    gh pr comment "$n" -R "$ORG/$r" --body "$1" >/dev/null 2>&1 || true
  done <<<"$PRS"
}

fail() {
  say "FAILED: $*"
  comment ":x: preview for **$TICKET** failed to build.

\`\`\`
$*
\`\`\`
\`\`\`
$(tail -30 "$LOG" 2>/dev/null)
\`\`\`"
  exit 1
}

command -v gh >/dev/null || fail "gh is not on this AMI"
gh auth setup-git >/dev/null 2>&1 || fail "gh auth setup-git failed, the token is probably expired"

# ---------------------------------------------------------------- code
mkdir -p "$WS"
checkout() { # repo branch
  local repo=$1 branch=$2 d="$WS/$1"
  [ -d "$d" ] && return 0
  say "cloning $repo @ $branch"
  gh repo clone "$ORG/$repo" "$d" -- --depth=1 --branch "$branch" -q \
    || fail "could not clone $repo at $branch"
}

mw_branch=main; fe_branch=main
while read -r repo branch; do
  [ -n "${repo:-}" ] || continue
  case "$repo" in
    bluejay_middleware)  mw_branch=$branch ;;
    bluejay_frontend_v2) fe_branch=$branch ;;
  esac
done <<<"$OVERRIDES"

checkout bluejay_middleware "$mw_branch"
checkout bluejay_frontend_v2 "$fe_branch"

# ---------------------------------------------------------------- secrets
# One token in user-data instead of ninety. The variable set never leaves this box, and it
# is the sandbox set, never prod: a box reviewers can open must not hold production keys.
vars_for() { # serviceId -> KEY=VALUE lines
  local svc=$1
  curl -fsS --max-time 30 "$RAILWAY_API" \
    -H "Authorization: Bearer $RAILWAY_TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$PROJECT" --arg e "$ENVIRONMENT" --arg s "$svc" \
      '{query:"query($p:String!,$e:String!,$s:String!){variables(projectId:$p,environmentId:$e,serviceId:$s)}",variables:{p:$p,e:$e,s:$s}}')" \
    | jq -r '.data.variables | to_entries[] | "\(.key)=\(.value)"'
}

say "reading the sandbox variable set"
vars_for "$MW_SANDBOX" > "$WS/mw.env" || fail "could not read middleware sandbox variables"
[ -s "$WS/mw.env" ] || fail "middleware sandbox variables came back empty; is RAILWAY_TOKEN valid?"
vars_for "$FE_SANDBOX" > "$WS/fe.env" || true
chmod 600 "$WS"/*.env
say "  middleware: $(wc -l < "$WS/mw.env") variables"

# ---------------------------------------------------------------- middleware
# The same Dockerfile Railway builds, so this is the artifact prod runs.
say "building middleware"
docker build -q -t preview-mw "$WS/bluejay_middleware" >/dev/null || fail "middleware image failed to build"
docker rm -f preview-mw >/dev/null 2>&1 || true
docker run -d --name preview-mw --restart unless-stopped \
  --env-file "$WS/mw.env" -e PORT=8080 -p 8080:8080 preview-mw >/dev/null \
  || fail "middleware container failed to start"

up=0
for _ in $(seq 1 60); do
  c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost:8080/health 2>/dev/null)
  case "$c" in 200) up=1; break ;; esac
  sleep 5
done
[ "$up" = 1 ] || fail "middleware never answered /health: $(docker logs --tail 25 preview-mw 2>&1)"
say "middleware healthy"

# ---------------------------------------------------------------- tunnels
# The app sends upgrade-insecure-requests for every non-localhost host, so a plain http
# address renders unstyled. A quick tunnel is real https and needs no DNS or certificate,
# which is what made the Route53 design unnecessary.
command -v cloudflared >/dev/null || fail "cloudflared is not on this AMI"
tunnel() { # port logfile -> url
  local port=$1 log=$2 u=""
  pgrep -f "cloudflared tunnel --url http://localhost:$port\$" >/dev/null 2>&1 \
    || nohup cloudflared tunnel --url "http://localhost:$port" >"$log" 2>&1 &
  for _ in $(seq 1 60); do
    u=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" 2>/dev/null | tail -1)
    [ -n "$u" ] && break
    sleep 2
  done
  printf '%s' "$u"
}

API_URL=$(tunnel 8080 "$HOME/.tunnel-mw.log")
[ -n "$API_URL" ] || fail "no public url for middleware"
say "middleware at $API_URL"

# ---------------------------------------------------------------- frontend
# Railway builds this with RAILPACK, which is install + build + start. The browser calls
# middleware directly, so the frontend has to be built against this box's API url.
say "building frontend"
cd "$WS/bluejay_frontend_v2" || fail "no frontend checkout"
set -a; . "$WS/fe.env" 2>/dev/null || true; set +a
export NEXT_PUBLIC_API_URL="$API_URL" PORT=3000
npm ci --no-audit --no-fund >/dev/null 2>&1 || fail "npm ci failed"
npm run build >/dev/null 2>&1 || fail "frontend build failed: $(npm run build 2>&1 | tail -20)"
nohup npm run start >"$HOME/fe.log" 2>&1 &

up=0
for _ in $(seq 1 60); do
  c=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://localhost:3000/ 2>/dev/null)
  case "$c" in ''|000) ;; *) up=1; break ;; esac
  sleep 5
done
[ "$up" = 1 ] || fail "frontend never answered: $(tail -20 "$HOME/fe.log")"

APP_URL=$(tunnel 3000 "$HOME/.tunnel-fe.log")
[ -n "$APP_URL" ] || fail "no public url for the frontend"

# Prove it renders. A 200 on the page is not enough: the failure this url exists to avoid
# is the page loading while every stylesheet 404s.
code=$(curl -sL -o /dev/null -m 45 -w '%{http_code}' "$APP_URL/" 2>/dev/null)
css=$(curl -sL -m 45 "$APP_URL/" 2>/dev/null | grep -oE '/_next/static/[^"]*\.css' | head -1)
csscode=000
[ -n "$css" ] && csscode=$(curl -s -o /dev/null -m 45 -w '%{http_code}' "$APP_URL$css" 2>/dev/null)
say "page=$code css=$csscode"

changed=$(awk '$2!="main" {printf "- `%s` on `%s`\n", $1, $2}' <<<"$OVERRIDES")
[ -n "$changed" ] || changed="- _nothing, this is the baseline_"

comment ":rocket: **Preview for $TICKET**

$APP_URL

| | |
|---|---|
| API | $API_URL |
| Data | shared sandbox, not production |
| Built from | $changed |

Middleware runs the same Dockerfile prod builds, against the sandbox services. Not a local
dev stack. The box stops itself after 15 minutes idle and is deleted when this PR closes."

say "done: $APP_URL"
