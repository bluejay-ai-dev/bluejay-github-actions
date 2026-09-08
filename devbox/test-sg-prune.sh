#!/usr/bin/env bash
# ensure_sg revokes rules. Getting the selection wrong either locks an engineer out or
# leaves someone else's access to rot, so the choice is asserted against a fixture
# rather than against a live security group.
set -euo pipefail
cd "$(dirname "$0")"
BJ_LIB=1 BJ_OWNER=alice source ./bj

got="$(stale_rules 1.2.3.4/32 " 22 3001 8001 " <<'TBL'
sgr-keep-ssh	alice	1.2.3.4/32	22
sgr-keep-fe	alice	1.2.3.4/32	3001
sgr-old-ip	alice	9.9.9.9/32	22
sgr-old-block	alice	1.2.3.4/32	3007
sgr-bob	bob	9.9.9.9/32	22
sgr-nodesc	None	9.9.9.9/32	22
TBL
)"
want="sgr-old-ip
sgr-old-block"

[ "$got" = "$want" ] || { printf 'FAIL\ngot:\n%s\nwant:\n%s\n' "$got" "$want" >&2; exit 1; }
echo "sg prune ok"
