#!/usr/bin/env python3
"""Render the release-gating page from two tsv dumps. No state, no server."""
import html, os, re, sys, time
from collections import defaultdict

open_tsv, dev_tsv, out = sys.argv[1:4]
ORG = os.environ.get("ORG", "bluejay-ai-dev")
ORDER = ["bluejay_middleware", "livekit_agent", "text_agent", "evals", "docs",
         "bluejay_frontend_v2"]
TICKET = re.compile(r"\bENG-\d+\b")

feats, untracked = defaultdict(list), []
for line in open(open_tsv):
    repo, num, title, url, labels, draft = (line.rstrip("\n").split("\t") + [""] * 6)[:6]
    if not repo:
        continue
    row = dict(repo=repo, num=num, title=title, url=url,
               labels=[l for l in labels.split(",") if l], draft=draft == "true")
    m = TICKET.search(title)
    (feats[m.group()].append(row) if m else untracked.append(row))

on_dev = defaultdict(set)
for line in open(dev_tsv):
    if line.strip():
        tid, repo = line.split("\t")
        on_dev[tid].add(repo.strip())

def order(repos):
    return sorted(repos, key=lambda r: ORDER.index(r) if r in ORDER else len(ORDER) - 1)

def clean(t):
    return html.escape(re.sub(r"^\[?ENG-\d+\]?:?\s*", "", t))[:78]

def chips(rows):
    out = []
    for r in order({x["repo"] for x in rows}):
        pr = next(x for x in rows if x["repo"] == r)
        cls = "chip draft" if pr["draft"] else "chip"
        out.append(f'<a class="{cls}" href="{pr["url"]}">{r.replace("bluejay_","")}'
                   f'<span class=n>#{pr["num"]}</span></a>')
    return "".join(out)

rows = []
for tid, prs in sorted(feats.items(), key=lambda kv: -len({r["repo"] for r in kv[1]})):
    repos = {r["repo"] for r in prs}
    hold = any("do-not-promote" in r["labels"] for r in prs)
    state, note = ("solo", "") if len(repos) == 1 else ("multi", f"{len(repos)} repos")
    if hold:
        state, note = "hold", "do-not-promote"
    rows.append(f'''<tr class="{state}">
      <td><a href="https://linear.app/getbluejay/issue/{tid}">{tid}</a></td>
      <td class=t>{clean(prs[0]["title"])}</td>
      <td>{chips(prs)}</td>
      <td class=s>{note}</td></tr>''')

dev_rows = "".join(
    f'<tr><td><a href="https://linear.app/getbluejay/issue/{t}">{t}</a></td>'
    f'<td colspan=3>{" ".join(order(r))}</td></tr>' for t, r in sorted(on_dev.items())
) or '<tr><td colspan=4 class=empty>dev is clean, everything on it is already on main</td></tr>'

untracked_rows = "".join(
    f'<tr class=untracked><td class=s>no ticket</td><td class=t>{clean(r["title"])}</td>'
    f'<td>{chips([r])}</td><td></td></tr>' for r in untracked)

open(out, "w").write(f"""<!doctype html><meta charset=utf-8><title>Release gating</title>
<style>
 :root{{color-scheme:dark}}
 body{{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:#0a0a0a;color:#c9c9c9;
   padding:40px 32px;max-width:1180px;margin:0 auto}}
 h1{{font-size:14px;color:#fff;margin:0 0 2px;font-weight:600;letter-spacing:.02em}}
 h2{{font-size:11px;color:#666;margin:34px 0 8px;text-transform:uppercase;letter-spacing:.08em;font-weight:500}}
 p.sub{{color:#5a5a5a;margin:0}}
 table{{border-collapse:collapse;width:100%}}
 td{{padding:6px 10px;border-bottom:1px solid #171717;vertical-align:top}}
 td:first-child{{width:80px}} td.t{{color:#8f8f8f;width:44%}} td.s{{color:#5a5a5a;font-size:11px;text-align:right}}
 a{{color:#6f9bd8;text-decoration:none}} a:hover{{text-decoration:underline}}
 .chip{{display:inline-block;background:#161616;border:1px solid #232323;border-radius:3px;
   padding:1px 6px;margin:1px 3px 1px 0;color:#a8a8a8;font-size:11px}}
 .chip .n{{color:#5a5a5a;margin-left:5px}}
 .chip.draft{{opacity:.45}}
 tr.multi td:first-child a{{color:#e0a458}}
 tr.hold td{{background:#170e0e}} tr.hold td.s{{color:#d05f5f}}
 tr.untracked td:first-child{{color:#c05555}}
 .empty{{color:#444}}
 .legend{{margin-top:28px;color:#4a4a4a;font-size:11px;line-height:1.7}}
</style>
<h1>Release gating &middot; {ORG}</h1>
<p class=sub>generated {time.strftime('%Y-%m-%d %H:%M')} &middot; grouped by the ENG id in the PR title, nothing stored</p>

<h2>In flight &middot; {len(feats)} features</h2>
<table>{''.join(rows)}</table>

<h2>Waiting on dev to be promoted</h2>
<table>{dev_rows}</table>

<h2>No ticket in the title &middot; {len(untracked)}</h2>
<table>{untracked_rows or '<tr><td colspan=4 class=empty>none</td></tr>'}</table>

<p class=legend>
 Amber ticket id = touches more than one repo, so those PRs merge and promote together.<br>
 Red rows would fail the ticket-gate check once it is required, and are invisible to every query on this page.<br>
 Promoting any repo pulls in every repo listed for every ticket sitting on its dev.
</p>
""")
