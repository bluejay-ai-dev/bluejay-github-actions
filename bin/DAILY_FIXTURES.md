# Daily prod fixtures

watchdog-service runs `suite.sh` from this repo's main every morning at 8:30 AM Pacific and
pages on a real regression. Its fixtures live in the watchdog-service Infisical project (prod),
as the `DAILY_*` keys below. `suite.sh preflight` checks every item and ends the run as
`fixture` (never paged) when one is missing.

## Prod data

1. **Org A, the fixture org.** A dedicated prod org with funds (or PAYG credits) and at
   least one SMS and voice capable phone number. bluejayai refuses to run without a number.
2. **Org B.** A second, separate prod org. Only its API key is used, to prove one org cannot
   read another's traces.
3. **Fixture user.** A user that is a member of org A and no other org. A second
   membership lands sign-in on the org picker, and browser and bluejayai end as `fixture`. Sign-in goes through a service-role
   magic link, so no password is needed. signup.mjs makes, onboards and deletes its own throwaway
   account at `watchdog-signup+<ts>@example.com` each run. It needs one `allowed_signups` row,
   `watchdog-signup@example.com`, or the signup gate blocks every run after the first.
4. **Text agent and sim.** A TEXT agent with `http_webhook` set to the hosted echo, plus a
   simulation with one digital human and at least one metric.
5. **Webchat agent and sim.** A TEXT agent with connection type `OPENAI_CHAT`
   (`openai_base_url`, `openai_api_key`, `openai_model`; a cheap model on a dedicated key),
   plus a simulation with one digital human and at least one metric.
6. **SMS agent and sim.** A TEXT agent on connection type `SMS` with an org A number, plus a
   simulation with one digital human.
7. **Outbound agent and sim.** An OUTBOUND voice agent that calls our digital human, plus a
   simulation with one digital human.
8. **Inbound agent and sim.** An INBOUND voice agent our digital human calls, plus a
   simulation with one digital human.
9. **One agent and sim per voice provider.** An INBOUND voice agent and a one digital human
   simulation for each of: `vapi` (VAPI), `retell` (RETELL), `elevenlabs` (ELEVEN_LABS),
   `livekit` (LIVEKIT, with `livekit_agent_name`), `pipecat` (PIPECAT), `bland` (BLAND_VOICE
   or BLAND_PHONE), `websocket` (WEBSOCKET), `sip` (SIP) and `phone` (PHONE). Add
   `sierra`, `amelia`, `ces` and `dfcx` (the *_VOICE types) only if we hold a test tenant on
   that vendor. Keep each digital human short (max call length 1 to 2 minutes).
10. **Org A integrations.** Vapi and ElevenLabs keys stored on org A (the `creds` part reads
    both), plus a key for every other provider in the list above that needs one.
11. **PagerDuty.** An Events API v2 integration on the service that should be woken up.

## Infisical keys (watchdog-service, prod)

`DAILY_BLUEJAY_API_KEY` (org A), `DAILY_BLUEJAY_API_KEY_B` (org B), `DAILY_USER_EMAIL`,
`DAILY_SUPABASE_AUTH_URL` (https://auth.getbluejay.ai, so the session cookie gets the name the
frontend reads), `DAILY_AGENT_ID`, `DAILY_SIM_TEXT`, `DAILY_SIM_WEBCHAT`, `DAILY_SIM_SMS`,
`DAILY_SIM_INBOUND`, `DAILY_AGENT_INBOUND`, `DAILY_SIM_OUTBOUND`, `DAILY_AGENT_OUTBOUND` and
`DAILY_PROVIDERS`, a JSON list with one lowercase entry per provider:

```
[{"name":"vapi","sim_id":"...","agent_id":"..."},{"name":"phone","sim_id":"...","agent_id":"..."}]
```

Run one part by hand with the same keys: `infisical run --env=prod -- bin/suite.sh <part>`.
