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
    echo '{"ok":true,"data":{"agents":[{"status":"working"},{"status":"idle"}]}}'
    ;;
  list)
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
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -f ]; then
    output=$2
    shift 2
  else
    shift
  fi
done
cat > "$output" <<'SAMPLE'
    100 Thread_1 DispatchQueue_1: com.apple.main-thread
      11 stepTransactionFlush
      13 GraphHost.flushTransactions()
      17 addGlyph
      19 rebuildRow
      23 wyhash
SAMPLE
EOF

chmod +x "$BIN"/*

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
grep -Eq '17\.00% +-[[:space:]]+addGlyph' <<< "$MEASURE_OUTPUT"
grep -Eq '19\.00% +-[[:space:]]+rebuildRow' <<< "$MEASURE_OUTPUT"
grep -Eq '23\.00% +-[[:space:]]+wyhash' <<< "$MEASURE_OUTPUT"

echo 'performance measurement script tests passed'
