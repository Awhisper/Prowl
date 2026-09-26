#!/bin/bash
# Measure Prowl's steady-state CPU and attribute it to the agent-detection and
# SwiftUI-flush paths, alongside the baseline recorded in
# docs-ai/032-performance-hardening/004-agent-detection-steady-state.md.
#
# A CPU percentage means nothing without its workload, so every run records the
# agent mix and the host load average next to the per-symbol attribution. Treat
# a sample taken above roughly one runnable process per core as unusable:
# starvation inflates every number, and it inflates them unevenly.
set -euo pipefail
umask 077

# Set PROWL_PID when several Debug app instances are running or an exact process
# has already been selected for an isolated measurement.
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

# Each run gets its own directory so earlier samples stay comparable.
# ~/Library/Logs is where macOS keeps user-visible diagnostics, so runs survive a
# reboot and Console.app can see them. $TMPDIR is wrong for this: it is cleared
# periodically and on reboot, which silently discards the baseline a later run is
# meant to be compared against. ~/Library/Caches would be worse still, since the
# system may evict it under disk pressure.
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
OUT="${PROWL_MEASURE_DIR:-$HOME/Library/Logs/Prowl/measurements}/$RUN_ID"
mkdir -p "$OUT"

# Keep the console output and the on-disk record identical.
exec > >(tee "$OUT/summary.txt") 2>&1

echo "pid: $PID  (up $(ps -o etime= -p "$PID" | tr -d ' '))"
echo "load: $(uptime | sed 's/.*load averages*: //')   cores: $(sysctl -n hw.ncpu)"
echo

echo "=== agent mix ==="
# Working agents drive the expensive detection path, so the mix is needed to
# compare two runs honestly.
prowl agents --json 2>/dev/null > "$OUT/agents.json" || printf '{"ok":false}\n' > "$OUT/agents.json"
jq -r 'if .ok then "total=\(.data.agents|length)   " + (.data.agents|group_by(.status)|map("\(.[0].status)=\(length)")|join("  ")) else "CLI unavailable" end' \
  < "$OUT/agents.json" 2>/dev/null || echo "CLI unavailable"
echo

echo "=== pane visibility ==="
prowl list --json 2>/dev/null > "$OUT/panes.json" || printf '{"ok":false}\n' > "$OUT/panes.json"
jq -r '
  if .ok then
    .data.items as $items
    | "total=\($items | length)"
      + "   visible=\(if $items | all(.pane | has("visible")) then $items | map(select(.pane.visible)) | length else "unknown" end)"
      + "   focused=\($items | map(select(.pane.focused)) | length)"
      + "   tabs=\($items | map(.tab.id) | unique | length)"
      + "   selected_tabs=\($items | map(select(.tab.selected) | .tab.id) | unique | length)"
      + "   worktrees=\($items | map(.worktree.id) | unique | length)"
  else "CLI unavailable" end
' < "$OUT/panes.json" 2>/dev/null || echo "CLI unavailable"
echo

echo "=== process CPU (20 s) ==="
top -l 21 -s 1 -pid "$PID" -stats pid,cpu 2>/dev/null \
  | grep -E "^ *$PID" | awk '{print $2}' | tail -20 > "$OUT/cpu.txt"
python3 - "$OUT/cpu.txt" <<'PY'
import statistics as s, sys
v = [float(x) for x in open(sys.argv[1]).read().split()]
if v:
    print(f"mean={s.mean(v):.1f}%  median={s.median(v):.1f}%  min={min(v):.1f}%  max={max(v):.1f}%")
PY
echo

echo "=== stack sample (20 s) ==="
sample "$PID" 20 -f "$OUT/sample.txt" >/dev/null 2>&1
python3 - "$OUT/sample.txt" <<'PY'
import re, sys

lines = open(sys.argv[1]).read().splitlines()
hdr = []
for i, l in enumerate(lines):
    m = re.match(r'^\s+(\d+) (Thread_\w+.*)$', l)
    if m:
        hdr.append((i, int(m.group(1)), m.group(2).strip()))
if not hdr:
    print("no thread blocks parsed")
    raise SystemExit

# (symbol, pre-fix % of one core) — baseline was 20 agents: 1 working, 2 blocked.
syms = [
    ('detectAgentState',             15.88),
    ('AgentSessionResolver.resolve(', 13.02),
    ('resolveUncached',              12.98),
    ('bestMatch',                    11.38),
    ('normalize(',                    6.70),
    ('transcriptStrings',             2.47),
    ('recentCandidates',              1.57),
    ('stepTransactionFlush',           None),
    ('GraphHost.flushTransactions()',  None),
    ('addGlyph',                       None),
    ('rebuildRow',                     None),
    ('wyhash',                         None),
    ('RepositorySectionView',          None),
    ('SidebarActiveAgentsOverlay',     None),
]
tot = {s: 0 for s, _ in syms}

for idx, (i, _t, _desc) in enumerate(hdr):
    end = hdr[idx + 1][0] if idx + 1 < len(hdr) else len(lines)
    ent = []
    for l in lines[i + 1:end]:
        m = re.search(r'(\d+) (\S.*)$', l)
        if m:
            ent.append((m.start(1), int(m.group(1)), m.group(2)))
    # Sum only the shallowest occurrences so nested frames are not double counted.
    for s, _ in syms:
        counted, mind = [], None
        for d, c, sym in ent:
            if s in sym:
                if mind is None or d <= mind:
                    counted.append(c)
                    mind = d
        tot[s] += sum(counted)

W = hdr[0][1]
print(f"window={W} samples/thread;  1 core = {W} samples\n")
print(f"{'%core':>7}  {'was':>7}   symbol")
for s, base in syms:
    pct = 100 * tot[s] / W
    was = f"{base:.2f}%" if base is not None else "  -  "
    print(f"{pct:6.2f}%  {was:>7}   {s}")

det = 100 * tot['detectAgentState'] / W
if det > 0:
    print("\ncomposition of detectAgentState (load-independent):")
    for s, base in [('AgentSessionResolver.resolve(', 82), ('bestMatch', 72), ('normalize(', 42)]:
        share = 100 * tot[s] / max(tot['detectAgentState'], 1)
        print(f"  {s:32s} {share:5.1f}%  (was {base}%)")
PY

echo
echo "run dir: $OUT"
echo "  sample.txt / cpu.txt / summary.txt / agents.json / panes.json"
