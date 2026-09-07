#!/usr/bin/env bash
# The promotion gate. Runs once per queue batch against one environment.
#
#   suite.sh run <frontend_url> [api_url]   everything the batch earns
#   suite.sh <part> [args]                  one part, for debugging
#   parts: preflight sha creds signup text sms traces browser bluejayai outbound inbound redteam uptime
#
# Exit: 0 pass | 1 regression | 2 usage | 3 fixtures or prereqs missing | 4 provider config red
#
# It asserts status class, never agent behaviour. Four turns of nonsense passes on purpose:
# this gates infrastructure, and evals_tests.yml owns whether the answers were any good.
set -uo pipefail

FE=${SUITE_FRONTEND_URL:-}
API=${SUITE_API_URL:-}
OTLP=${SUITE_OTLP_URL:-https://otlp.getbluejay.ai/v1/traces}
KEY=${TEST_SUITE_BLUEJAY_API_KEY:-}
KEY_B=${TEST_SUITE_BLUEJAY_API_KEY_B:-}
HERE=$(cd "$(dirname "$0")" && pwd)

E_FAIL=1; E_USAGE=2; E_FIXTURE=3; E_CONFIG=4; E_AMBER=5

note() { printf '  %s\n' "$*" >&2; }
ok()   { printf 'ok   %-9s %s\n' "$1" "${2:-}"; }
bad()  { printf 'FAIL %-9s %s\n' "$1" "${2:-}" >&2; }
miss() { printf 'MISS %-9s %s\n' "$1" "${2:-}" >&2; exit $E_FIXTURE; }

# Inside $( ) the miss below exits the SUBSHELL, so a caller that writes
#   x=$(need FOO)
# keeps going with x empty unless it also checks the status. Always write
#   x=$(need FOO) || return $E_FIXTURE
# or call it bare, as preflight does.
need() {
  local v=${!1:-}
  [ -n "$v" ] || miss fixture "$1 is unset"
  printf '%s' "$v"
}

# curl that keeps the status code. Prints "<code>\n<body>".
call() {
  local method=$1 path=$2 key=${4:-$KEY} body=${3:-}
  local args=(-s -o /tmp/suite.body -w '%{http_code}' --max-time 45 -X "$method"
              -H "X-API-Key: $key" -H 'Content-Type: application/json' "$API$path")
  [ -n "$body" ] && args+=(-d "$body")
  local code; code=$(curl "${args[@]}") || code=000
  printf '%s\n' "$code"
}
body() { cat /tmp/suite.body; }

touched() { [ -z "${SUITE_CHANGED:-}" ] && return 1; grep -qEi "$1" <<<"$SUITE_CHANGED"; }

# ---------------------------------------------------------------- status class

# Red is the regression being gated. Amber is the carrier having a bad day.
verdict() {
  case "$1" in
    COMPLETED|CONVERSATION_ENDED|RUNNING|EVALUATING) echo green ;;
    NO_ANSWER|CALL_DROPPED)                         echo amber ;;
    *)                                              echo red ;;
  esac
}

# error_code lives on test_results but is not on the REST response yet, so classify on
# status. Every AUTH/MISSING/DECRYPT/BRIDGE code lands on NO_CONNECTION anyway; the code
# is only ever extra detail in the failure line.
result_of() {
  local code; code=$(call GET "/v1/retrieve-simulation-result/$1")
  [ "$code" = 200 ] || { echo "HTTP_$code"; return; }
  body | jq -r '.simulation_result.status // "UNKNOWN"'
}

# Deadline per state transition, not one for the whole test. Queueing returns before
# dispatch, so a 200 from the queue endpoint means nothing and a stuck dispatch has to
# fail in 45s rather than burn the whole 300.
await() {  # await <result_id> <wanted...|deadline> ; echoes the status it settled on
  local id=$1 want=$2 deadline=$3 end=$((SECONDS + deadline)) s
  while [ $SECONDS -lt "$end" ]; do
    s=$(result_of "$id")
    grep -qw -- "$s" <<<"$want" && { echo "$s"; return; }
    [ "$(verdict "$s")" = green ] || { echo "$s"; return; }
    sleep 5
  done
  echo "STUCK_IN_${s:-UNKNOWN}"
}

