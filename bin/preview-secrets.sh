#!/usr/bin/env bash
# Preview secrets live in Infisical, never on Railway. Each service's project has a `preview`
# env whose root holds the shared preview secrets; a preview's own values (its db branch, its
# Supabase keys) go in /previews/<name> there, which imports / so the service reads both.
#
#   preview-secrets.sh login                    prints an access token (GitHub OIDC, or INFISICAL_TOKEN as is)
#   preview-secrets.sh dump <project>           preview / as a JSON object
#   preview-secrets.sh put <project> <name>     recreate /previews/<name> from a JSON object on stdin
#   preview-secrets.sh rm <project> <name>
#
# Needs INFISICAL_TOKEN for everything but login. Login needs INFISICAL_CI_IDENTITY_ID and the
# job's id-token permission.
set -euo pipefail
API=${INFISICAL_API:-https://app.infisical.com/api}
ENVSLUG=preview

call() {  # call <method> <path> [json]
  curl -fsS --max-time 30 -X "$1" "$API$2" -H "Authorization: Bearer $INFISICAL_TOKEN" \
    -H 'content-type: application/json' ${3:+-d "$3"}
}
name_ok() { [[ "$1" =~ ^[a-z0-9-]+$ ]] || { echo "bad preview name: $1" >&2; exit 2; }; }

case "${1:-}" in
  login)
    [ -n "${INFISICAL_TOKEN:-}" ] && { echo "$INFISICAL_TOKEN"; exit 0; }
    jwt=$(curl -fsS "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=infisical" \
            -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" | jq -r .value)
    curl -fsS --max-time 30 -X POST "$API/v1/auth/oidc-auth/login" -H 'content-type: application/json' \
      -d "$(jq -nc --arg i "$INFISICAL_CI_IDENTITY_ID" --arg j "$jwt" '{identityId:$i, jwt:$j}')" | jq -r .accessToken ;;
  dump)
    call GET "/v3/secrets/raw?workspaceId=$2&environment=$ENVSLUG&secretPath=%2F" \
      | jq -c '[.secrets[] | {(.secretKey): .secretValue}] | add // {}' ;;
  put)
    name_ok "$3"; vals=$(cat)
    call POST /v1/folders "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" '{workspaceId:$w, environment:$e, name:"previews", path:"/"}')" >/dev/null 2>&1 || true
    # recreate rather than patch, so a refresh never keeps a key the base dropped
    call DELETE "/v1/folders/$3" "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" '{workspaceId:$w, environment:$e, path:"/previews"}')" >/dev/null 2>&1 || true
    call POST /v1/folders "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" --arg n "$3" '{workspaceId:$w, environment:$e, name:$n, path:"/previews"}')" >/dev/null
    call POST /v1/secret-imports "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" --arg p "/previews/$3" \
      '{workspaceId:$w, environment:$e, path:$p, import:{environment:$e, path:"/"}}')" >/dev/null
    [ "$(jq 'length' <<<"$vals")" = 0 ] || call POST /v3/secrets/batch/raw "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" --arg p "/previews/$3" \
      --argjson v "$vals" '{workspaceId:$w, environment:$e, secretPath:$p,
        secrets:[$v | to_entries[] | {secretKey:.key, secretValue:(.value|tostring)}]}')" >/dev/null ;;
  rm)
    name_ok "$3"
    call DELETE "/v1/folders/$3" "$(jq -nc --arg w "$2" --arg e "$ENVSLUG" '{workspaceId:$w, environment:$e, path:"/previews"}')" >/dev/null 2>&1 \
      && echo "deleted /previews/$3 in $2" >&2 || true ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
