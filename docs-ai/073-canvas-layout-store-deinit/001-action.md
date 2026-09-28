# 073 — Canvas Layout Store Deinitialization: Action Log

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-09-28 | Verified the Xcode 27 release artifact's store destructor; implemented the explicit nonisolated destructor and synchronous TaskLocal regression test | Local branch `fix/canvas-layout-store-deinit`; remote publication pending Relay |

## Outcome & current state (as of 2026-09-28)

`CanvasLayoutStore` in `supacode/Features/Canvas/Models/CanvasCardLayout.swift` now has
an explicit empty `nonisolated deinit`. Keep it even though it performs no cleanup:
removing it reintroduces the compiler-inferred isolated destructor under the project's
default main-actor isolation. State access remains main-actor isolated. The store does
not need main-actor work during teardown; persistence remains in property observers.

`supacodeTests/CanvasLayoutStoreTests.swift` adds release coverage in a main-queue
callback with no current Swift Task and a live TaskLocal binding. It checks synchronous
lifetime completion, preservation/restoration of the binding, and persistence after
release. On a fixed system runtime the original code can also pass; the affected-runtime
comparison and compiler-output inspection establish the workaround's necessity.

### Why Xcode 27 alone does not resolve this path

The public [2026.9.25 release](https://github.com/onevcat/Prowl/releases/tag/v2026.9.25)
records `DTXcode=2700`, `DTXcodeBuild=27A266a`, and `DTSDKName=macosx27.0`.
Its arm64 executable UUID is `D4B8E8A4-DAE3-32CD-8F1F-1714D93E9D62`.
The downloaded ZIP SHA-256 is
`962ce57aaccb74b3cb37409c32da1c918753dd51f0d5d275b72bbc9534bd117d`.

For this artifact, Swift metadata identifies `CanvasLayoutStore` at `0x101c503f0`.
The singleton metadata template is `0x1021169e8`; its heap destructor slot at
`0x1021169d8` rebases to `0x1004332c8`. Disassembly of that function ends in a branch
at `0x100433338` to the imported `swift_task_deinitOnExecutor`. The binary links the
system `/usr/lib/swift/libswift_Concurrency.dylib`; it does not bundle a replacement.
Thus the current Xcode 27 release still reaches the old system runtime's failing path.

Swift [#85204](https://github.com/swiftlang/swift/pull/85204) changes TaskLocal runtime
allocation, not the application's generated destructor. Swift
[#88036](https://github.com/swiftlang/swift/issues/88036) documents the matching
synchronous task-local release failure and the distinction between compiler and runtime.

### Validation

- Extracted the production store, its payload, and layout value type, adding only the
  explicit `Observation` import normally supplied by the app's module imports.
- Xcode 26.6 / Swift 6.3.3, optimized simulator executable: original source aborts on
  iOS 26.2 with `StopLookupScope` / `swift_task_deinitOnExecutorImpl` / invalid-free
  frames. The patched version completes 10,000 synchronous releases outside a Task.
- The same original and patched executables each complete 10,000 releases on iOS 26.4.
- Xcode 26.3 and 26.6 SIL: the original destructor calls `swift_task_deinitOnExecutor`;
  the patched destructor does not.
- `make check` passes, including 210 Python script tests, formatting, lint, workflow
  naming, and string-catalog validation.
- `make build-app` passes with Xcode 26.6 (0 errors, 0 warnings).
- `CanvasLayoutStoreTests`: 5 tests pass, zero failures or skips, confirmed from the
  result bundle. The final test source also avoids the weak-variable mutability warning.

## Deviations from plan

No Xcode 27 installation is available on the investigation host. Its actual published
artifact was inspected instead. The host runs macOS 26.5.2, so affected-runtime execution
uses iOS simulators rather than macOS 26.3.1. Xcode 26.6 selects versioned dependency
manifests for its older Swift toolchain, replacing the `swift-issue-reporting` pin with
`xctest-dynamic-overlay` during local validation. The generated lockfile change is not
part of the fix; release-toolchain validation must use the repository's original pins.

## Open questions

- Run switching/archiving regression on macOS 26.3.1 and verify the patched build with
  the release Xcode 27 toolchain before publication. No claim of a full macOS 26.3.1
  app-level reproduction is made.
- This mitigation covers KB/KC's confirmed store only. It does not resolve KD's
  separate input-method crash or justify changing other classes' teardown isolation.
