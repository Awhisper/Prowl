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

# A CLI query may take this long before it is abandoned. Its answer is only kept if it
# arrived inside the sampled window (see keep_if_sampled), so the timeout just
# bounds how long the script waits; it does not decide correctness.
CLI_TIMEOUT=$((SAMPLE_SECONDS + 5))

# sample(1) stamps its Date/Time header when sampling begins, 28-36 ms after launch in
# ten measured runs on a loaded host. The CLI queries wait this long after the launch
# so their answers normally land inside the sampled window rather than before it.
QUERY_OFFSET=0.25

# Runs a prowl query into a file, QUERY_OFFSET after the sample launch, and marks when
# the answer arrived. The marker is a file created by a shell builtin; its modification
# time is the kernel's clock. perl's alarm survives the exec.
query_cli() {
  local out=$1
  shift
  /bin/sleep "$QUERY_OFFSET"
  # The group's stderr also takes bash's own "Alarm clock" notice for a timed-out call.
  { /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$CLI_TIMEOUT" prowl "$@" > "$out"; } \
    2>/dev/null || printf '{"ok":false,"reason":"no answer within %ss"}\n' "$CLI_TIMEOUT" > "$out"
  : > "$out.answered"
}

# Prints when sample(1) began sampling, as epoch seconds, from its own Date/Time header.
sample_started_at() {
  /usr/bin/perl -MTime::Local -ne '
    if (/^Date\/Time:\s+(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)(\.\d+)? ([+-])(\d\d)(\d\d)/) {
      my $utc = timegm($6, $5, $4, $3, $2 - 1, $1) + ($7 || 0);
      my $offset = ($9 * 3600 + $10 * 60) * ($8 eq "+" ? 1 : -1);
      printf "%.3f\n", $utc - $offset;
      exit;
    }' "$1" 2>/dev/null || true
}

# Prints the socket path the prowl CLI connects to, as ProwlSocket.defaultPath does.
prowl_cli_socket() {
  if [ -n "${PROWL_CLI_SOCKET:-}" ]; then
    printf '%s\n' "$PROWL_CLI_SOCKET"
    return
  fi
  local preferred="$HOME/Library/Application Support/com.onevcat.prowl/cli.sock"
  # sockaddr_un.sun_path is 104 bytes on Darwin, including the NUL terminator.
  if [ "$(printf '%s' "$preferred" | wc -c)" -lt 104 ]; then
    printf '%s\n' "$preferred"
  else
    local tmp=${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}
    printf '%s\n' "${tmp%/}/prowl-cli.sock"
  fi
}

# Prints why the CLI does not answer for process $1, or nothing when it does. Debug
# and Release apps share the default socket path and only one app serves it, so a
# CLI answer can describe another app than the sampled one.
cli_socket_mismatch() {
  local pid=$1
  local socket
  socket=$(prowl_cli_socket)
  if ! lsof -a -U -p "$pid" -Fn 2>/dev/null | grep -Fxq "n$socket"; then
    printf 'CLI socket %s is not served by pid %s\n' "$socket" "$pid"
  fi
}

# Keeps a query's answer only if the sampled process gave it while sample(1) was
# sampling, and otherwise replaces it with {"ok":false} and the reason.
keep_if_sampled() {
  local out=$1
  local answered reason=
  answered=$(/usr/bin/stat -f %Fm "$out.answered")
  if [ -n "$SOCKET_MISMATCH" ]; then
    reason=$SOCKET_MISMATCH
  elif [ -z "$WINDOW_START" ]; then
    reason="the sample recorded no start time"
  elif awk -v a="$answered" -v s="$WINDOW_START" 'BEGIN { exit !(a < s) }'; then
    reason="answered before sampling started"
  elif awk -v a="$answered" -v e="$WINDOW_END" 'BEGIN { exit !(a > e) }'; then
    reason="answered after sampling ended"
  fi
  # An answer from another app is wrong even when the CLI reported a failure.
  if [ -n "$SOCKET_MISMATCH" ] || { [ -n "$reason" ] && jq -e '.ok' < "$out" > /dev/null 2>&1; }; then
    jq -cn --arg reason "$reason" '{ok: false, reason: $reason}' > "$out"
  fi
  rm -f "$out.answered"
}

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

  # Sample first: the spike may not last, so nothing runs ahead of the launch.
  # Keep the header: it carries the window size every later attribution needs.
  sample "$PID" "$SAMPLE_SECONDS" -f "$OUT/sample.txt" >/dev/null 2>&1 &
  SAMPLE_PID=$!
  # The CLI queries run side by side while the sample runs. Whether an answer describes
  # the sampled window is decided after the sample ends, from the sample's own clock.
  query_cli "$OUT/agents.json" agents --json &
  AGENTS_PID=$!
  query_cli "$OUT/panes.json" list --json &
  PANES_PID=$!

  echo
  echo "=== spike: sampling for ${SAMPLE_SECONDS}s ==="
  # Context is recorded while the sample runs, because a spike figure without its
  # workload cannot be compared to any other run, and the host may be overcommitted.
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

  wait "$SAMPLE_PID"
  wait "$AGENTS_PID" "$PANES_PID"
  # The window is sample(1)'s own: the Date/Time it stamps when sampling begins, which
  # carries milliseconds, plus the duration. Neither bound depends on this shell.
  WINDOW_START=$(sample_started_at "$OUT/sample.txt")
  WINDOW_END=
  if [ -n "$WINDOW_START" ]; then
    WINDOW_END=$(awk -v s="$WINDOW_START" -v d="$SAMPLE_SECONDS" 'BEGIN { printf "%.3f", s + d }')
  fi
  # Checked after the sample so that nothing delays its launch. An app binds the socket
  # only when it launches, so a PID that serves it now served it for the whole sample.
  SOCKET_MISMATCH=$(cli_socket_mismatch "$PID")
  keep_if_sampled "$OUT/agents.json"
  keep_if_sampled "$OUT/panes.json"

  jq -r 'if .ok then "agent mix: total=\(.data.agents|length)   "
      + (.data.agents|group_by(.status)|map("\(.[0].status)=\(length)")|join("  "))
    else "CLI unavailable" + (if .reason then " (\(.reason))" else "" end) end' < "$OUT/agents.json" 2>/dev/null || true

  jq -r '
    if .ok then
      .data.items as $items
      | "pane mix: total=\($items | length)"
        + "   visible=\(if $items | all(.pane | has("visible")) then $items | map(select(.pane.visible)) | length else "unknown" end)"
        + "   focused=\($items | map(select(.pane.focused)) | length)"
        + "   tabs=\($items | map(.tab.id) | unique | length)"
        + "   selected_tabs=\($items | map(select(.tab.selected) | .tab.id) | unique | length)"
        + "   worktrees=\($items | map(.worktree.id) | unique | length)"
    else "pane mix: CLI unavailable" + (if .reason then " (\(.reason))" else "" end) end
  ' < "$OUT/panes.json" 2>/dev/null || true

  echo
  echo "captured: $OUT/sample.txt  ($(wc -l < "$OUT/sample.txt" | tr -d ' ') lines)"
  echo "          $OUT/context.txt  $OUT/agents.json  $OUT/panes.json"
  exit 0
done

echo "no spike >= ${THRESHOLD}% seen within ${MAX_WAIT}s." >&2
exit 2
