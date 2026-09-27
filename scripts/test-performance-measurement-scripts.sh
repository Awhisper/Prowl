#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

BIN="$TEST_ROOT/bin"
MEASUREMENTS="$TEST_ROOT/measurements"
mkdir -p "$BIN" "$MEASUREMENTS"

REAL_PS=$(command -v ps)

cat > "$BIN/ps" <<EOF
#!/bin/bash
set -euo pipefail
if [[ "\$*" == *"-o time="* ]]; then
  state="$TEST_ROOT/ps-state"
  value=0
  if [ -f "\$state" ]; then value=1; fi
  : > "\$state"
  printf '00:00:0%s\n' "\$value"
elif [[ "\$*" == *"-o etime="* ]]; then
  echo '00:10'
elif [[ "\$*" == *"pid,%cpu,comm"* ]]; then
  printf '  PID %%CPU COMM\n%s 75.0 /Applications/Prowl Debug.app/Contents/MacOS/ProwlApp\n' "\${PROWL_PID:-1}"
else
  exec "$REAL_PS" "\$@"
fi
EOF

cat > "$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat > "$BIN/uptime" <<'EOF'
#!/bin/bash
echo '01:00  up 1 day,  load averages: 1.00 2.00 3.00'
EOF

cat > "$BIN/sysctl" <<'EOF'
#!/bin/bash
echo 12
EOF

cat > "$BIN/prowl" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1" in
  agents)
    # A slow agents answer must not push the pane snapshot past the sample window.
    if [ -n "${PROWL_FAKE_AGENTS_STALLS:-}" ]; then exec /bin/sleep 30; fi
    echo '{"ok":true,"data":{"agents":[{"status":"working"},{"status":"idle"}]}}'
    ;;
  list)
    # A stalled CLI must not block or delay the sample.
    if [ -n "${PROWL_FAKE_LIST_STALLS:-}" ]; then exec /bin/sleep 30; fi
    # A snapshot that arrives after sampling has ended must never be saved.
    if [ -n "${PROWL_FAKE_LIST_AFTER_SAMPLE:-}" ]; then
      for _ in $(seq 1 3000); do
        [ -f "$PROWL_FAKE_TIMES_DIR/sample-ended" ] && break
        /bin/sleep 0.01
      done
    fi
    if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
      /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$PROWL_FAKE_TIMES_DIR/list-answered"
    fi
    cat <<'JSON'
{"ok":true,"data":{"items":[
  {"worktree":{"id":"w1"},"tab":{"id":"t1","selected":true},"pane":{"id":"p1","focused":true,"visible":true}},
  {"worktree":{"id":"w1"},"tab":{"id":"t1","selected":true},"pane":{"id":"p2","focused":false,"visible":true}},
  {"worktree":{"id":"w2"},"tab":{"id":"t2","selected":true},"pane":{"id":"p3","focused":false,"visible":false}}
]}}
JSON
    ;;
  *) exit 64 ;;
esac
EOF

cat > "$BIN/top" <<EOF
#!/bin/bash
for _ in \$(seq 1 20); do echo "\${PROWL_PID:-1} 50.0"; done
EOF

cat > "$BIN/sample" <<'EOF'
#!/bin/bash
set -euo pipefail
if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$PROWL_FAKE_TIMES_DIR/sample-started"
fi
seconds=$2
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
# The timing cases need a sample that lasts its requested duration, like sample(1).
if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
  /bin/sleep "$seconds"
fi
cat > "$output" <<'SAMPLE'
    100 Thread_1 DispatchQueue_1: com.apple.main-thread
      11 stepTransactionFlush
      13 GraphHost.flushTransactions()
      7 flushTransactions
      17 addGlyph
      19 rebuildRow
      23 wyhash
SAMPLE
if [ -n "${PROWL_FAKE_TIMES_DIR:-}" ]; then
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f\n", time' > "$PROWL_FAKE_TIMES_DIR/sample-ended.tmp"
  mv "$PROWL_FAKE_TIMES_DIR/sample-ended.tmp" "$PROWL_FAKE_TIMES_DIR/sample-ended"
fi
EOF

