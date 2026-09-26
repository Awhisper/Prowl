#!/bin/bash
# Capture a stack sample of Prowl at the moment its CPU crosses a threshold.
#
# `sample(1)` only sees its own window, so a runaway that has already passed is
# invisible no matter how long the sample runs — averaging a spike over a long
# window is what hides it. This watches until the spike is happening and samples
# then, unattended.
#
# Usage:  bash scripts/capture-cpu-spike.sh [threshold_percent] [sample_seconds]
#         bash scripts/capture-cpu-spike.sh 150 10      # default
#
# Environment:
#   PROWL_SPIKE_INTERVAL   seconds between CPU checks (default 2)
#   PROWL_SPIKE_MAX_WAIT   give up after this many seconds (default 7200)
#   PROWL_SPIKE_CONSECUTIVE  readings above threshold before firing (default 2)
#   PROWL_PID             exact process to watch; required when several Debug apps run
#   PROWL_MEASURE_DIR      where runs are written
#                          (default ~/Library/Logs/Prowl/measurements)
set -euo pipefail
umask 077

THRESHOLD=${1:-150}
SAMPLE_SECONDS=${2:-10}
INTERVAL=${PROWL_SPIKE_INTERVAL:-2}
MAX_WAIT=${PROWL_SPIKE_MAX_WAIT:-7200}
NEEDED=${PROWL_SPIKE_CONSECUTIVE:-2}

usage_error() {
  echo "$1" >&2
  exit 64
}

require_positive_integer() {
  local name=$1
  local value=$2
  case "$value" in
    '' | *[!0-9]*) usage_error "$name must be a positive integer." ;;
  esac
  [ "$value" -gt 0 ] || usage_error "$name must be greater than zero."
}

require_positive_integer threshold_percent "$THRESHOLD"
require_positive_integer sample_seconds "$SAMPLE_SECONDS"
require_positive_integer PROWL_SPIKE_INTERVAL "$INTERVAL"
require_positive_integer PROWL_SPIKE_MAX_WAIT "$MAX_WAIT"
require_positive_integer PROWL_SPIKE_CONSECUTIVE "$NEEDED"

resolve_prowl_pid() {
  if [ -n "${PROWL_PID:-}" ]; then
    require_positive_integer PROWL_PID "$PROWL_PID"
    kill -0 "$PROWL_PID" 2>/dev/null || {
      echo "PROWL_PID $PROWL_PID is not running." >&2
      return 1
    }
    printf '%s\n' "$PROWL_PID"
    return
  fi

  local matches
  local count
  matches=$(ps -Ao pid=,comm= | awk '/\/Prowl Debug\.app\/Contents\/MacOS\/ProwlApp$/ { print $1 }')
  count=$(printf '%s\n' "$matches" | awk 'NF { count += 1 } END { print count + 0 }')
  case "$count" in
    0)
      echo "Prowl Debug is not running." >&2
      return 1
      ;;
    1)
      printf '%s\n' "$matches"
      ;;
    *)
      printf 'Several Prowl Debug processes are running (%s). Set PROWL_PID explicitly.\n' "$matches" >&2
      return 1
      ;;
  esac
}

PID=$(resolve_prowl_pid)

# ~/Library/Logs is where macOS keeps user-visible diagnostics, so a captured
# spike survives a reboot and Console.app can see it. $TMPDIR is wrong for this:
# it is cleared periodically and on reboot, and a spike capture is worth keeping
# precisely because the spike is hard to catch a second time.
OUT="${PROWL_MEASURE_DIR:-$HOME/Library/Logs/Prowl/measurements}/spikes/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUT"

# `ps -o %cpu` is a decayed average since launch, which lags a sudden spike by
# far too much to trigger on. Differencing consumed CPU time over a known
# interval gives the real instantaneous figure instead.
cpu_seconds() {
  ps -o time= -p "$1" 2>/dev/null | tr -d ' ' |
    awk -F: '{
      days = 0
      first = $1
      if (split(first, day_and_hour, "-") == 2) {
        days = day_and_hour[1]
        first = day_and_hour[2]
      }
      total = first
      for (i = 2; i <= NF; i++) total = total * 60 + $i
      print days * 86400 + total
    }'
}

