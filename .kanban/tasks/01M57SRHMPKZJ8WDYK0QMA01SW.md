---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57szhy4py2k9js7rk93s0sr
  text: |-
    Research:
    - The "hang" step in Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift sleeps in a loop of `hangSleepInterval` (3600 s) and does not read stdin.
    - Users of "hang": ConnectionTests (5 tests) and IntegrationTests (LSPRequestSpanTests, LSPCancelRequestTests, LSPRequestMetricsTests, LoggingContentTests, TelemetryContentSafetyTests). All of them stop the script with close(). No test needs the script to stay alive after stdin closes.
    - ConnectionTests cannot close only stdin: ProcessLanguageServerConnection has no such operation. Thus the new test goes into IntegrationTests. It starts the script with `ProcessGroupChild.spawn` (through @testable import). That type reaps the child on its own thread, thus `processExists(pid)` becomes false after the exit.
    - ProcessGroupChild uses POSIX_SPAWN_CLOEXEC_DEFAULT, thus the child does not hold the write end of its own stdin pipe.
    - Plan: the hang step reads stdin until EOF, discards the bytes, then calls exit(0). `ScriptedLSPServer` in IntegrationSupport.swift gets one helper for the script arguments, which withConnection and the new test both use.
    - No orphan scripted-lsp-server process before the work.
  timestamp: 2026-10-18T15:27:13.860738+00:00
- actor: claude-code
  id: 01m57t7gj76pz6ekfjj06149gd
  text: |-
    Implementation:
    - The "hang" step now calls `StandardInputMessageReader.discardUntilEndOfInput()`. That function reads stdin until EOF and discards the bytes, then the step calls exit(0). The step answers no request, and stdout stays open while stdin is open. The constant `hangSleepInterval` is gone (dead code).
    - The read also keeps the stdin pipe empty, thus a write of the client to a script at a hang step never blocks.
    - New test IntegrationTests/.../ScriptedLSPServerHangTests.swift `aHangStepStopsTheScriptWhenItsStandardInputCloses`. It starts the script with `ProcessGroupChild.spawn`, waits on the stderr marker of the step before "hang" (a state, not a time), checks `processExists(pid)`, closes the stdin write end, and polls `!processExists(pid)` with the named budget `exitBudget` (30 s). The cleanup sends SIGKILL to the group and waits for the reap.
    - New helper `ScriptedLSPServer.arguments(steps:)` in IntegrationSupport.swift. `withConnection` and the new test both use it.
    - RED: before the script change the test failed at `isGone` after 30.553 s (the script reached the hang step and stayed alive). GREEN: passed after 0.367 s.
    - The script source changed, thus the cache name `scripted-lsp-server-<sha256>.swift` changed. This is expected.
    - The build warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle" is in each build. It is the upstream warning that ^kw00hcn recorded; this change did not add it.
  timestamp: 2026-10-18T15:31:34.599636+00:00
- actor: claude-code
  id: 01m57t7mgbpsyqnvwfehnrr79k
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/IntegrationSupport.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/ScriptedLSPServerHangTests.swift (new). `swift test --package-path IntegrationTests --filter ScriptedLSPServerHangTests`: RED 1 failed, then GREEN 1 passed. `swift test --package-path IntegrationTests --filter 'TelemetryContentSafetyTests|LoggingContentTests|ScriptedLSPServerHangTests|LSPRequestMetricsTests|LSPRequestSpanTests|LSPCancelRequestTests|LanguageServerProcessGroupTests'`: 10 tests in 7 suites passed. `swift test --filter 'ConnectionTests|ScriptedLSPServerScriptTests'`: 26 tests in 2 suites passed. Full root `swift test`: 1015 tests in 90 suites passed, 0 failed. Only warning: the upstream Cmlx bundle warning of ^kw00hcn. Orphan scripted-lsp-server processes: none before, none after. Both acceptance-criteria boxes checked.
    - next: /review
  timestamp: 2026-10-18T15:31:38.635603+00:00
- actor: claude-code
  id: 01m57tbv1ekcdgyk6pedzbmm5w
  text: |-
    ### test — green
    - evidence: swift test (root) — 1015 tests in 90 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests — 16 tests in 13 suites passed, 0 failed, 0 skipped. The live pylsp and live SourceKit tests ran and passed.
    - warnings: only the SwiftPM warning "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from a dependency (task ^kw00hcn). No warning comes from this repo.
    - next: none. No file was changed. No commit was made.
  timestamp: 2026-10-18T15:33:56.398971+00:00
- actor: claude-code
  id: 01m57tcf9hpnnpx9ez6fg621cz
  text: |-
    ### commit — changed
    - evidence: 1ccdfa4 test: stop the hang step of the test server at the end of stdin ^qma01sw (7 files)
    - next: none. The commit is local. It is not pushed.
  timestamp: 2026-10-18T15:34:17.137348+00:00
- actor: claude-code
  id: 01m57tebt93jy27zze8d83av91
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 1ccdfa4); findings 0, confirmed 0, refuted 0; 3 files reviewed; 4 .kanban files not reviewed because of .reviewignore.
    - next: none. The task is in done.
  timestamp: 2026-10-18T15:35:19.113199+00:00
- actor: claude-code
  id: 01m57tejq6wjvcga3e9b3614fm
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files
    - test: green — swift test 1015 passed; swift test --package-path IntegrationTests 16 passed
    - commit: 1ccdfa4
    - review: clean — 0 findings
  timestamp: 2026-10-18T15:35:26.182333+00:00
position_column: done
position_ordinal: f880
title: The hang step of scripted-lsp-server must stop the script when stdin closes
---
## Problem
When the test binary crashes, `withConnection` does not call `close()`, and no code kills the process group of the scripted server. The `hang` step of `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` sleeps for ever and does not read stdin. Thus the script stays alive with parent pid 1. ^0d568qc found one such orphan: the RED run of ^s4fmb5k crashed the test binary ("Range requires lowerBound <= upperBound").

The exit of the test binary closes the write end of the stdin pipe of the script. A real language server stops at the end of stdin.

## Change
- Make the `hang` step wait for the end of stdin, and stop the script at the end of stdin. The step must still never answer a request and must keep stdout open while stdin is open.

## Acceptance criteria
- [x] A test in the IntegrationTests package or in ConnectionTests proves that a script at a `hang` step stops when its stdin closes, with `processExists(pid)`.
- [x] The existing ConnectionTests that use `hang` pass. #bug