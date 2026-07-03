---
comments:
- actor: wballard
  id: 01kwkrcnt1rwg7s9vabnqc1y1p
  text: |-
    Implemented. New: Sources/CodeContextKit/LSP/LspDaemon.swift — LspDaemonState enum (notStarted/notFound/starting/running(pid)/failed(reason,attempts)/shuttingDown), ConnectionHandle+ConnectionFactory (pid/isAlive/waitForExit/terminate/stderrTail hooks bundled alongside the connection so LanguageServerConnection stays scoped to LSP requests only), and LspDaemon<Connection: LanguageServerConnection> actor with start()/healthCheck()/restartWithBackoff()/forceRestart()/shutdown() plus a processConnectionFactory() extension for production wiring to ProcessLanguageServerConnection. Backoff matches Rust's daemon.rs restart_with_backoff exactly (delay = backoffDuration(consecutiveFailures) at the CURRENT count, not off-by-one).

    New tests: Tests/CodeContextKitTests/LspDaemonTests.swift (12 tests, all against FakeLanguageServerConnection + ManualClock, no real process spawns) covering full lifecycle, backoff sequence, give-up-at-5, forceRestart reset, resetDocuments-on-crash, and handshake-timeout->kill (via a private HangingInitializeConnection).

    Found and fixed two real bugs in ProcessLanguageServerConnection.swift while building this (pre-existing, exposed by the new tests):
    1. FileHandle.availableData raises an uncatchable NSException when closed concurrently with a blocked read on another thread — crashed the test process. Fixed by reading via a raw POSIX read(2) on a file descriptor captured once in init (never touching FileHandle from the detached background threads).
    2. The newer FileHandle.read(upToCount:) API (my first fix attempt) loops internally trying to fill the full requested byte count rather than returning as soon as data is available — deadlocks against a live process that wrote less than the chunk size. Verified empirically before settling on the raw read(2) fix.

    Also added pid/isRunning()/waitUntilExit()/recentStderrTail() to ProcessLanguageServerConnection (needed for the production connection factory), with new tests in ConnectionTests.swift, plus a "stderr" action added to scripted-lsp-server.swift's DSL to test it.

    Ran a double-check adversarial review (via Task tool) which found close() only sent SIGTERM (not a guaranteed kill, unlike Rust's kill_on_drop/child.kill()), plus a shutdown()-vs-healthCheck() reentrancy gap leaving consecutiveFailures stale after a clean shutdown, and a session() identity-changes-per-restart caveat that wasn't documented. Fixed: close() now sends SIGKILL directly (the "ask nicely" grace period is the daemon's job via the JSON-RPC shutdown/exit dance before ever calling terminate()); shutdown() now resets consecutiveFailures to 0; session()'s doc comment now explains callers must re-fetch after a restart rather than caching.

    Deviation: LspSession in this Swift port is rebuilt fresh on every successful start() (LspSession's connection is an immutable `let`) rather than the Rust design of one persistent LspSession over a swappable Arc<Mutex<client>>. Documented on session()'s doc comment; flagged for LspSupervisor (next task, ^7rejsfy) to be aware of.

    Verification: swift build clean; full `swift test` green (268 tests, 20 suites), including 3 stress-repeats each of ConnectionTests and LspDaemonTests to check the concurrency-sensitive paths. Leaving in doing for /review.
  timestamp: 2026-07-03T10:29:03.425709+00:00
- actor: wballard
  id: 01kwkwwe6fhwn91j8nd94r2222
  text: 'Implemented LspDaemon actor (state machine notStarted→starting→running→failed→shuttingDown, PATH lookup, handshake timeout, backoff restart 1-60s capped, give-up-at-5, graceful shutdown), tested against FakeLanguageServerConnection+ManualClock, checkpointed (71389d8). Found and fixed 2 real pre-existing concurrency bugs in ProcessLanguageServerConnection during implementation/testing: FileHandle.availableData crash-on-concurrent-close, FileHandle.read(upToCount:) deadlock, and an EINTR-mishandled-as-EOF bug caught by stress testing — all replaced with correct raw POSIX read(2). Also fixed real test flakiness (subprocess-spawn contention) by serializing ConnectionTests. Stress-tested 20x full-suite + 15x filtered, no flakiness. Flagged a note for the future LspSupervisor task (^7rejsfy): session() must be re-fetched after each daemon restart since this port rebuilds a fresh LspSession per successful start() rather than Rust''s persistent-session-over-swappable-client design. Review clean on first pass despite large diff, moved doing → review → done.'
  timestamp: 2026-07-03T11:47:34.223246+00:00
depends_on:
- 01KWJ3S972X06D1TKBDBCVB3SD
position_column: done
position_ordinal: 8f80
title: 'LspDaemon actor: state machine, handshake, health, backoff auto-restart'
---
## What
Create `Sources/CodeContextKit/LSP/LspDaemon.swift` — port of `crates/swissarmyhammer-lsp/src/daemon.rs` as an actor owning one child process + its connection + session. State machine `notStarted → starting → running(pid) → failed(reason, attempts) → shuttingDown`, observable via AsyncStream. Lifecycle per plan.md: PATH lookup (miss → .notFound + installHint logged once); spawn; initialize (rootUri, empty capabilities) + initialized bounded by spec.startupTimeout, capturing a stderr tail into handshake errors; health check = process-exit detection; on unexpected exit log .error with status, tear down connection, `session.resetDocuments()`, → .failed, restart with backoff 1,2,4,8,16,32,60s cap, give up after 5 consecutive failures; success resets counter; `forceRestart()` resets counter; graceful shutdown (shutdown req → exit notif → wait, 5s grace, then kill). Connection factory + clock injected so tests never spawn real servers.

## Acceptance Criteria
- [x] Induced crash (fake connection dies) triggers restart with correct backoff sequence and a resetDocuments call between attempts (manual test clock)
- [x] Sixth consecutive failure leaves state .failed permanently until forceRestart
- [x] Graceful shutdown sends shutdown+exit and reaches .notStarted within the grace bound

## Tests
- [x] `Tests/CodeContextKitTests/LspDaemonTests.swift` with injected fake connection factory + manual clock: full lifecycle, backoff sequence values, give-up-at-5, forceRestart reset, handshake-timeout → kill path
- [x] Run `swift test --filter LspDaemonTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.