#!/usr/bin/env python3
"""Page PagerDuty when the nightly is red, resolve it when the nightly is green again.

  VERDICT=red ROUTING_KEY=... RUN_URL=... nightly-page.py /tmp/out
"""
import json, os, re, sys, time, urllib.request

EXERCISES = {
    "preflight": "the fixture org, its agents, sims and API keys",
    "sha": "middleware /v1/ping and /health/deps (Redis, Postgres), the frontend",
    "creds": "stored integration keys decrypting, the ElevenLabs and Vapi APIs",
    "signup": "the sign-up page and Turnstile, Supabase auth, a new account reaching the app, account cleanup",
    "text": "middleware, text_agent, Redis, webhook dispatch, SQS, evals, ClickHouse",
    "webchat": "middleware chat driver (OPENAI_CHAT), text_agent, Redis, evals, ClickHouse",
    "sms": "middleware, text_agent, Twilio SMS",
    "traces": "the OTel collector, ClickHouse traces, the middleware traces API and its org filter",
    "browser": "frontend sign-in and the run page",
    "bluejayai": "frontend Bluejay AI chat, the MCP server, middleware writes",
    "outbound": "middleware dispatcher, LiveKit DH workers on EC2, Twilio SIP, the agent calling us",
    "inbound": "middleware dispatcher, LiveKit DH workers on EC2, Twilio SIP, us calling the agent",
}

out = open(sys.argv[1]).read() if len(sys.argv) > 1 and os.path.exists(sys.argv[1]) else ""
run_url, verdict = os.environ["RUN_URL"], os.environ["VERDICT"]
key = os.environ.get("ROUTING_KEY", "")
if not key:
    sys.exit("NIGHTLY_PAGERDUTY_ROUTING_KEY is unset, nobody was paged")

m = re.search(r"^FAIL: (.*) in \d+s$", out, re.M)
failed = m.group(1).split() if m else []
reasons = {}
for part, why in re.findall(r"^FAIL\s+(\S+)\s+(.*)$", out, re.M):
    reasons[part] = why  # the last line per part wins, so a retried amber shows its final state
passed = set(re.findall(r"^ok\s+([\w:-]+)", out, re.M))
nice = lambda p: f"{p[5:]} call" if p.startswith("call:") else p
exercises = lambda p: (f"middleware dispatcher, LiveKit DH workers on EC2, {p[5:]} itself"
                       if p.startswith("call:") else EXERCISES.get(p, "see the run log"))

title = (f"Nightly prod test failed {len(failed)} of {len(failed) + len(passed)} parts: "
         + ", ".join(map(nice, failed))) if failed else "Nightly prod test failed before reporting any part"
event = {
    "routing_key": key,
    "event_action": "trigger" if verdict == "red" else "resolve",
    "dedup_key": "bluejay-nightly-prod",
    "payload": {
        "summary": title[:1000],
        "source": "bluejay-github-actions nightly",
        "severity": "critical",
        "component": "prod",
        "group": "platform",
        "class": "nightly",
        "custom_details": {
            "What this means": "The nightly suite ran real sign-ups, sims and calls against prod and "
                               "these parts failed. Only a dropped or unanswered call gets a retry, so this is "
                               "very likely a real outage, not a flake.",
            "Customer impact": "Customers using the failed parts may see their simulations, calls or "
                               "sign-ins fail the same way. Each part below says what it depends on.",
            "Failed parts": {nice(p): reasons.get(p, "no reason line, see the run log") for p in failed},
            "What each failed part exercises": {nice(p): exercises(p) for p in failed},
            "Where to look": {
                "GitHub run": run_url,
                "Evidence artifact (full log, screenshots)": run_url + "#artifacts",
                "Sentry, last 24h": "https://bluejay-4k.sentry.io/issues/?statsPeriod=24h",
            },
            "First steps to triage": [
                "1. Open the GitHub run and read the FAIL lines in the summary; the artifact has the full log and screenshots.",
                "2. Re-run only the failed parts: Actions, nightly, Run workflow, parts = the names above "
                "(a provider call is call:<name>). Green on re-run means a flake; it resolves this page.",
                "3. A call that never dispatched or ended NO_CONNECTION: check the LiveKit DH workers on EC2 "
                "(us-west-1) and the middleware dispatcher logs on Railway. One provider only: check that provider's status page and its key (creds).",
                "4. text, webchat or sms stuck or COMPLETED with no metrics: check middleware and text_agent on Railway, "
                "then the evals queue and ClickHouse.",
                "5. Look for Sentry errors in the same window, and for a prod release that went out since the last green night.",
            ],
            "Resolves when": "The next nightly, or a manual re-run of the failed parts, comes back green.",
        },
    },
    "links": [{"href": run_url, "text": "GitHub run"}],
}
for attempt in range(3):
    try:
        urllib.request.urlopen(urllib.request.Request(
            "https://events.pagerduty.com/v2/enqueue", json.dumps(event).encode(),
            {"Content-Type": "application/json"}), timeout=10)
        print(f"{event['event_action']}: {title}")
        break
    except Exception as e:
        if attempt == 2:
            sys.exit(f"PagerDuty refused the page: {e}")
        time.sleep(2 * (attempt + 1))
