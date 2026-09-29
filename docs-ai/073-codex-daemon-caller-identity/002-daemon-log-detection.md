# 073.002 — Daemon-Mode Codex Log Detection

## Context

`CodexLogProvider` found rollouts through the open files of the pane's Codex TUI. A TUI
attached to Codex's shared daemon holds none, so the state machine reported
`screen.noLiveTurn` and relied on the screen alone. That is how the 2026-09-28 symptom
(#838) became visible: the screen rules missed a Codex 0.158 footer and nothing else knew
the turn was open.

## Change

- `CodexDaemonThreadMapper.binding(surfaceID:daemonPID:tuiStartedAt:)` returns the rollouts
  a pane drives: the root thread of its newest indexed submit plus every descendant the
  daemon holds open. The session log must belong to the current TUI process (its header
  within 120 s after the process start), so a log left by an earlier TUI cannot bind.
- The rollout index now honors the live boundary of forked rollouts (client ids and
  `task_started` count only after the rollout's own `thread_settings_applied`) and records
  the byte offset of the live `task_started` that precedes each client id.
- `CodexLogProvider` falls back to that binding when the TUI's inventory is complete and
  holds no rollout. It finds the daemon through `daemon.pid` under the TUI's `CODEX_HOME`
  and checks that the pid is still the managed daemon. A newly discovered bound rollout
  starts at that turn offset instead of its end, because binding happens only after the
  turn's user item is written, which is after `task_started`.
- `AgentDetectionCoordinator` passes its pane's surface id to the provider.

Measured before the change: `/fork` in Codex 0.158 writes only the fork's own items, and a
forked subagent copies `task_started` but not user items before its live boundary.

## Refs

PR #840 (stacked on #839).

## Current state

Live acceptance in a Debug instance with an isolated `CODEX_HOME` daemon, two hand-typed
Codex panes in one cwd:

| Scenario | `detection_reason` |
| --- | --- |
| Before the first submit | `screen.noLiveTurn` (unbound) |
| Concurrent turns in both panes | each `log.openWork`, then `log.turnEnded` at its own end |
| Subagent running while the parent waits | `log.openWork` throughout |
| `/new` then a new turn | `log.openWork` on the new thread |
| Steered message during a turn | `log.openWork` throughout |
| Restart with `codex resume` of an older thread, then a turn | `log.openWork` (live offset) |
| Esc interrupt | `log.turnEnded` |
