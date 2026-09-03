// Reads the Bluejay AI chat stream from inside the page.
//
// Playwright buffers a streaming response body until it closes, which hides whether the
// stream ever opened and gives nothing back until the model has finished thinking. This
// wraps fetch instead, so tool calls are visible as they happen and a stream that opens
// and stalls is distinguishable from one that never opened.
//
// Everything it sees lands on window.__bjai. chat-tap.test.mjs proves the parsing against
// a stub server, since getting this wrong would fail open: no events looks the same as no
// instrumentation.
export async function installChatTap(ctx) {
  await ctx.addInitScript(() => {
    const S = (window.__bjai = { chat: [], uploads: [], events: [], blocks: [], tools: [],
                                 toolErrors: [], bodies: [], done: false, errors: [] });
    const orig = window.fetch;
    window.fetch = async (...args) => {
      const url = String(typeof args[0] === "string" ? args[0] : (args[0]?.url ?? ""));
      const res = await orig(...args);
      try {
        if (/\/api\/chat-files\//.test(url)) {
          S.uploads.push({ url: url.replace(/^https?:\/\/[^/]+/, ""), status: res.status });
          if (!res.ok) S.bodies.push(await res.clone().text().catch(() => ""));
        } else if (/\/api\/chat(\?|$)/.test(url)) {
          S.chat.push({ status: res.status });
          if (!res.ok) { S.bodies.push(await res.clone().text().catch(() => "")); return res; }
          if (!res.body) return res;
          const [mine, theirs] = res.body.tee();
          (async () => {
            const rd = mine.getReader(), dec = new TextDecoder();
            let buf = "";
            for (;;) {
              const { done, value } = await rd.read();
              if (done) break;
              buf += dec.decode(value, { stream: true });
              let i;
              while ((i = buf.indexOf("\n")) >= 0) {
                const line = buf.slice(0, i).trim();
                buf = buf.slice(i + 1);
                if (!line) continue;
                let ev; try { ev = JSON.parse(line); } catch { continue; }
                S.events.push(ev.type);
                const b = ev.content_block;
                if (ev.type === "content_block_start" && b?.type) {
                  S.blocks.push(b.type);
                  if (b.type === "mcp_tool_use") S.tools.push(b.name ?? "?");
                  if (b.type === "mcp_tool_result" && b.is_error)
                    S.toolErrors.push(JSON.stringify(b).slice(0, 400));
                }
                if (ev.type === "message_stop") S.done = true;
              }
            }
            S.done = true;
          })();
          return new Response(theirs, { status: res.status, statusText: res.statusText, headers: res.headers });
        }
      } catch (e) { S.errors.push(String(e)); }
      return res;
    };
  });
}
