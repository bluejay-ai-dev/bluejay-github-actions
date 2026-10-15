# Daily prod fixtures

What a person has to create in prod and set on this repo before `daily.yml` goes green.
`suite.sh preflight` checks every item below and ends the run as `fixture` (never paged)
when one is missing. All commands take `-R bluejay-ai-dev/bluejay-github-actions`.

## Prod data

1. **Org A, the fixture org.** A dedicated prod org with funds (or PAYG credits) and at
   least one SMS and voice capable phone number. bluejayai refuses to run without a number.
2. **Org B.** A second, separate prod org. Only its API key is used, to prove one org cannot
   read another's traces.
3. **Fixture user.** A user that is a member of org A and no other org. A second
   membership lands sign-in on the org picker, and browser and bluejayai end as `fixture`. Sign-in goes through a service-role
   magic link, so no password is needed. signup.mjs makes and deletes its own throwaway
   account at `gate+signup-*@bluejaysims.com` each run.
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

## Secrets

```
gh secret set DAILY_BLUEJAY_API_KEY          # org A API key
gh secret set DAILY_BLUEJAY_API_KEY_B        # org B API key
gh secret set DAILY_USER_EMAIL               # fixture user's email
gh secret set PROD_SUPABASE_URL
gh secret set PROD_SUPABASE_ANON_KEY
gh secret set PROD_SUPABASE_SERVICE_KEY
gh secret set DAILY_PAGERDUTY_ROUTING_KEY    # Events API v2 routing key
```

## Variables

```
gh variable set PROD_FRONTEND_URL        # https://app.getbluejay.ai
gh variable set PROD_API_URL             # prod middleware base URL
gh variable set DAILY_AGENT_ID         # any org A agent id, read only
gh variable set DAILY_SIM_TEXT         # item 4
gh variable set DAILY_ECHO_URL         # the echo the text agent posts to
gh variable set DAILY_SIM_WEBCHAT      # item 5
gh variable set DAILY_SIM_SMS          # item 6
gh variable set DAILY_SIM_OUTBOUND     # item 7
gh variable set DAILY_AGENT_OUTBOUND
gh variable set DAILY_SIM_INBOUND      # item 8
gh variable set DAILY_AGENT_INBOUND
gh variable set DAILY_PROVIDERS        # item 9, see below
```

`DAILY_PROVIDERS` is a JSON list with one entry per provider. Names are lowercase and
appear in the page title as "vapi call":

```
[{"name":"vapi","sim_id":"...","agent_id":"..."},{"name":"retell","sim_id":"...","agent_id":"..."}]
```

## Checking it

Run the workflow by hand with `parts` = `preflight`. It lists the first missing item as a
`MISS` line. Then run it with `parts` blank for a full run.