echo "watching pid $PID for >= ${THRESHOLD}% of one core"
echo "  checking every ${INTERVAL}s, need ${NEEDED} consecutive, giving up after ${MAX_WAIT}s"
echo "  output: $OUT"
echo

PREV=$(cpu_seconds "$PID")
[ -z "$PREV" ] && { echo "Could not read CPU time for pid $PID." >&2; exit 1; }

STREAK=0
# A bounded loop rather than `while true`, so the watcher always terminates.
ITERATIONS=$((MAX_WAIT / INTERVAL))
for _ in $(seq 1 "$ITERATIONS"); do
  sleep "$INTERVAL"
  NOW=$(cpu_seconds "$PID")
  if [ -z "$NOW" ]; then
    echo "pid $PID exited before a spike was seen." >&2
    exit 1
  fi
  PCT=$(awk -v a="$PREV" -v b="$NOW" -v t="$INTERVAL" 'BEGIN { printf "%.0f", (b - a) / t * 100 }')
  PREV=$NOW

  if [ "$PCT" -ge "$THRESHOLD" ]; then
    STREAK=$((STREAK + 1))
    echo "$(date +%H:%M:%S)  ${PCT}%  (${STREAK}/${NEEDED})"
  else
    [ "$STREAK" -gt 0 ] && echo "$(date +%H:%M:%S)  ${PCT}%  (reset)"
    STREAK=0
    continue
  fi

  [ "$STREAK" -ge "$NEEDED" ] || continue

  echo
  echo "=== spike: sampling for ${SAMPLE_SECONDS}s ==="
  # Context first: a spike figure without its workload cannot be compared to any
  # other run, and the host may simply be overcommitted.
  {
    echo "triggered_at: $(date -Iseconds)"
    echo "observed:     ${PCT}% of one core (threshold ${THRESHOLD}%)"
    echo "pid:          $PID  (up $(ps -o etime= -p "$PID" | tr -d ' '))"
    echo "load:         $(uptime | sed 's/.*load averages*: //')   cores: $(sysctl -n hw.ncpu)"
    echo
    echo "top host processes:"
    ps -Ao pid,%cpu,comm -r | sed -n '1,8p'
  } > "$OUT/context.txt"
  cat "$OUT/context.txt"

  prowl agents --json 2>/dev/null > "$OUT/agents.json" || printf '{"ok":false}\n' > "$OUT/agents.json"
  jq -r 'if .ok then "agent mix: total=\(.data.agents|length)   "
      + (.data.agents|group_by(.status)|map("\(.[0].status)=\(length)")|join("  "))
    else "CLI unavailable" end' < "$OUT/agents.json" 2>/dev/null || true

  prowl list --json 2>/dev/null > "$OUT/panes.json" || printf '{"ok":false}\n' > "$OUT/panes.json"
  jq -r '
    if .ok then
      .data.items as $items
      | "pane mix: total=\($items | length)"
        + "   visible=\(if $items | all(.pane | has("visible")) then $items | map(select(.pane.visible)) | length else "unknown" end)"
        + "   focused=\($items | map(select(.pane.focused)) | length)"
        + "   tabs=\($items | map(.tab.id) | unique | length)"
        + "   selected_tabs=\($items | map(select(.tab.selected) | .tab.id) | unique | length)"
        + "   worktrees=\($items | map(.worktree.id) | unique | length)"
    else "pane mix: CLI unavailable" end
  ' < "$OUT/panes.json" 2>/dev/null || true

  # Keep the header: it carries the window size every later attribution needs.
  sample "$PID" "$SAMPLE_SECONDS" -f "$OUT/sample.txt" >/dev/null 2>&1
  echo
  echo "captured: $OUT/sample.txt  ($(wc -l < "$OUT/sample.txt" | tr -d ' ') lines)"
  echo "          $OUT/context.txt  $OUT/agents.json  $OUT/panes.json"
  exit 0
done

echo "no spike >= ${THRESHOLD}% seen within ${MAX_WAIT}s." >&2
exit 2
