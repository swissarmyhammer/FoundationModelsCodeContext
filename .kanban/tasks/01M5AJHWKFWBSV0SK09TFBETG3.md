---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5aksy8vp6xmm6gk5t3dp930
  text: |-
    Cause found (implement):
    - Diagnostics added first: `ReaderLoopProgress` (phase, bytes, frames of the stdout reader loop), one content-safe `.warning` record on a request timeout in `Log.lspWire` (server, pid, method, id, server running, reader phase/bytes/frames; no payload, no stderr), and in ConnectionTests a timeout attachment (`Attachment.record`, kept with `swift test --attachments-path`) with pid, running, reader progress, a marker file the scripted server writes (new DSL action `mark`) and the stderr tail.
    - Repro with the retry removed locally (build once, APFS clone of .build per run, 6 concurrent `swift test --skip-build --scratch-path`, 40 `yes`): rounds r1-r4 24/24 passed, r5 run4 failed with `.timeout(30.0 seconds)` in requestReceivesItsScriptedTypedResponse. Attachment: `server running: false`, `reader loop: stopped, 243 bytes, 1 frames`, markers `started / read the request / wrote the response`. So the server answered and exited, and the reader loop read and decoded the response: it was lost between the reader and the waiter.
    - Where: `PendingRequestTable`. Under load the task that registers the continuation (`awaitResponse` child task) starts late. Order: `expectResponse` -> write -> server answers and exits -> reader `resolveOrBuffer` = `.buffered` -> reader reads EOF -> `failAll(notRunning)`, which DISCARDED `earlyResponses` -> only then `register` stores the continuation, which nothing resumes until the 30 s timeout. A second defect in the same path: any registration after `failAll` waited for the timeout instead of failing at once.
    - The old unit test `failAllDiscardsABufferedEarlyResponseSoALaterRegistrationDoesNotReceiveIt` asserted the buggy contract (it imagined an id reused after failAll; ids are monotonic per connection and the table is dead after failAll). It is replaced by the two tests of the correct contract.
  timestamp: 2026-10-19T17:37:01.723084+00:00
- actor: claude-code
  id: 01m5ammk57tv7ay8pgzx33ysgc
  text: |-
    ### implement — changed
    - fix: `PendingRequestTable.failAll(with:)` keeps each buffered early response and records its error; `register(id:continuation:)` takes a buffered response first, and after `failAll` resumes at once with that error instead of waiting for the timeout. TDD: `PendingRequestTableTests.aResponseBufferedBeforeFailAllStillReachesTheLaterRegistration` (RED: `.timeout(30.0 seconds)`, the same error as the flake) and `aRegistrationAfterFailAllWithNoBufferedResponseGetsTheErrorOfFailAll` (RED: caseName timeout); both GREEN after the fix. Old test `failAllDiscardsABufferedEarlyResponseSoALaterRegistrationDoesNotReceiveIt` removed: it asserted the bug.
    - diagnostics kept (content-safe): `ReaderLoopProgress` + `readerLoopProgress()`; `.warning` "a request to the language server timed out" in `Log.lspWire` with new MetadataKeys `process.pid`, `lsp.server.running`, `lsp.reader.phase`, `lsp.reader.bytes`, `lsp.reader.frames` (tests: `aRequestTimeoutLogsTheStateOfTheServerAndOfTheReaderLoopButNoStandardErrorText` asserts no stderr text in any record, `theReaderLoopProgressIsStoppedAfterTheServerExits`). Test-only: ConnectionTests timeout attachment (pid, running, reader progress, marker file, stderr tail), scripted-server action `mark`, `theMarkStepsOfAnAnsweredRequestWriteEachMarkerInOrder`.
    - load proof, retry removed locally: before fix 1 timeout in 30 runs (r1-r5), attachment showed server exited after writing the response and reader read 243 bytes / 1 frame. After fix 36/36 concurrent full runs passed (rounds f1-f6, 6 at once on APFS clones, 40 `yes`), 0 timeouts. All `yes` killed (pgrep 0), clones deleted.
    - retry put back: `withRetryOnSpawnContention` and its call are as at HEAD (the inner `withConnection` call only gains `markerFile:`).
    - tests: `swift test` 1062 tests / 94 suites passed (incl. TelemetryContentSafetyTests); `swift test --package-path IntegrationTests` 22 tests / 16 suites passed; `swift format lint --strict --recursive Sources Tests` clean. Only warning: the allowed mlx-swift "missing creator for mutated node".
    - files: Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift, Sources/FoundationModelsCodeContext/LSP/ReaderLoopProgress.swift (new), Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift, Tests/FoundationModelsCodeContextTests/CodeContextTracingTests.swift, Tests/FoundationModelsCodeContextTests/ConnectionTests.swift, Tests/FoundationModelsCodeContextTests/PendingRequestTableTests.swift, Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift
    - next: /review; then ^60jmzth can remove the retry.
  timestamp: 2026-10-19T17:51:35.079290+00:00
- actor: claude-code
  id: 01m5amsqqph3ng4sdc8psw4ffg
  text: |-
    ### test — green
    - evidence: swift build complete; swift test 1062 tests in 94 suites passed; swift test --package-path IntegrationTests 22 tests in 16 suites passed; swift format lint --strict clean (no output). 0 failures, 0 skipped. Only warning: allowed mlx-swift_Cmlx "missing creator for mutated node".
    - next: review
  timestamp: 2026-10-19T17:54:23.606928+00:00
position_column: doing
position_ordinal: '8280'
title: 'ConnectionTests timeout under load: log the server state when a request times out, and find the second cause of the lost response'
---
## What
With `withRetryOnSpawnContention` removed (^60jmzth), `ConnectionTests.requestReceivesItsScriptedTypedResponse` still fails with `.timeout(30.0 seconds)` in 2 of 23 concurrent full root `swift test` runs under load. The load was 5–6 runs at once, each with its own APFS clone of `.build` and `--skip-build`, plus 40 `yes > /dev/null` on 30 cores. Both failures came right at suite start. The scripted server cold-starts in 1.7–1.9 s under the same load, so the server was up and the response was lost. ^t71wvkm fixed one cause (a read end closed under a live read loop, then its fd number reused). This is a second cause.

## Change
1. **Diagnostics first.** When a request on `ProcessLanguageServerConnection` times out, log (content-safe, no payloads) or capture in the test:
   - whether the server process is alive;
   - whether the reader loop is running and how many bytes and frames it has read;
   - the end of the server's stderr, in the test only;
   - whether the server got the request. The scripted server can write a marker to stderr or to a file when it reads a request.
2. Reproduce with the load setup above. Use the diagnostics to find where the response is lost: it was never written, written to the wrong fd, read by a different loop, or read but not delivered to the waiter.
3. **Fix the cause** with a failing test first (TDD), the same way ^t71wvkm did with `ProcessUtilitiesReadLoopTests`.
4. Keep the diagnostics if they are content-safe and cheap; otherwise remove them.

## Acceptance
- With the retry removed locally, 0 timeouts in at least 20 concurrent full runs under the load above.
- Plain `swift test` and `swift test --package-path IntegrationTests` pass.
- ^60jmzth can then remove the retry. #test-flake