# livekit_agent_name comes off the fixture agent row, never the call site. Mandatory for
# LIVEKIT agents, must stay unset for the bridge providers: backwards one way is
# NO_CONNECTION, backwards the other is NO_ANSWER.
agent_run_extra() {
  local code; code=$(call GET "/v1/agents/$1")
  [ "$code" = 200 ] || miss fixture "agent $1 unreadable (HTTP $code)"
  body | jq -c 'if .connection_type == "LIVEKIT"
                then {livekit_agent_name: (.livekit_agent_name // "")}
                else {} end'
}

# ---------------------------------------------------------------- parts

# The fixture manifest, and the only place it lives. A dev DB rebuild has broken the
# existing suite once already: if a rebuild turns the gate red people learn to override it,
# and then it is worse than no gate. Hence the separate exit code.
cmd_preflight() {
  command -v jq >/dev/null || miss preflight "jq not installed"
  command -v node >/dev/null || miss preflight "node not installed"

  for v in SUITE_API_URL SUITE_FRONTEND_URL \
           TEST_SUITE_BLUEJAY_API_KEY TEST_SUITE_BLUEJAY_API_KEY_B \
           SUITE_SUPABASE_URL SUITE_SUPABASE_ANON_KEY SUITE_SUPABASE_SERVICE_KEY SUITE_USER_EMAIL \
           TEST_SUITE_SIM_TEXT TEST_SUITE_SIM_SMS \
           TEST_SUITE_SIM_OUTBOUND TEST_SUITE_AGENT_OUTBOUND \
           TEST_SUITE_SIM_INBOUND TEST_SUITE_AGENT_INBOUND \
           TEST_SUITE_AGENT_ID; do
    need "$v" >/dev/null
  done
  touched 'red.?team' && need TEST_SUITE_AGENT_REDTEAM >/dev/null
  touched 'uptime'    && need TEST_SUITE_MONITOR_ID >/dev/null

  local code
  for a in "$TEST_SUITE_AGENT_ID" "$TEST_SUITE_AGENT_OUTBOUND" "$TEST_SUITE_AGENT_INBOUND"; do
    code=$(call GET "/v1/agents/$a")
    [ "$code" = 200 ] || miss preflight "agent $a -> $code (revoked key, or a dev DB rebuild took the fixture)"
  done
  for x in "$TEST_SUITE_SIM_TEXT" "$TEST_SUITE_SIM_SMS" "$TEST_SUITE_SIM_OUTBOUND" "$TEST_SUITE_SIM_INBOUND"; do
    code=$(call GET "/v1/simulation/$x")
    [ "$code" = 200 ] || miss preflight "simulation $x -> $code (fixture gone)"
  done
  # Second org has to be a different org or the tenancy assertion proves nothing.
  code=$(call GET /v1/integrations "" "$KEY_B")
  [ "$code" = 200 ] || miss preflight "second-org key -> $code"
  local a b
  a=$(call GET /v1/integrations >/dev/null; body | jq -r '.organization_id')
  b=$(call GET /v1/integrations "" "$KEY_B" >/dev/null; body | jq -r '.organization_id')
  [ "$a" != "$b" ] || miss preflight "both API keys belong to org $a"

  # bluejayai creates its own digital humans, which the API refuses without a caller id.
  code=$(call GET /v1/phone-numbers)
  [ "$code" = 200 ] || miss preflight "phone numbers -> $code"
  body | jq -e 'if type=="array" then length else (.phone_numbers|length) end > 0' >/dev/null \
    || miss preflight "org has no phone number, bluejayai cannot create a digital human"

  # A3's fixture agent posts at a hosted echo; a runner is not publicly reachable, so the
  # echo going down looks exactly like a product failure unless it is checked here first.
  if [ -n "${TEST_SUITE_ECHO_URL:-}" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$TEST_SUITE_ECHO_URL") || code=000
    [ "$code" = 200 ] || miss preflight "echo webhook $TEST_SUITE_ECHO_URL -> $code"
  fi
  ok preflight "fixtures present, two distinct orgs"
}

cmd_sha() {
  local code
  code=$(curl -s -o /tmp/suite.body -w '%{http_code}' --max-time 20 "$API/v1/ping") || code=000
  [ "$code" = 200 ] || { bad sha "middleware /v1/ping returned $code"; return $E_FAIL; }
  local mw; mw=$(body | jq -r '.sha // .commit // empty')
  # /health is a static ok and useless as a signal; /health/deps actually probes redis and
  # postgres and 503s when one is unreachable.
  code=$(curl -s -o /tmp/suite.body -w '%{http_code}' --max-time 20 "$API/health/deps") || code=000
  [ "$code" = 200 ] || { bad sha "middleware /health/deps -> $code $(body | head -c 160)"; return $E_FAIL; }

  code=$(curl -s -o /tmp/suite.body -w '%{http_code}' --max-time 20 "$FE/api/health") || code=000
  local fe=""
  if [ "$code" = 200 ]; then fe=$(body | jq -r '.sha // .commit // empty'); else
    # An unauthenticated root is a 307 to the login page, which is a live frontend.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$FE/") || code=000
    [[ $code =~ ^(200|30[0-9])$ ]] || { bad sha "frontend / returned $code"; return $E_FAIL; }
  fi

  local want=${SUITE_EXPECT_SHA:-}
  [ -z "$want" ] && { ok sha "both live (no expected SHA pinned)"; return 0; }
  # Not having a SHA to compare is a missing prerequisite, not a product regression.
  # Without it the gate can green-light code that was never deployed.
  [ -n "$mw" ] || miss sha "middleware /v1/ping exposes no SHA yet"
  [ -n "$fe" ] || miss sha "frontend exposes no SHA endpoint yet"
  [ "${mw:0:7}" = "${want:0:7}" ] || { bad sha "middleware on $mw, promoting $want"; return $E_FAIL; }
  [ "${fe:0:7}" = "${want:0:7}" ] || { bad sha "frontend on $fe, promoting $want"; return $E_FAIL; }
  ok sha "both on ${want:0:7}"
}

# Real provider round trips: each decrypts the org's stored key and calls the vendor.
# Rotated keys, a failed decrypt and an integration row wiped by a migration all land here.
cmd_creds() {
  local code rc=0
  code=$(call GET /v1/integrations)
  [ "$code" = 200 ] || { bad creds "GET /v1/integrations -> $code"; return $E_FAIL; }

  code=$(call GET /v1/integrations/elevenlabs/agents)
  [ "$code" = 200 ] || { bad creds "elevenlabs agents -> $code $(body | head -c 120)"; rc=$E_CONFIG; }
  code=$(call GET /v1/integrations/vapi/tools)
  [ "$code" = 200 ] || { bad creds "vapi tools -> $code $(body | head -c 120)"; rc=$E_CONFIG; }

  [ $rc = 0 ] && ok creds "integrations, elevenlabs, vapi"
  return $rc
}

# The deepest path with no carrier in it: middleware, text_agent, redis, webhook dispatch,
# SQS, evals, ClickHouse. Highest coverage per second in the suite.
cmd_text() {
  local sim; sim=$(need TEST_SUITE_SIM_TEXT)
  local code; code=$(call POST /v1/queue-http-text-simulation-run \
    "{\"simulation_id\":\"$sim\",\"runs_per_digital_human\":1}")
  [ "$code" = 200 ] || { bad text "queue -> $code $(body | head -c 200)"; return $E_FAIL; }
  local run rid
  run=$(body | jq -r '.simulation_run_id'); rid=$(body | jq -r '.simulation_result_ids[0]')

  local s
  s=$(await "$rid" "RUNNING CONVERSATION_ENDED EVALUATING COMPLETED" 45)
  [ "$(verdict "$s")" = green ] || { bad text "never left the queue: $s"; return $E_FAIL; }
  s=$(await "$rid" "CONVERSATION_ENDED EVALUATING COMPLETED" 180)
  [ "$(verdict "$s")" = green ] || { bad text "conversation failed: $s"; return $E_FAIL; }
  s=$(await "$rid" "COMPLETED" 300)
  case "$(verdict "$s")" in
    green) ;;
    amber) bad text "amber: $s"; return $E_AMBER ;;
    *)     bad text "$s"; return $E_FAIL ;;
  esac

  call GET "/v1/retrieve-simulation-result/$rid" >/dev/null
  local evals url turns
  evals=$(body | jq '.simulation_result.metrics | length // 0')
  url=$(body | jq -r '.simulation_result.transcript_url // empty')
  [ "${evals:-0}" -gt 0 ] || { bad text "COMPLETED with no metric results: evals or the ClickHouse write is broken"; return $E_FAIL; }
  [ -n "$url" ] || { bad text "COMPLETED with no transcript_url"; return $E_FAIL; }

  curl -s --max-time 30 "$url" -o /tmp/suite.tx || { bad text "transcript_url unfetchable"; return $E_FAIL; }
  turns=$(jq '[.. | objects | select(has("speaker") or has("role"))] | length' /tmp/suite.tx 2>/dev/null)
  [ "${turns:-0}" -ge 4 ] || { bad text "only $turns turns, expected >= 4"; return $E_FAIL; }

  # Hand the browser part something concrete to look for.
  {
    echo "SUITE_SIM_ID=$sim"; echo "SUITE_RUN_ID=$run"; echo "SUITE_RESULT_ID=$rid"
    jq -r '[.. | objects | select(has("speaker") or has("role"))][0]
           | (.utterance // .text // .content // "") | .[0:40]
           | "SUITE_EXPECT_TEXT=" + .' /tmp/suite.tx 2>/dev/null
  } > /tmp/suite.text.env
  ok text "run $run, $turns turns, $evals metric results"
}

cmd_sms() {
  local sim; sim=$(need TEST_SUITE_SIM_SMS)
  local code; code=$(call POST /v1/queue-sms-simulation-run \
    "{\"simulation_id\":\"$sim\",\"runs_per_digital_human\":1}")
  [ "$code" = 200 ] || { bad sms "queue -> $code $(body | head -c 200)"; return $E_FAIL; }
  local rid; rid=$(body | jq -r '.simulation_result_ids[0]')

  local s
  s=$(await "$rid" "RUNNING CONVERSATION_ENDED EVALUATING COMPLETED" 45)
  [ "$(verdict "$s")" = green ] || { bad sms "never left the queue: $s"; return $E_FAIL; }
  # CONVERSATION_ENDED is the checkpoint that skips the evals tail. A4 does not wait for it.
  s=$(await "$rid" "CONVERSATION_ENDED EVALUATING COMPLETED" 180)
  case "$(verdict "$s")" in
    green) ;;
    amber) bad sms "amber: $s"; return $E_AMBER ;;
    *)     bad sms "$s"; return $E_FAIL ;;
  esac

  call GET "/v1/retrieve-simulation-result/$rid" >/dev/null
  local url; url=$(body | jq -r '.simulation_result.transcript_url // empty')
  [ -n "$url" ] || { bad sms "$s with no transcript_url"; return $E_FAIL; }
  curl -s --max-time 30 "$url" -o /tmp/suite.sms || { bad sms "transcript_url unfetchable"; return $E_FAIL; }
  local inb outb
  inb=$(jq '[.. | objects | select((.speaker // .role // "") | test("agent|assistant";"i"))] | length' /tmp/suite.sms 2>/dev/null)
  outb=$(jq '[.. | objects | select((.speaker // .role // "") | test("human|user|digital";"i"))] | length' /tmp/suite.sms 2>/dev/null)
  [ "${inb:-0}" -ge 2 ] && [ "${outb:-0}" -ge 2 ] || { bad sms "$inb in / $outb out, expected >= 2 each"; return $E_FAIL; }
  ok sms "$s, $inb in / $outb out"
}

