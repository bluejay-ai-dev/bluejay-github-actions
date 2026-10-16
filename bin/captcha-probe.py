#!/usr/bin/env python3
"""Page when prod Supabase can no longer verify sign up and sign in captchas.

A browser cannot solve Turnstile, so this asks auth to sign up with a token we know is bad.
A healthy project rejects the token (invalid-input-response). A broken one rejects its own
secret (invalid-input-secret, missing-input-secret), and then every email sign up and sign in
fails too. The bad token stops the request before an account is made. It cannot see a valid
secret that belongs to the wrong Turnstile widget.

  ROUTING_KEY=... RUN_URL=... captcha-probe.py
"""
import json, os, sys, time, urllib.error, urllib.request

SUPABASE_URL = "https://okihfrlvyycxyylukqey.supabase.co"
# Public: the frontend ships this to every browser as NEXT_PUBLIC_SUPABASE_ANON_KEY. The probe
# must call auth as a logged out visitor would, or the captcha check may be skipped.
ANON_KEY = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9raWhmcmx2eXljeHl5bHVrcWV5"
            "Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDE1ODY2OTAsImV4cCI6MjA1NzE2MjY5MH0."
            "S-q2a4_ssOSkHgt9cuyIEOX9qIXDDT6J2Ih0G2h0Tqk")


def verdict(body):
    """None when healthy, 'broken' when the secret is definitely wrong, 'unclear' otherwise."""
    text = body.lower()
    if "invalid-input-response" in text:
        return None
    return "broken" if "input-secret" in text else "unclear"


def probe():
    req = urllib.request.Request(
        f"{SUPABASE_URL}/auth/v1/signup", method="POST",
        headers={"apikey": ANON_KEY, "Content-Type": "application/json"},
        data=json.dumps({"email": "paging-captcha-probe@bluejaysims.com", "password": "probe-never-signs-up-A1!",
                         "gotrue_meta_security": {"captcha_token": "paging-probe-invalid-token"}}).encode())
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode()
    except urllib.error.HTTPError as e:
        body = e.read().decode()  # the healthy answer is a 400
    except Exception as e:
        body = f"{type(e).__name__}: {e}"
    return verdict(body), body[:300]


def page(action, summary, details):
    key = os.environ.get("ROUTING_KEY", "")
    if not key:
        if action == "resolve":
            return  # healthy and nothing to resolve; a run that is red every 5 min gets ignored
        sys.exit(f"CAPTCHA_PAGERDUTY_ROUTING_KEY is unset, nobody was paged: {summary}")
    event = {"routing_key": key, "event_action": action, "dedup_key": "bluejay-auth-captcha",
             "payload": {"summary": summary, "source": "bluejay-github-actions captcha-probe",
                         "severity": "critical", "component": "auth", "group": "platform",
                         "class": "captcha", "custom_details": details},
             "links": [{"href": os.environ.get("RUN_URL", ""), "text": "GitHub run"}]}
    urllib.request.urlopen(urllib.request.Request(
        "https://events.pagerduty.com/v2/enqueue", json.dumps(event).encode(),
        {"Content-Type": "application/json"}), timeout=10)
    print(f"{action}: {summary}")


# a timeout or 5xx can be a blip, so only 3 unclear answers in a row page
for attempt in range(3):
    result, seen = probe()
    if result != "unclear":
        break
    time.sleep(20)
print(f"verdict={result or 'healthy'} response={seen}")

if result is None:
    page("resolve", "Sign up and sign in captchas verify again", {})
    sys.exit(0)
page("trigger",
     "Customers cannot sign up or sign in: Supabase rejects its own captcha secret" if result == "broken"
     else "Sign up check got no clear answer 3 times in a row: Supabase auth may be down",
     {"last_response": seen,
      "customer_impact": "Every email sign up and password sign in on app.getbluejay.ai fails. Google sign in still works.",
      "triage_steps": [
          "Open https://supabase.com/dashboard/project/okihfrlvyycxyylukqey/auth/protection and compare the captcha "
          "secret with the prod Turnstile secret in Infisical. Both must come from the same widget as the frontend site key.",
          "Check NEXT_PUBLIC_TURNSTILE_SITE_KEY is set on the prod frontend.",
          "Confirm the fix with a real sign up in an incognito window."],
      "resolves_when": "The next run sees Supabase reject only the bad token."})
sys.exit(1)
