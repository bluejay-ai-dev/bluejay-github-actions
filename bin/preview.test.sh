#!/usr/bin/env bash
# Offline checks for preview.sh. gh is stubbed so the real jq predicate runs against a
# fixture: the ticket-to-branch rule is the only part of a preview that decides what gets
# deployed, so it is the part worth a test.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { printf '  ok    %s\n' "$1"; }
no() { printf '  FAIL  %s\n%s\n' "$1" "$2"; fail=1; }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1" "got:
$2
want:
$3"; }

cat > "$TMP/prs.json" <<'JSON'
[
 {"repository":{"name":"bluejay_frontend_v2"},"title":"[ENG-756] preview envs","headRefName":"lt-preview"},
 {"repository":{"name":"bluejay_middleware"},"title":"[ENG-7561] unrelated","headRefName":"lt-other"},
 {"repository":{"name":"livekit_agent"},"title":"[ENG-756] agent bit","headRefName":"lt-agent--np"},
 {"repository":{"name":"evals"},"title":"ENG-756 evals bit","headRefName":"lt-ev"},
 {"repository":{"name":"bluejay_frontend_v2"},"title":"[ENG-756] second pr","headRefName":"lt-dup"}
]
JSON

cat > "$TMP/gh" <<EOF
#!/usr/bin/env bash
q=""; r=""
while [ \$# -gt 0 ]; do
  case "\$1" in -q) q=\$2; shift ;; -R) r=\${2##*/}; shift ;; esac
  shift
done
jq --arg r "\$r" "[.[] | select(.repository.name == \\\$r)] | \$q" "$TMP/prs.json" | tr -d '"'
EOF
chmod +x "$TMP/gh"
run() { PATH="$TMP:$PATH" "$HERE/preview.sh" "$@"; }

is "resolve takes the first PR per repo, skips --np and ENG-7561" \
   "$(run resolve ENG-756)" \
   "$(printf 'bluejay_frontend_v2\tlt-preview')"

is "a ticket with no PRs resolves to nothing" "$(run resolve ENG-999)" ""
is "a bad ticket is refused" \
   "$(run resolve 'ENG-1"; touch /tmp/pwned #' 2>&1 || true)" \
   'not a ticket id: ENG-1"; touch /tmp/pwned #'

for f in preview.sh preview-boot.sh; do
  bash -n "$HERE/$f" && ok "$f parses" || no "$f parses" ""
done

# A run block that interpolates a caller-controlled value is shell injection, and previews
# are dispatched by anyone who can push a branch.
wf="$HERE/../.github/workflows/preview.yml"
bad=$(awk '
  match($0, /^ *run:/) { base = RLENGTH - 5; inrun = 1; line = $0 }
  inrun && !match($0, /^ *run:/) {
    indent = match($0, /[^ ]/) - 1
    if ($0 ~ /^ *$/) next
    if (indent <= base) { inrun = 0; next }
    line = $0
  }
  inrun && line ~ /\$\{\{/ { print FNR ": " line }
' "$wf")
[ -z "$bad" ] && ok "workflow never interpolates caller input into a run block" \
  || no "workflow never interpolates caller input into a run block" "$bad"

[ "$fail" = 0 ] && echo "preview ok" || { echo "preview WRONG" >&2; exit 1; }