# Assert the ingest pipeline directly rather than as a side effect of a sim: livekit_agent
# emits no spans of its own and test_results.trace_ids is customer supplied, so a sim proves
# nothing about traces. This is faster, deterministic, and tests the thing that breaks.
cmd_traces() {
  local seed=${SUITE_EXPECT_SHA:-$(date +%s)}${SUITE_ATTEMPT:-1}
  local tid; tid=$(printf '%s' "$seed" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32)
  local root=${tid:0:16} kid1=${tid:8:16} kid2=${tid:16:16}

  python3 - "$tid" "$root" "$kid1" "$kid2" > /tmp/suite.otlp.json <<'PY'
import json, sys, time
tid, root, k1, k2 = sys.argv[1:5]
now = time.time_ns()
def span(sid, parent, name, off):
    return {"traceId": tid, "spanId": sid, "parentSpanId": parent, "name": name, "kind": 2,
            "startTimeUnixNano": str(now + off), "endTimeUnixNano": str(now + off + 500_000_000),
            "attributes": [{"key": "bluejay.gate", "value": {"stringValue": "promotion-suite"}}],
            "status": {"code": 1}}
print(json.dumps({"resourceSpans": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "promotion-gate"}}]},
    "scopeSpans": [{"scope": {"name": "suite.sh"}, "spans": [
        span(root, "", "gate.root", 0),
        span(k1, root, "gate.child.a", 100_000_000),
        span(k2, root, "gate.child.b", 200_000_000),
    ]}]}]}))
