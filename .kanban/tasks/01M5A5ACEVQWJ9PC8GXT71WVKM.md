---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5aaqx8311qkb5q08903rda9
  text: |-
    Research (implement):
    - Reproduced. Plain 4x concurrent full runs: 4/4 pass (test ~1.1 s). 6 concurrent full runs + 40 `yes` CPU hogs: 1/6 then 3/6 runs fail with exactly `.handshakeFailed("operation timed out after 30.0 seconds")` after 30.0 s (the FIRST handshake in `daemon.start()`). One run also failed LoggingContentTests (hover answer nil after the 10 s request timeout), same "answer never arrives" class.
    - NOT the `swift <script>` compile: cold module cache start = 1.3 s, warm 0.4 s. A watcher that `sample`d each scripted-lsp-server alive > 12 s caught 3 stuck `swift-frontend -interpret` processes: running script, main thread blocked in `read(0)` (stdin) inside `-[NSConcreteFileHandle availableData]`, no grandchild in the group. So the server got `initialize`, answered it, and waits for `initialized`: the client never saw the answer.
    - Cause: `ProcessLanguageServerConnection.close()` closes `stdoutHandle`/`stderrHandle` while the dedicated reader/stderr threads still read those descriptors by raw number (`ProcessUtilities.readChunk` documents that it expects "the underlying descriptor has been closed out from under it"). Darwin reuses a freed descriptor number at once (probe: closed fd 3, next `pipe()` returned 3). A read loop that is between reads, or whose thread has not started yet (`runOnDedicatedThread` starts the thread from a cooperative-pool Task, and the scale tests saturate the pool), then reads the stdout pipe of a NEW connection and swallows its `initialize` response. This is also the likely cause of the earlier ConnectionTests "response never arrives" flake (^01KWVSJAR801YR97D051YDWPR5), which was masked with a retry.
    - Probes: `close(2)` wakes a blocked pipe `read(2)` with 0 on Darwin; `dup2(/dev/null)` over the fd wakes it too but the next read gives EBADF, so no fd tricks.
    - `ServerInstaller.startDrain` is already safe: its thread keeps the Pipe and nothing else closes the read end. HardKilledHostTests and LivePylspJediTests go through the same `ProcessLanguageServerConnection`, so they share the risk and the same fix covers them.
    - Plan: each read loop owns its read end and closes it itself after its last read; `close()` no longer closes stdout/stderr read ends (the SIGKILL of the group gives the loops EOF).
  timestamp: 2026-10-19T14:58:37.955024+00:00
- actor: claude-code
  id: 01m5acep2ne7286rc6atatjzqy
  text: |-
    Implementation landed (not committed):
    - `ProcessUtilities.runReadLoop(name:readEnd:_:)` (new): runs a pipe read loop on a dedicated thread with the descriptor of `readEnd`, and closes `readEnd` itself after the body returns. The loop is the one owner of its read end.
    - `ProcessLanguageServerConnection`: the stdout reader loop and the stderr drain loop start through `runReadLoop`; the stored `stdoutHandle`/`stderrHandle` are gone; `close()` closes only the stdin write end (the SIGKILL of the group gives both loops EOF, and each loop then closes its own read end). Doc comments of `close()`, `closeOutOfStepConnection` and `readChunk` updated (`readChunk` no longer describes a descriptor "closed out from under it").
    - `ServerInstaller.startDrain`: uses `runReadLoop` too (it was already safe via `withExtendedLifetime`; now one ownership rule for every pipe read loop).
    - TDD: new unit suite `Tests/FoundationModelsCodeContextTests/ProcessUtilitiesReadLoopTests.swift` (3 tests; reads the read-end state through `EPIPE` on the write end with `F_SETNOSIGPIPE`, never through the descriptor number, because a parallel test can reuse it). RED: `theLoopClosesTheReadEndAfterTheBodyReturns` failed against a stub that did not close (write succeeded); GREEN after the close.
    - What did not work / was ruled out: precompiling the script is not needed, since compile time is not the cause (1.3 s cold). `dup2(/dev/null)` over the descriptor to wake a reader gave EBADF on the next read, so I rejected descriptor tricks. HardKilledHostTests and LivePylspJediTests use the same connection, so they share the risk and the fix; no change was needed in those suites.
    - Not done here (new tasks): ^60jmzth remove the `withRetryOnSpawnContention` retry from ConnectionTests (it hid this cause); ^nvydq0p ProcessGroupChild signals `-pid` after the reap (one loaded run exited 143/SIGTERM, pids wrapping near 99999, likely pid reuse); ^3a92r6p the mlx-swift "missing creator for mutated node" build warning is back (present at HEAD without this change, verified by stashing the four files).
  timestamp: 2026-10-19T15:28:32.853446+00:00
