#!/usr/bin/env bash
# Checks the idle accounting in ./idle-shutdown. This is the whole cost model:
# too eager and it kills running work, too lax and boxes bill 24/7.
#
#   ./test-idle-shutdown.sh
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BJ_STATE_DIR="$TMP/state"
export BJ_PROC_STAT="$TMP/stat"
export BJ_POWEROFF_CMD="touch $TMP/poweroff"
export BJ_SESSION_CMD="cat $TMP/sessions"
mkdir -p "$BJ_STATE_DIR"
: > "$TMP/sessions"

# /proc/stat jiffies: idle_delta/total_delta sets the busy percentage.
stat_at() { echo "cpu $1 0 0 $2 0 0 0 0 0 0" > "$BJ_PROC_STAT"; }
# state file is "last_epoch last_total last_idle idle_secs". Args are the previous
# sample as (elapsed_seconds, user_jiffies, idle_jiffies, idle_secs); idle is part
# of total, so total is derived rather than passed, which is easy to get wrong.
seed() { echo "$(( $(date +%s) - $1 )) $(( $2 + $3 )) $3 $4" > "$BJ_STATE_DIR/state"; }
idle_secs() { awk '{print $4}' "$BJ_STATE_DIR/state"; }
run() { ./idle-shutdown >/dev/null 2>&1; }

fail=0
ok() { printf '  ok   %s\n' "$1"; }
no() { printf '  FAIL %s (%s)\n' "$1" "$2"; fail=1; }
is() { [ "$2" = "$3" ] && ok "$1" || no "$1" "want $3, got $2"; }

echo "idle-shutdown"

# first run has no previous sample to diff against, so it only records a baseline
rm -f "$BJ_STATE_DIR/state"
stat_at 1000 9000
run
is "first run seeds state without shutting down" "$([ -e "$TMP/poweroff" ] && echo yes || echo no)" "no"
is "first run starts the counter at zero" "$(idle_secs)" "0"

# 300s elapsed, 1000 jiffies of which 990 idle -> 1% busy, nobody logged in
seed 300 1000 9000 0
stat_at 1010 9990
run
is "idle time accrues when quiet" "$(idle_secs)" "300"

# same window but only 500 of 1000 jiffies idle -> 50% busy, well over the 10% floor
seed 300 1000 9000 1500
stat_at 2000 9500
run
is "busy CPU resets the counter" "$(idle_secs)" "0"

# quiet box, but someone is ssh'd in
seed 300 1000 9000 1500
stat_at 1010 9990
echo "ubuntu pts/0 ..." > "$TMP/sessions"
run
is "an ssh session resets the counter" "$(idle_secs)" "0"
: > "$TMP/sessions"

# quiet and nobody home, but a long job asked to be left alone
seed 300 1000 9000 1500
stat_at 1010 9990
touch "$BJ_STATE_DIR/hold"
run
is "hold file resets the counter" "$(idle_secs)" "0"
rm -f "$BJ_STATE_DIR/hold"

# crossing IDLE_MINUTES (30 -> 1800s) is what actually pulls the trigger
seed 300 1000 9000 1500
stat_at 1010 9990
run
is "shuts down at the threshold" "$([ -e "$TMP/poweroff" ] && echo yes || echo no)" "yes"

# a resume from stop leaves a state file from hours ago and a reset jiffy counter
rm -f "$TMP/poweroff"
seed 100000 999999 999999 1700
stat_at 10 5
run
is "counter wrap after a stop/start resets rather than firing" "$(idle_secs)" "0"
is "...and does not shut down" "$([ -e "$TMP/poweroff" ] && echo yes || echo no)" "no"

[ "$fail" -eq 0 ] && echo "all passed" || { echo "FAILURES"; exit 1; }