PY

  local code
  code=$(curl -s -o /tmp/suite.body -w '%{http_code}' --max-time 30 -X POST "$OTLP" \
    -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
    --data-binary @/tmp/suite.otlp.json) || code=000
  # A 401 here is the single most common real trace outage.
  [ "$code" = 200 ] || { bad traces "collector ingest -> $code $(body | head -c 160)"; return $E_FAIL; }

  # Batch processor holds 10s and the exporter retries 5s to 30s, so poll, do not sleep.
  local end=$((SECONDS + 60)) n=0
  while [ $SECONDS -lt $end ]; do
    code=$(call POST "/v1/traces/$tid" "{}")
    [ "$code" = 200 ] && { n=$(body | jq '[.data.data.results[0].rows[]] | length'); [ "$n" -ge 3 ] && break; }
    sleep 3
  done
  [ "${n:-0}" -ge 3 ] || { bad traces "read back $n/3 spans after 60s (trace $tid)"; return $E_FAIL; }

  local links stripped
  links=$(body | jq --arg r "$root" '[.data.data.results[0].rows[].data | select(.parent_span_id == $r)] | length')
  [ "$links" = 2 ] || { bad traces "parent links broken: $links children point at the root, expected 2"; return $E_FAIL; }
  stripped=$(body | jq '[.data.data.results[0].rows[].data
                         | (.attributes, .resource) | keys[]
                         | select(. == "organization.id" or . == "collector.environment")] | length')
  [ "$stripped" = 0 ] || { bad traces "$stripped internal tags leaked to the client"; return $E_FAIL; }

  # The case that matters. The historical failure was spans landing with an empty
  # organization.id, which the org filter then silently drops - and without this you
  # cannot tell "ingest is broken" from "ingest works but tenancy is wrong".
  code=$(call POST "/v1/traces/$tid" "{}" "$KEY_B")
  [ "$code" = 404 ] || { bad traces "second org got HTTP $code on the same trace, expected 404"; return $E_FAIL; }

  # Read-path smoke only: the list narrows to trace ids reachable from obs_conversations
  # and test_results, so a synthetic trace never appears in it.
  code=$(call GET "/v1/traces?limit=5")
  [ "$code" = 200 ] || { bad traces "list endpoint -> $code"; return $E_FAIL; }
  ok traces "3 spans, links intact, tags stripped, cross-org 404"
}

