# 073 — Canvas Layout Store Deinitialization: Plan

| | |
| --- | --- |
| **Status** | Implemented (local; pending publication) |
| **Anchor date** | 2026-09-28 |
| **Primary PRs** | Pending Relay publication |
| **Related** | [005 canvas](../005-canvas-live-sessions/000-plan.md), tracker onevcat/relay-tracker#333 |

## Background

The KB/KC investigation traced store destruction during worktree switching/archiving
through `swift_task_deinitOnExecutor` into a TaskLocal invalid free on macOS 26.3.1.
Swift [#85204](https://github.com/swiftlang/swift/pull/85204) fixes allocation in the
concurrency runtime; updating the compiler does not replace the user's system runtime.

The public Prowl 2026.9.25 artifact identifies Xcode 27 (`27A266a`) as its build tool.
Its arm64 `CanvasLayoutStore` destructor still calls `swift_task_deinitOnExecutor`.
The application links the system `/usr/lib/swift/libswift_Concurrency.dylib`.

## Goals

- Avoid this runtime entry point when releasing `CanvasLayoutStore`.
- Keep main-actor isolation of observable state and existing persistence behavior.
- Exercise synchronous release under task-local storage outside a Swift Task.

## Design / Approach

Add an explicit empty `nonisolated deinit` to `CanvasLayoutStore` in
`supacode/Features/Canvas/Models/CanvasCardLayout.swift`. The store owns values,
`UserDefaults`, and the observation registrar; it has no actor-bound teardown work.
Persistence already occurs on mutation, not on destruction.

Add a focused test in `supacodeTests/CanvasLayoutStoreTests.swift`. Dispatch onto the
main queue to escape the test runner's Swift Task, verify there is no current task,
establish task-local storage, release the store, and verify lifetime and persistence.
Use a standalone extraction of production source to compare old/new simulator runtimes
and inspect generated SIL. Simulator evidence corroborates the runtime defect but does
not substitute for macOS 26.3.1 UI regression.

## Alternatives & decisions

- Rely on Xcode 27: rejected because the current Xcode 27 artifact retains the call.
- Raise the minimum OS: unnecessarily drops supported users for a local workaround.
- Remove main-actor isolation or change every isolated deinit: broadens the change and
  risks invalid teardown elsewhere. Limit the mitigation to the confirmed store.

## Amendments