chmod +x "$BIN"/*

# The saved pane snapshot must have been answered while the fake sample was running.
assert_snapshot_inside_sample() {
  local times=$1
  local started ended answered
  started=$(cat "$times/sample-started")
  ended=$(cat "$times/sample-ended")
  answered=$(cat "$times/list-answered")
  awk -v start="$started" -v end="$ended" -v answered="$answered" \
    'BEGIN { exit !(answered >= start && answered <= end) }' || {
    echo "pane snapshot answered at $answered, outside the sample from $started to $ended" >&2
    exit 1
  }
}

SPIKE_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$MEASUREMENTS" \
    PROWL_SPIKE_INTERVAL=1 \
    PROWL_SPIKE_MAX_WAIT=1 \
    PROWL_SPIKE_CONSECUTIVE=1 \
    bash "$ROOT/scripts/capture-cpu-spike.sh" 50 1
)

SPIKE_DIR=$(find "$MEASUREMENTS/spikes" -mindepth 1 -maxdepth 1 -type d)
test -f "$SPIKE_DIR/panes.json"
grep -Fq \
  'pane mix: total=3   visible=2   focused=1   tabs=2   selected_tabs=2   worktrees=2' \
  <<< "$SPIKE_OUTPUT"

rm -f "$TEST_ROOT/ps-state"
STALL_MEASUREMENTS="$TEST_ROOT/stall-measurements"
mkdir -p "$STALL_MEASUREMENTS"
STALL_STARTED=$SECONDS
STALL_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$STALL_MEASUREMENTS" \
    PROWL_SPIKE_INTERVAL=1 \
    PROWL_SPIKE_MAX_WAIT=1 \
    PROWL_SPIKE_CONSECUTIVE=1 \
    PROWL_FAKE_LIST_STALLS=1 \
    bash "$ROOT/scripts/capture-cpu-spike.sh" 50 1
)
STALL_ELAPSED=$((SECONDS - STALL_STARTED))
[ "$STALL_ELAPSED" -lt 10 ] || { echo "stalled prowl list held the spike capture for ${STALL_ELAPSED}s" >&2; exit 1; }
STALL_DIR=$(find "$STALL_MEASUREMENTS/spikes" -mindepth 1 -maxdepth 1 -type d)
grep -Fq 'stepTransactionFlush' "$STALL_DIR/sample.txt"
grep -Fq '{"ok":false}' "$STALL_DIR/panes.json"
grep -Fq 'pane mix: CLI unavailable' <<< "$STALL_OUTPUT"

rm -f "$TEST_ROOT/ps-state"
SLOW_AGENTS_MEASUREMENTS="$TEST_ROOT/slow-agents-measurements"
TIMES="$TEST_ROOT/times"
mkdir -p "$SLOW_AGENTS_MEASUREMENTS" "$TIMES"
SLOW_AGENTS_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$SLOW_AGENTS_MEASUREMENTS" \
    PROWL_SPIKE_INTERVAL=1 \
    PROWL_SPIKE_MAX_WAIT=1 \
    PROWL_SPIKE_CONSECUTIVE=1 \
    PROWL_FAKE_AGENTS_STALLS=1 \
    PROWL_FAKE_TIMES_DIR="$TIMES" \
    bash "$ROOT/scripts/capture-cpu-spike.sh" 50 1
)
SLOW_AGENTS_DIR=$(find "$SLOW_AGENTS_MEASUREMENTS/spikes" -mindepth 1 -maxdepth 1 -type d)
grep -Fq '{"ok":false}' "$SLOW_AGENTS_DIR/agents.json"
grep -Fq '"ok":true' "$SLOW_AGENTS_DIR/panes.json"
grep -Fq 'pane mix: total=3' <<< "$SLOW_AGENTS_OUTPUT"
assert_snapshot_inside_sample "$TIMES"

# A prowl list that answers only after sampling has ended must be refused, however
# late the shell got to the queries after launching the sample.
rm -f "$TEST_ROOT/ps-state"
LATE_LIST_MEASUREMENTS="$TEST_ROOT/late-list-measurements"
LATE_TIMES="$TEST_ROOT/late-times"
mkdir -p "$LATE_LIST_MEASUREMENTS" "$LATE_TIMES"
LATE_LIST_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$LATE_LIST_MEASUREMENTS" \
    PROWL_SPIKE_INTERVAL=1 \
    PROWL_SPIKE_MAX_WAIT=1 \
    PROWL_SPIKE_CONSECUTIVE=1 \
    PROWL_FAKE_AGENTS_STALLS=1 \
    PROWL_FAKE_LIST_AFTER_SAMPLE=1 \
    PROWL_FAKE_TIMES_DIR="$LATE_TIMES" \
    bash "$ROOT/scripts/capture-cpu-spike.sh" 50 1
)
LATE_LIST_DIR=$(find "$LATE_LIST_MEASUREMENTS/spikes" -mindepth 1 -maxdepth 1 -type d)
if [ -f "$LATE_TIMES/list-answered" ] && grep -Fq '"ok":true' "$LATE_LIST_DIR/panes.json"; then
  assert_snapshot_inside_sample "$LATE_TIMES"
fi
grep -Fq '{"ok":false}' "$LATE_LIST_DIR/panes.json"
grep -Fq 'pane mix: CLI unavailable' <<< "$LATE_LIST_OUTPUT"

rm -f "$TEST_ROOT/ps-state"
MEASURE_OUTPUT=$(
  PATH="$BIN:$PATH" \
    PROWL_PID=$$ \
    PROWL_MEASURE_DIR="$MEASUREMENTS" \
    bash "$ROOT/scripts/measure-agent-detection-cpu.sh"
)

MEASURE_DIR=$(find "$MEASUREMENTS" -mindepth 1 -maxdepth 1 -type d ! -name spikes)
test -f "$MEASURE_DIR/panes.json"
grep -Fq \
  'total=3   visible=2   focused=1   tabs=2   selected_tabs=2   worktrees=2' \
  <<< "$MEASURE_OUTPUT"
grep -Eq '11\.00% +-[[:space:]]+stepTransactionFlush' <<< "$MEASURE_OUTPUT"
grep -Eq '13\.00% +-[[:space:]]+GraphHost\.flushTransactions\(\)' <<< "$MEASURE_OUTPUT"
grep -Eq '7\.00% +-[[:space:]]+flushTransactions \(excluding GraphHost\)' <<< "$MEASURE_OUTPUT"
grep -Eq '17\.00% +-[[:space:]]+addGlyph' <<< "$MEASURE_OUTPUT"
grep -Eq '19\.00% +-[[:space:]]+rebuildRow' <<< "$MEASURE_OUTPUT"
grep -Eq '23\.00% +-[[:space:]]+wyhash' <<< "$MEASURE_OUTPUT"

echo 'performance measurement script tests passed'