cmd_browser() {
  [ -f /tmp/suite.text.env ] && set -a && . /tmp/suite.text.env && set +a
  [ -n "${SUITE_RUN_ID:-}" ] || miss browser "no run to look at, text has to pass first"
  # Warm in CI via actions/cache; this only pays on a cold runner.
  [ -d "$HERE/node_modules" ] || (cd "$HERE" && npm ci --silent && npx playwright install --with-deps chromium)
  node "$HERE/core-path.mjs" "$FE"
}

cmd_signup() {
  [ -n "$FE" ] || miss signup "SUITE_FRONTEND_URL is unset"
  need SUITE_SUPABASE_SERVICE_KEY >/dev/null || return $E_FIXTURE
  [ -d "$HERE/node_modules" ] || (cd "$HERE" && npm ci --silent && npx playwright install --with-deps chromium)
  node "$HERE/signup.mjs" "$FE"
}

# ------------------------------------------------------------------ bluejay ai

# The one surface where a customer's words become writes on their own data, over MCP with
# their access token. Asks it to build an agent and two simulations through the UI, then
# checks the rows exist and removes them. It creates and deletes its own records, so no
# fixture another part depends on is ever touched.
cmd_bluejayai() {
  [ -n "$FE" ] || miss bluejayai "SUITE_FRONTEND_URL is unset"
  need TEST_SUITE_BLUEJAY_API_KEY >/dev/null || return $E_FIXTURE
  need SUITE_SUPABASE_SERVICE_KEY >/dev/null || return $E_FIXTURE
  need SUITE_USER_EMAIL >/dev/null           || return $E_FIXTURE
  [ -d "$HERE/node_modules" ] || (cd "$HERE" && npm ci --silent && npx playwright install --with-deps chromium)
  local rc
  BJAI_TOKEN="bjai-$(date +%s)-$RANDOM" node "$HERE/bluejay-ai.mjs" "$FE"
  rc=$?
  case $rc in
    0) ok bluejayai "built through the UI and cleaned up" ;;
    "$E_AMBER") : ;;
    *) bad bluejayai "see above" ;;
  esac
  return $rc
}

