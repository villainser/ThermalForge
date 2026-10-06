#!/bin/bash
#
# Measures ThermalForge's idle CPU the way docs/idle-cpu-experiments.md describes:
# per process (never system-wide), from the cumulative user/system CPU time `ps` reports,
# over a fixed window, with the number of "Instant spike" log lines in that window (spike
# logging costs CPU, so a number without its spike rate isn't comparable).
#
#   Scripts/measure-idle-cpu.sh [seconds]        default 120
#
# Before running: quit and relaunch ThermalForge, leave its menu CLOSED and untouched, and
# wait two minutes so it has settled. Run it again on the commit before the adaptive-polling
# change to get the "before" number on the same Mac.
#
# Needs no sudo: ps can read any process's CPU time.

set -u

WINDOW="${1:-120}"
case "$WINDOW" in
    ''|*[!0-9]*) echo "usage: $0 [seconds]" >&2; exit 2 ;;
esac

# "1:02:03.45", "2:03.45" or "3.45" -> seconds
to_seconds() {
    awk -F: '{
        if (NF == 3)      print $1 * 3600 + $2 * 60 + $3
        else if (NF == 2) print $1 * 60 + $2
        else              print $1
    }' <<<"$1"
}

# prints "<user seconds> <system seconds>" for a pid
cpu_times() {
    local line u s
    line=$(ps -o utime=,stime= -p "$1" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    set -- $line
    u=$(to_seconds "$1")
    s=$(to_seconds "$2")
    echo "$u $s"
}

LOG="$HOME/Library/Logs/ThermalForge/thermalforge-$(date +%F).log"
spikes() {
    if [ -f "$LOG" ]; then grep -c "Instant spike:" "$LOG" || true; else echo 0; fi
}

APP_PID=$(pgrep -x ThermalForgeApp | head -1)
DAEMON_PID=$(pgrep -f "thermalforge daemon" | head -1)

if [ -z "$APP_PID" ] && [ -z "$DAEMON_PID" ]; then
    echo "Neither ThermalForgeApp nor the thermalforge daemon is running." >&2
    exit 1
fi

echo "Window: ${WINDOW}s   (app pid: ${APP_PID:-none}, daemon pid: ${DAEMON_PID:-none})"
echo "Keep the ThermalForge menu closed and don't touch the machine until this finishes."

APP_BEFORE=""; DAEMON_BEFORE=""
[ -n "$APP_PID" ] && APP_BEFORE=$(cpu_times "$APP_PID")
[ -n "$DAEMON_PID" ] && DAEMON_BEFORE=$(cpu_times "$DAEMON_PID")
SPIKES_BEFORE=$(spikes)

sleep "$WINDOW"

report() {
    local name="$1" pid="$2" before="$3" after u0 s0 u1 s1
    if [ -z "$pid" ]; then
        printf '%-8s not running\n' "$name"
        return
    fi
    after=$(cpu_times "$pid") || { printf '%-8s exited during the window\n' "$name"; return; }
    set -- $before; u0=$1; s0=$2
    set -- $after;  u1=$1; s1=$2
    awk -v name="$name" -v w="$WINDOW" -v u0="$u0" -v s0="$s0" -v u1="$u1" -v s1="$s1" 'BEGIN {
        du = u1 - u0; ds = s1 - s0; dt = du + ds
        pct = dt / w * 100
        share = (dt > 0) ? ds / dt * 100 : 0
        printf "%-8s %6.2f%% of one core   (user %.2f%%, system %.2f%%; system share %.0f%%)\n",
               name, pct, du / w * 100, ds / w * 100, share
    }'
}

report "app"    "$APP_PID"    "$APP_BEFORE"
report "daemon" "$DAEMON_PID" "$DAEMON_BEFORE"

SPIKES_AFTER=$(spikes)
awk -v a="$SPIKES_BEFORE" -v b="$SPIKES_AFTER" -v w="$WINDOW" 'BEGIN {
    printf "spike log lines in window: %d  (%.2f per minute)\n", b - a, (b - a) / (w / 60)
}'
echo "Note: ps reports CPU time in 10 ms steps, so a short window on a very quiet process is coarse."
echo "      Use 300 or more seconds when the daemon is near zero."