- actor: claude-code
  id: 01m5acetrkgs9mqdk9qgtb7awe
  text: |-
    ### implement — changed
    - evidence: cause = `ProcessLanguageServerConnection.close()` closed the stdout/stderr read ends while the read-loop threads still read them by descriptor number; Darwin reuses the number at once, so a stale loop read the next connection's stdout and swallowed its `initialize` response (sampled stuck server: blocked in `read(0)` waiting for `initialized`). Files: Sources/FoundationModelsCodeContext/LSP/ProcessUtilities.swift, Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift, Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift, Tests/FoundationModelsCodeContextTests/ProcessUtilitiesReadLoopTests.swift (new). Runs: before fix, 6 concurrent full integration runs + 40 CPU hogs failed 1/6 and 3/6 with the exact handshake timeout; after fix, the same load passed 6/6 and 5/6 (the sixth was killed by an external SIGTERM, exit 143, see ^nvydq0p; no handshake timeout, no stuck server sampled). Acceptance: 5/5 consecutive plain `swift test --package-path IntegrationTests` passed (22 tests each). Unit: `swift test` 1052 tests / 93 suites passed. `swift format lint --strict` clean. Only warning: pre-existing mlx-swift "missing creator for mutated node" (^3a92r6p).
    - next: /review
  timestamp: 2026-10-19T15:28:37.652001+00:00
- actor: claude-code
  id: 01m5acnerkx8ck0pgwmn12e51w
  text: |-
    ### test — green
    - evidence: swift build ok; swift test 1052 tests in 93 suites passed (0 failed, 0 skipped); swift test --package-path IntegrationTests 22 tests in 16 suites passed; swift format lint --strict --recursive Sources Tests clean after fixing CodeEntitiesTests.swift (AddLines/Indentation on a multi-element #expect array literal, formatted with swift format). Only warning: known mlx-swift_Cmlx "missing creator for mutated node" (^3a92r6p, ^kw00hcn).
    - next: review
  timestamp: 2026-10-19T15:32:14.739686+00:00
- actor: claude-code
  id: 01m5actdeqmkdw72xd22n0hj1m
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1c9d41d) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 5 files reviewed, 10 .kanban/ files excluded by .reviewignore
    - next: none — task moved to done
  timestamp: 2026-10-19T15:34:57.239199+00:00
- actor: claude-code
  id: 01m5acv076e3y8y5shab68p3a5
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files (ProcessUtilities.runReadLoop owns and closes each pipe read end; close() closes only stdin)
    - test: green — swift test 1052 passed; IntegrationTests 22 passed; swift format lint --strict clean
    - commit: 1c9d41d
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-19T15:35:16.454081+00:00
position_column: done
position_ordinal: ff80
title: LanguageServerGrandchildTests.forceRestartKillsTheGrandchildOfTheOldServer times out in the handshake under full-suite load
---
## What
In a full `swift test --package-path IntegrationTests` run (2026-10-19, during ^b91evm0 test step) this test failed once:
`LanguageServerGrandchildTests.forceRestartKillsTheGrandchildOfTheOldServer()` → `.handshakeFailed("operation timed out after 30.0 seconds")` at `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LanguageServerGrandchildTests.swift:52`, while the live SourceKit and scale tests ran in parallel. The suite alone passed (3 tests, 0.8 s); the next full run passed. No code change between runs.

The test was added in 40fde36 (^sgdcvtq). It starts the scripted server via `swift <script>`, and that compile-and-start is slow under parallel load. The same class of flake was fixed before for ConnectionTests (01KWVSJAR801YR97D051YDWPR5) and ProcessInstallRunnerTests (01M56861Y5R6151E7REVQPCB1T); check how those were fixed and follow the same pattern.

## TDD
1. Reproduce: run the full integration suite several times (or with parallel load) and confirm the handshake timeout; note the frequency.
2. Fix the cause, not just the timeout number. For example, use the shared precompiled scripted-server path or the retry-on-spawn-contention helper that ConnectionTests uses, or serialize the process-heavy suites.
3. Check the other new suites from 40fde36 (HardKilledHostTests, LivePylspJediTests) for the same risk.

## Acceptance
- 5 consecutive full `swift test --package-path IntegrationTests` runs pass with this test included. #test-flake