# One real conversation buys Retell plus Twilio plus SIP trunking plus the LiveKit receiver.
# Highest coverage per second in the system, which is why it survives the cut.
voice() {
  local part=$1 sim=$2 agent=$3 deadline=$4
  local extra; extra=$(agent_run_extra "$agent")
  local payload; payload=$(jq -cn --arg s "$sim" --argjson e "$extra" \
    '{simulation_id:$s, runs_per_digital_human:1} + $e')
  local code; code=$(call POST /v1/queue-simulation-run "$payload")
  [ "$code" = 200 ] || { bad "$part" "queue -> $code $(body | head -c 200)"; return $E_FAIL; }
  local rid; rid=$(body | jq -r '.simulation_result_ids[0]')

  local s
  s=$(await "$rid" "RUNNING CONVERSATION_ENDED EVALUATING COMPLETED" 45)
  [ "$(verdict "$s")" = green ] || { bad "$part" "never dispatched: $s"; return $E_FAIL; }
  s=$(await "$rid" "CONVERSATION_ENDED EVALUATING COMPLETED" "$deadline")
  case "$(verdict "$s")" in
    green) ok "$part" "$s"; return 0 ;;
    amber) bad "$part" "amber: $s"; return $E_AMBER ;;
    *)     bad "$part" "$s"; return $E_FAIL ;;
  esac
}

