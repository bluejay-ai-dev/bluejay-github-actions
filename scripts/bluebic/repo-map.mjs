// maps a judge failure_mode to the bluejay repo whose code most likely owns the fix.
// static, NOT llm-guessed: keeps the github token's repo scope minimal + auditable.
// seed from the taxonomy doc's "write sites"; expand later from the live ErrorCode
// distribution. owner is bluejay-ai-dev; the values here ARE the bluebic allowlist.
export const REPO_MAP = {
  tool_error:          "bluejay-ai-dev/bluejay_middleware",   // integration/tool call sites
  knowledge_gap:       "bluejay-ai-dev/knowledge_base",       // kb/rag/grounding content
  ignored_instruction: "bluejay-ai-dev/bluejay_middleware",   // prompt / instruction-following
  over_refusal:        "bluejay-ai-dev/bluejay_middleware",   // guardrails / policy
  handoff_failure:     "bluejay-ai-dev/bluejay_middleware",   // escalation routing
  looped:              "bluejay-ai-dev/bluejay_middleware",   // state tracking
  abandoned:           "bluejay-ai-dev/bluejay_middleware",   // triage catch-all
};

export const DEFAULT_REPO = "bluejay-ai-dev/bluejay_middleware";

// v1 allowlist is exactly the two repos the map can emit, so the runner can assert
// the resolved target is in-scope before checking it out.
export const ALLOWED_REPOS = new Set(Object.values(REPO_MAP));

// resolveRepo returns [repo, confident]. confident=false → prepare.mjs flags low
// confidence in the prompt + PR body so a human double-checks the target.
export function resolveRepo(failureMode) {
  const repo = REPO_MAP[failureMode];
  return repo ? [repo, true] : [DEFAULT_REPO, false];
}
