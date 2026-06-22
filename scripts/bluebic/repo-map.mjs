// maps a judge failure_mode to the bluejay repo whose code most likely owns the fix.
// static, NOT llm-guessed: keeps the github token's repo scope minimal + auditable.
// owner is bluejay-ai-dev; the values here ARE the bluebic allowlist (the BLUEBIC_GH_TOKEN
// PAT must be scoped to exactly these three repos).
//
// this mirrors the local runner's allowlist (bluejay-ai-dashboard scripts/bluebic-runner.mjs)
// verbatim — the two backends MUST route a given failure_mode to the same repo.
export const REPO_MAP = {
  tool_error:          "bluejay-ai-dev/bluejay_middleware",   // integration / tool call sites
  handoff_failure:     "bluejay-ai-dev/bluejay_middleware",   // escalation routing
  knowledge_gap:       "bluejay-ai-dev/knowledge_base",       // kb / rag / grounding content
  // these dashboard chats are the platform / text assistant — its system prompt + behavior live
  // in bluejay_frontend_v2, NOT the voice livekit_agent. route prompt/behavior failures there.
  ignored_instruction: "bluejay-ai-dev/bluejay_frontend_v2",
  over_refusal:        "bluejay-ai-dev/bluejay_frontend_v2",
  looped:              "bluejay-ai-dev/bluejay_frontend_v2",
  // abandoned | none | unknown | null → no target → NO_FIX (deliberately ABSENT from the map).
};

// the bluebic allowlist: exactly the repos the map can emit. the runner asserts the
// resolved target is in-scope before checkout; the PAT scope must match this set.
export const ALLOWED_REPOS = new Set(Object.values(REPO_MAP));

// resolveRepo returns [repo | null, confident]. an unmapped failure_mode (abandoned/none/
// null) returns [null, false] → prepare.mjs / ship.mjs treat a null target as an immediate
// NO_FIX: no checkout, no agent, no PR. never fall through to a default-repo "guess fix".
export function resolveRepo(failureMode) {
  const repo = REPO_MAP[failureMode];
  return repo ? [repo, true] : [null, false];
}