cmd_outbound() {
  local s a
  s=$(need TEST_SUITE_SIM_OUTBOUND)   || return $E_FIXTURE
  a=$(need TEST_SUITE_AGENT_OUTBOUND) || return $E_FIXTURE
  voice outbound "$s" "$a" 240
}
cmd_inbound() {
  local s a
  s=$(need TEST_SUITE_SIM_INBOUND)   || return $E_FIXTURE
  a=$(need TEST_SUITE_AGENT_INBOUND) || return $E_FIXTURE
  voice inbound "$s" "$a" 240
}

# Proves the red-team pipeline dispatches, which is all a merge gate should claim. A run
# that actually red teams is a nightly job: every probe here is a real billed voice call,
# so it is capped at one and stopped as soon as it is moving.
cmd_redteam() {
  local agent; agent=$(need TEST_SUITE_AGENT_REDTEAM)
  local cfg='{"recon_count":1,"max_levels":1,"max_branches_per_node":1,"max_total_dhs":1,"max_call_duration_minutes":1}'
  # agent_id is an int here, and the endpoint is confirm-gated: without confirmed it only previews.
  local code; code=$(call POST /v1/red-team-simulations \
    "{\"agent_id\":$agent,\"confirmed\":true,\"config\":$cfg}")
  [ "$code" = 200 ] || { bad redteam "start -> $code $(body | head -c 200)"; return $E_FAIL; }
  local tid rid
  tid=$(body | jq -r '.test_id'); rid=$(body | jq -r '.simulation_run_id // empty')
  [ -n "$tid" ] && [ "$tid" != null ] || { bad redteam "no test_id in the response"; return $E_FAIL; }

  local code2; code2=$(call GET "/v1/red-team-simulations/$tid")
  call POST "/v1/red-team-simulations/$tid/stop" >/dev/null
  [ "$code2" = 200 ] || { bad redteam "test $tid unreadable right after start -> $code2"; return $E_FAIL; }
  ok redteam "test $tid dispatched (run ${rid:-none}) and stopped"
}

cmd_uptime() {
  local id; id=$(need TEST_SUITE_MONITOR_ID)
  local code; code=$(call GET "/v1/uptime/monitors/$id")
  [ "$code" = 200 ] || { bad uptime "monitor -> $code"; return $E_FAIL; }
  local st when age
  st=$(body | jq -r '.last_status // "NONE"')
  when=$(body | jq -r '.last_checked_at // empty')
  [ "$(body | jq -r '.enabled')" = true ] || { bad uptime "monitor $id is disabled"; return $E_FAIL; }
  # UNKNOWN means we could not measure, not an agent-down verdict, so it never blocks.
  [ "$st" != DOWN ] || { bad uptime "last check is DOWN"; return $E_FAIL; }
  [ -n "$when" ] || { bad uptime "monitor has never checked"; return $E_FAIL; }
  age=$(python3 -c 'import datetime,sys;print(int((datetime.datetime.now(datetime.timezone.utc)-datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00"))).total_seconds()))' "$when")
  [ "$age" -lt 1800 ] || { bad uptime "last check was ${age}s ago, the loop is not running"; return $E_FAIL; }
  ok uptime "$st, ${age}s ago"
}

# ---------------------------------------------------------------- driver

# Exactly one retry, amber only. NO_CONNECTION and SYSTEM_ERROR are precisely the
# regression being gated, and retrying them hides it.
attempt() {
  local rc
  "$@"; rc=$?
  [ $rc = 0 ] && return 0
  [ $rc = $E_AMBER ] || return $rc
  note "amber, one retry"
  SUITE_ATTEMPT=2 "$@"; rc=$?
  [ $rc = $E_AMBER ] && rc=$E_FAIL
  return $rc
}

