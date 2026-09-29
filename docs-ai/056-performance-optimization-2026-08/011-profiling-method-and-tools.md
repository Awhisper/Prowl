# 056.011 — Profiling Method and Tools

## Context

The performance wave exposed a measurement problem as well as code costs: a short CPU spike is
invisible to a `sample(1)` window started after it ends, and absolute CPU percentages are not
comparable without agent mix, host load, tab count, and sampling duration. #661 records the
stepwise profile and introduces a steady-state sampler plus a CPU-threshold-triggered capture.

Review also found that the initial durable narrative described pre-review implementations rather
than the fork results: per-round fragment pruning instead of the shared LRU, detection-poll tab
title delivery instead of the clock-driven task, index-rebuild-only memo invalidation instead of
bounded canonical revalidation, and obsolete unmerged branch hashes.

## Change

- Fork integration #665 makes automatic process selection fail when more than one Debug app is
  present and supports explicit `PROWL_PID` for an already resolved target.
- Numeric watcher inputs are validated. Required `top`, `sample`, and parser failures propagate
  as failures instead of leaving an apparently successful partial run.
- Capture directories include the process ID and use a private umask, yielding user-only output
  directories and files for samples that can contain absolute paths and window titles.
- CPU-time parsing covers day-prefixed long-running processes. Agent roster capture records an
  explicit unavailable payload when the CLI cannot answer.
- Both profilers save the complete pane snapshot and report worktree, tab, selected-tab, and
  visible-pane counts. The CLI derives visibility from the surface viewport and window state.
  The spike capture launches `sample` before anything else and starts the CLI queries 0.25 s
  later. It keeps an answer only if it arrived while sampling ran, from the `Date/Time` in the
  sample's own header to that time plus the duration; otherwise it records `{"ok":false}` with
  the reason.
- Both profilers keep CLI answers only when the profiled PID serves the socket the CLI connects
  to (`PROWL_CLI_SOCKET` or the default path). Debug and Release apps share the default path, so
  otherwise the snapshot could describe another app; the files then record `{"ok":false}` with the
  socket and PID. The steady-state profiler skips the queries; the spike capture checks after the
  sample so that nothing runs before `sample`.
- The steady-state parser reports AppKit transaction flushes, SwiftUI graph flushes, and Ghostty
  glyph, row, and hash work as separate symbols.
- The detailed performance record is reconciled with #653–#657 and #662–#665, and cross-links this
  August review entry instead of preserving obsolete branch-stack claims.

## Refs

- Original PR #661
- Merged fork integration PR #665
- Detailed measurement narrative:
  [032.004](../032-performance-hardening/004-agent-detection-steady-state.md)

## Current state

The scripts default to persistent `~/Library/Logs/Prowl/measurements` output, can target an exact
PID, and fail closed when a trustworthy measurement cannot be produced. The documented before and
after percentages remain author measurements with their workload caveats; this review verified
the structural paths and the tools, not the original long captures. Each run records `agents.json`
and `panes.json` beside the process sample.

## Verification

- Both scripts passed `bash -n` and ShellCheck with no findings.
- The script regression test verifies pane capture and independent symbol attribution with fixed
  command fixtures. It also samples one PID while the CLI socket belongs to another and requires
  both snapshots to be marked unavailable.
- Invalid interval and missing-PID paths returned failures; a bounded high-threshold watcher timed
  out as designed.
- A live CPU-bound process triggered a one-second sample successfully. A separate harmless process
  completed the full 20-second CPU plus 20-second stack-sample parser path.
- Generated directories and samples were verified as `0700` and `0600` respectively.
- `make check` and `make build-app` passed for #665 with no warnings.
