---
comments:
- actor: wballard
  id: 01kwm9bdjaa8m2bvmv1cefvckh
  text: |-
    Implemented `Sources/CodeContextKit/LSP/LspSupervisor.swift` (actor `LspSupervisor<Connection: LanguageServerConnection>`) and `Tests/CodeContextKitTests/LspSupervisorTests.swift` (13 tests) via TDD.

    What it does: `start()` runs `ProjectDetection.detectProjects`/`serverSpecs(for:)`, spawns one `LspDaemon` per unique command concurrently, starts a per-daemon health-check loop paced by `spec.healthCheckInterval` that restarts only daemons landing in `.failed`. Exposes `status()`, `forceRestart(command:)`, `shutdown()`, `session(forFileExtension:)` (routes via `Languages.module` -> `languageServer.command`), `anySession()`. Session-re-fetch-after-restart handled correctly: supervisor never caches a session, always calls `daemon.session()` fresh on each `session(forFileExtension:)`/`anySession()` call.

    Review cycle: `double-check` found two real concurrency races on first pass — (1) concurrent `start()` calls could race past the dedupe check and orphan duplicate daemons/health-loop tasks, (2) `shutdown()` fired `cancel()` on health-loop tasks without awaiting their actual completion, so an in-flight restart past its cancellation checks could resurrect a daemon after `shutdown()` had already returned. Fixed both: `start()` now coalesces concurrent callers onto one in-flight `Task` (`inFlightStart`); `shutdown()` now awaits every health-loop task's completion before tearing down any daemon. Also extracted duplicated `ProcessState`/`fakeConnectionFactory`/`Box` test helpers (previously duplicated between this file and `LspDaemonTests.swift`) into shared `Tests/CodeContextKitTests/Support/FakeDaemonProcess.swift`.

    Second double-check round found the two new regression tests were vacuous (passed even against the reverted/buggy code, verified empirically by the reviewer reverting and re-running). Rewrote both to actually exercise the races: the coalescing test now counts daemon-construction attempts via a new test-only hook (`setDaemonConstructedHookForTesting`, needed because `connectionFactory` never runs unless a real binary is on PATH); the shutdown-race test now uses a gated fake connection (`RestartGate`/`GatedConnection`, a bare `CheckedContinuation` immune to cancellation) to genuinely stall an in-flight restart handshake before racing `shutdown()` against it. I independently verified both regression tests by manually reverting each production fix and re-running — both fail correctly against the buggy code (confirmed the shutdown race corrupts state to `.failed` instead of `.notStarted`) and pass against the fix.

    Verification: `swift test` — 328/328 tests pass across 27 suites, fresh run. `swift test --filter LspSupervisorTests` stress-tested 15+ consecutive runs, zero flakes. `swift build` clean (no new warnings). Leaving in `doing` for review per /implement workflow.
  timestamp: 2026-07-03T15:25:28.010858+00:00
depends_on:
- 01KWJ3TKKJPVWDQVZ2VG79RQ70
- 01KWJ3RH1RE9WJY5353AHD6JSK
position_column: doing
position_ordinal: '80'
title: 'LspSupervisor actor: spec collection, daemon fleet, health loop'
---
## What
Create `Sources/CodeContextKit/LSP/LspSupervisor.swift` — port of `crates/swissarmyhammer-lsp/src/supervisor.rs`, minus election. On `start()`: run project detection, collect `ServerSpec`s from detected modules deduped by command, create one `LspDaemon` per unique command (all with workspace rootDirectory as rootUri), start them concurrently. Own the periodic health loop (spec.healthCheckInterval, injectable clock) calling each daemon's health check → auto-restart path. Expose `status() -> [ServerStatus]`, `forceRestart(command:)`, `shutdown()` (concurrent graceful teardown), `session(forFileExtension:)` routing an extension to its daemon's session via `Languages.all`, and `anySession()`.

## Acceptance Criteria
- [x] Polyglot fixture (rust + two js dirs) starts exactly two daemons (rust-analyzer, typescript-language-server) — dedupe verified
- [x] Health tick on a dead daemon triggers its restart; healthy daemons untouched
- [x] `session(forFileExtension: "ts")` and `"tsx"` return the same session; unknown extension returns nil

## Tests
- [x] `Tests/CodeContextKitTests/LspSupervisorTests.swift` with injected daemon/connection fakes + manual clock: dedupe, routing, health-loop restart dispatch, concurrent shutdown completes
- [x] Run `swift test --filter LspSupervisorTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.