#!/usr/bin/env bash
# Runs as root on a preview box, after preview.sh has dropped the repo checkouts in
# /opt/preview and the plan in /tmp/preview.env. Builds and starts only what is there.
set -euo pipefail

install -m 0644 /tmp/preview.env /etc/preview.env
. /etc/preview.env

has() { case " $FRESH " in *" $1 "*) return 0 ;; esac; return 1; }
say() { echo "==> $*"; }

export DEBIAN_FRONTEND=noninteractive
# From the Ubuntu archive, so the version is pinned by the release and signed by the distro
# keyring. Caddy is here for automatic https: the preview has a real A record, so HTTP-01
# gives it a real certificate. The frontend sends upgrade-insecure-requests for every
# non-localhost host, so a plain-http preview renders completely unstyled.
apt-get update -qq
apt-get install -y -qq caddy

# Secrets reach a preview only from the Infisical preview environment. There is deliberately
# no fallback to dev or prod: a box CI created and reviewers can reach must not be able to
# read either. Without the identity the services still start and fail loudly on their first
# database call, which is a better failure than quietly running against dev.
mkdir -p /run/preview && chmod 0710 /run/preview && chown root:ubuntu /run/preview
: > /run/preview/env && chmod 0640 /run/preview/env && chown root:ubuntu /run/preview/env
if [ -n "${INFISICAL_MACHINE_IDENTITY_ID:-}" ]; then
  tok=$(infisical login --method=aws-iam \
        --machine-identity-id="$INFISICAL_MACHINE_IDENTITY_ID" --plain --silent) || tok=""
  [ -n "$tok" ] && printf 'INFISICAL_TOKEN=%s\n' "$tok" > /run/preview/env
fi
if [ -s /run/preview/env ]; then
  secrets=(infisical run --projectId "$INFISICAL_PROJECT_ID" --env=preview --)
  say "secrets: infisical preview"
else
  secrets=()
  say "secrets: NONE. Set a preview machine identity or nothing will reach a database."
fi

# The browser calls middleware directly (useLiveTranscript reads NEXT_PUBLIC_API_URL), so a
# fresh middleware needs its own https host. A ticket that does not change middleware
# borrows the shared one rather than standing up a second copy of it.
if has bluejay_middleware; then API_URL="https://$API_HOST"; else API_URL="$SHARED_API_URL"; fi

unit() { # <name> <workdir> <cmd...>
  local n=$1 wd=$2; shift 2
  systemd-run --unit="preview-$n" --collect --quiet \
    --property=WorkingDirectory="$wd" \
    --property=EnvironmentFile=-/run/preview/env \
    --property=Restart=always --property=RestartSec=5 \
    --property=User=ubuntu --property=StandardOutput=journal \
    "$@"
}

if has bluejay_middleware; then
  say "building middleware"
  d=/opt/preview/bluejay_middleware
  sudo -u ubuntu bash -lc "cd $d && uv venv -q && uv pip install -q -r requirements.txt"
  # The allowed origins in src/main.py are a fixed list, so no preview host is ever on it.
  # One exact origin, this preview's own, not a pattern: preview hostnames live under a
  # domain we control, but a pattern on a shared deployment is still a standing hole.
  unit mw "$d" --setenv=EXTRA_CORS_ORIGINS="https://$BASE_HOST" \
    "${secrets[@]}" "$d/.venv/bin/uvicorn" src.main:app --host 127.0.0.1 --port 8000
fi

if has bluejay_frontend_v2; then
  say "building frontend"
  d=/opt/preview/bluejay_frontend_v2
  sudo -u ubuntu bash -lc "cd $d && npm ci --no-audit --no-fund"
  # NEXT_PUBLIC_REDIRECT_URL must be per preview: auth.ts only falls back to the request
  # host for localhost, so without this OAuth returns reviewers to the wrong deployment.
  # Turnstile is left unset on purpose. Its site key is bound to fixed hostnames, so on a
  # preview host the widget could never solve; unset, the component renders nothing.
  unit fe "$d" --setenv=PORT=3000 \
    --setenv=NEXT_PUBLIC_API_URL="$API_URL" \
    --setenv=NEXT_PUBLIC_REDIRECT_URL="https://$BASE_HOST/auth/callback" \
    "${secrets[@]}" npm run dev
fi

if has livekit_agent; then
  say "building agent"
  d=/opt/preview/livekit_agent
  sudo -u ubuntu bash -lc "cd $d && uv venv -q && uv pip install -q -r requirements.txt"
  # A unique worker name, so a simulation reaches this build by passing livekit_agent_name
  # and every other simulation on the shared project keeps going to the shared worker.
  unit lk "$d" --setenv=OUTBOUND_AGENT_NAME="preview-$(echo "$TICKET" | tr 'A-Z' 'a-z')" \
    "${secrets[@]}" "$d/.venv/bin/python" -m src.run_agent start
fi

# Only publish a host for something that is actually listening. A vhost pointing at a dead
# port is how a preview reads as broken when the service simply is not part of the ticket.
{
  echo "{ email ops@getbluejay.ai }"
  has bluejay_frontend_v2 && printf '%s {\n  reverse_proxy 127.0.0.1:3000\n}\n' "$BASE_HOST"
  has bluejay_middleware  && printf '%s {\n  reverse_proxy 127.0.0.1:8000\n}\n' "$API_HOST"
  :
} > /etc/caddy/Caddyfile
systemctl reload caddy || systemctl restart caddy

say "units:"
systemctl --no-pager --plain list-units 'preview-*' || true
say "frontend: https://$BASE_HOST"
say "api:      $API_URL"
