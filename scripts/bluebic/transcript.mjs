// plain-JS port of the dashboard's lib/bluebic/transcript.ts renderTranscript.
// keep these byte-for-byte equivalent: the github agent must see the SAME numbered,
// tool-I/O transcript the local runner + the judge see, NOT a raw JSON dump.
//
//   [T1] Customer: ...
//   [T2] Assistant: [tool inventory_lookup state=output input={…} → output={…}]
//   [T2] Assistant: <text>
//
// message shape (from chats.messages, via MCP or the supabase fallback):
//   user:      { role: "user", text }
//   assistant: { role: "assistant", parts: [{ type: "tool"|"text", name, state, inputJson, outputText, content }] }

function trunc(s, n) {
  return s.length > n ? s.slice(0, n) + "…[truncated]" : s;
}

export function renderTranscript(messages) {
  if (!Array.isArray(messages)) return "";
  const lines = [];
  messages.forEach((m, i) => {
    const t = i + 1;
    if (m.role === "user") {
      lines.push(`[T${t}] Customer: ${trunc(m.text ?? "", 4000)}`);
      return;
    }
    for (const part of m.parts ?? []) {
      if (part.type === "tool") {
        const input = trunc(part.inputJson ?? "", 500);
        const output = trunc(part.outputText ?? "", 800);
        lines.push(`[T${t}] Assistant: [tool ${part.name ?? "unknown"} state=${part.state ?? "?"} input=${input} → output=${output}]`);
      } else if (part.content) {
        lines.push(`[T${t}] Assistant: ${trunc(part.content, 4000)}`);
      }
    }
  });
  return lines.join("\n");
}