cmd_run() {
  FE=${1:-$FE}; API=${2:-$API}
  [ -n "$FE" ] || { echo "usage: suite.sh run <frontend_url> [api_url]" >&2; exit $E_USAGE; }
  FE=${FE%/}; API=${API%/}
  export SUITE_FRONTEND_URL=$FE SUITE_API_URL=$API
  local t0=$SECONDS rc=0 failed=()

  cmd_preflight || exit $?
  local skip=" " prc
  for part in sha creds signup text sms traces browser bluejayai outbound inbound; do
    [[ $skip == *" $part "* ]] && { note "skipped $part"; continue; }
    attempt "cmd_$part"
    prc=$?
    case $prc in
      0) ;;
      "$E_FIXTURE") exit $E_FIXTURE ;;
      # A provider whose credentials are red is a config problem, not a regression, and the
      # call tests would only fail for the same reason. Report config, do not report a
      # regression that is not there.
      "$E_CONFIG") rc=$E_CONFIG
                   # Only the credential check implies the call tests would fail too.
                   # A chat route with no MCP URLs says nothing about telephony.
                   [ "$part" = creds ] && { note "provider config red, skipping the call tests"
                                            skip+="outbound inbound "; } ;;
      *) failed+=("$part"); rc=$E_FAIL
         # The browser walk reads the run the text part creates; without one it has nothing
         # to assert and would only re-report the same failure.
         [ "$part" = text ] && skip+="browser " ;;
    esac
  done

  touched 'red.?team' && { attempt cmd_redteam || { failed+=(redteam); rc=$E_FAIL; }; }
  touched 'uptime'    && { attempt cmd_uptime  || { failed+=(uptime);  rc=$E_FAIL; }; }

  printf '\n%s in %ss\n' "$([ $rc = 0 ] && echo PASS || echo "FAIL: ${failed[*]:-config}")" $((SECONDS - t0))
  exit $rc
}

# The logic worth checking, as opposed to the curls: the status classifier and the retry
# rule. Offline, no fixtures, no credentials, instant.
cmd_selftest() {
  local f=0
  chk() { [ "$2" = "$3" ] || { echo "selftest: $1 -> $2, want $3" >&2; f=1; }; }
  chk COMPLETED          "$(verdict COMPLETED)"          green
  chk CONVERSATION_ENDED "$(verdict CONVERSATION_ENDED)" green
  chk NO_ANSWER          "$(verdict NO_ANSWER)"          amber
  chk CALL_DROPPED       "$(verdict CALL_DROPPED)"       amber
  chk NO_CONNECTION      "$(verdict NO_CONNECTION)"      red
  chk SYSTEM_ERROR       "$(verdict SYSTEM_ERROR)"       red
  chk OUT_OF_FUNDS       "$(verdict OUT_OF_FUNDS)"       red
  chk STUCK              "$(verdict STUCK_IN_QUEUED)"    red

  # amber retries exactly once, then hardens to a failure
  local n=0
  amber() { n=$((n + 1)); return $E_AMBER; }
  red()   { n=$((n + 1)); return $E_FAIL; }
  attempt amber; chk "amber rc" "$?" "$E_FAIL"; chk "amber tries" "$n" 2
  n=0; attempt red; chk "red rc" "$?" "$E_FAIL"; chk "red tries" "$n" 1

  [ $f = 0 ] && ok selftest "classifier and retry rule" || return $E_FAIL
}

case "${1:-}" in
  run)       shift; cmd_run "$@" ;;
  selftest)  cmd_selftest ;;
  preflight|sha|creds|signup|text|sms|traces|browser|bluejayai|outbound|inbound|redteam|uptime)
             p=$1; shift; FE=${FE%/}; API=${API%/}; "cmd_$p" "$@" ;;
  *)         sed -n '2,8p' "$0"; exit $E_USAGE ;;
esac
