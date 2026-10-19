---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5aek8j06jyqdaqd4j51x6j4
  text: |-
    Implementation + load proof. The flake is NOT gone.

    Change (in the working tree, not committed): removed `withRetryOnSpawnContention`, its doc comment and the long comment in the test body. `requestReceivesItsScriptedTypedResponse()` now calls `Self.withConnection(steps:)` once. No retry added back.

    How the load test ran: concurrent `swift test` runs on one `.build` take turns on the SwiftPM lock ("Another instance of SwiftPM ... waiting"), so they do not overlap. So I built once (`swift build --build-tests`), made an APFS clone of `.build` for each run (`cp -cR .build <scratch>/bN`), and ran `swift test --skip-build --scratch-path <scratch>/bN` for each one at the same time, with 40 `yes > /dev/null` running (30-core machine). Every `yes` was killed afterwards (`pgrep -x yes` = 0).

    Results: 23 full root runs (rounds of 5, 6, 6, 6). 21 passed. 2 failed, and both failures were this test:
    - round 2 run 4: `✘ requestReceivesItsScriptedTypedResponse() recorded an issue at ConnectionTests.swift:161:6: Caught error: .timeout(30.0 seconds)`, failed after 41.957 s
    - round 3 run 6: same `.timeout(30.0 seconds)`, failed after 39.147 s
    That is about 9% (2/23), close to the 12-13% the old comment reported before the retry was added. No other test failed in any run.

    What I found:
    - Both failures were at the very start of the run. The test started at log line 113 or 124 of about 2480, when every suite is starting at once. All later ConnectionTests in the same failing run passed in about 0.4 s.
    - A slow interpreter start does not explain it. While 6 full runs plus 40 `yes` were going, 8 `swift <joined scripted-lsp-server>.swift '[]'` cold starts launched together each took 1.71 to 1.90 s. So the child was alive for 30+ s and the reply never came. That is the "response never arrives" mode, not "a bit slow".
    - The joined script file is written with `.atomic` and is cached by digest in /tmp/FoundationModelsCodeContextTests-501/scripted-lsp-server, so a half-written script is ruled out.
    - ProcessGroupChild spawns with POSIX_SPAWN_CLOEXEC_DEFAULT and closes the child ends after the spawn. I did not find a second descriptor-reuse path on a read, but I did not audit every close in the test process (installer, git and other Process users that run while the suites start).

    Possible next steps (not done, outside this card): when the timeout fires, log the child's state (alive or not, its stderr tail, whether it read the request), so a failing run shows which side lost the frame. Then look for another descriptor double-close or reuse that only happens while many suites are spawning at the same moment. ^t71wvkm fixed one cause. This data shows a second cause is still there.

    Plain `swift test`: 1058 tests in 94 suites passed. `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. The only warning was the known mlx-swift "missing creator for mutated node" (^3a92r6p).
  timestamp: 2026-10-19T16:06:00.000825+00:00
- actor: claude-code
  id: 01m5aekcnp0ybfj4kjbegsrv4g
  text: |-
    ### implement — stuck
    - evidence: 1 file changed: Tests/FoundationModelsCodeContextTests/ConnectionTests.swift (retry helper and its comments removed). Under load (23 concurrent full root runs on cloned scratch paths, 40 `yes`), `requestReceivesItsScriptedTypedResponse` timed out 2 times (`.timeout(30.0 seconds)`, round2-run4 and round3-run6). Cold start under the same load was 1.7-1.9 s, so the response never arrives, and the cause is not a slow start. Plain `swift test`: 1058/1058 passed. IntegrationTests: 22/22 passed. Only the known mlx warning (^3a92r6p).
    - next: a person decides. The retry was not added back. A second cause of the lost response is still there after ^t71wvkm. It needs a new investigation card (log the child state and stderr on timeout, then audit descriptor reuse while many suites spawn at once) before this card can finish.
  timestamp: 2026-10-19T16:06:04.214179+00:00
- actor: claude-code
  id: 01m5aem0t5zwwqcezh2a3zhwhr
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — removing withRetryOnSpawnContention still gives `.timeout(30.0 seconds)` in requestReceivesItsScriptedTypedResponse under load (2 of 23 concurrent full runs, both at suite start; the server cold-starts in 1.7–1.9 s, so the reply is lost). ^t71wvkm's fix is not the only cause.
    - The ConnectionTests.swift change was reverted so main keeps the retry until the remaining cause is found. Nothing was committed for this task.
    - needs: a diagnostic card. On timeout, log whether the server is alive, the end of its stderr, and whether it read the request. Then look for another fd reuse or double-close while many suites spawn at once.
  timestamp: 2026-10-19T16:06:24.837511+00:00
- actor: claude-code
  id: 01m5ankvbcqnqgp7x9y00mp6hr
  text: |-
    Second attempt, after ^tfbetg3 (314daae: PendingRequestTable.failAll no longer throws away a response that arrived before its request registered).

    Change (working tree, not committed): removed `withRetryOnSpawnContention`, its doc comment, and the long comment in the body of `requestReceivesItsScriptedTypedResponse()`. The test now calls `Self.withConnection(steps:markerFile:)` once. The `markerFile:` argument stays, so a timeout still records the attachment from `recordTimeoutState(of:markerFile:)`. A repo-wide grep finds no other reference to `withRetryOnSpawnContention`.

    Load proof (same method as the first attempt): built once with `swift build --build-tests`, then 4 rounds of 6 concurrent `swift test --skip-build --scratch-path <clone>`. Each clone was an APFS clone of `.build` (`cp -c -R`), and 40 `yes > /dev/null` ran the whole time. That is 24 full root runs. All 24 passed: "Test run with 1062 tests in 94 suites passed", exit 0. `requestReceivesItsScriptedTypedResponse()` passed in all 24, in 1.42 to 1.96 s. There were 0 `✘` lines and 0 `timeout(` lines in any log. Before the ^tfbetg3 fix, the same method gave 2 timeouts in 23 runs. Afterwards every `yes` was killed (`pgrep -x yes` = 0) and every clone was deleted. The script and logs are in the session scratchpad.

    Plain `swift test`: 1062 tests in 94 suites passed. `swift test --package-path IntegrationTests`: 22 tests in 16 suites passed. The only warning was the allowed mlx-swift "missing creator for mutated node" (^3a92r6p).

    Rule check: I read the swift and test-integrity sections of the rules dump in full. The full dump (about 750K characters) was too large to read in one pass. This change only deletes code, and it removes the "retry logic added to hide a flaky test" that test-integrity flags.
  timestamp: 2026-10-19T18:08:39.276132+00:00
- actor: claude-code
  id: 01m5anky60088v7kev9j9zhtpa
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsCodeContextTests/ConnectionTests.swift (removed `withRetryOnSpawnContention`, its doc comment and the test-body comment; the test calls `withConnection(steps:markerFile:)` once). Load: 24 concurrent root runs (4 rounds of 6, APFS clones, 40 `yes`), 24/24 passed, 0 timeouts of requestReceivesItsScriptedTypedResponse. `swift test`: 1062/1062 in 94 suites passed. IntegrationTests: 22/22 in 16 suites passed. Only the allowed mlx warning.
    - next: /review
  timestamp: 2026-10-19T18:08:42.176513+00:00
- actor: claude-code
  id: 01m5anrtram8z4vqb4g2evxsks
  text: |-
    ### test — green
    - evidence: swift build complete, only the allowed mlx-swift_Cmlx "missing creator for mutated node" warning; swift test — 1062 tests in 94 suites passed, 0 failed, 0 skipped; swift test --package-path IntegrationTests — 22 tests in 16 suites passed, 0 skipped, 0 warnings; swift format lint --strict --recursive Sources Tests IntegrationTests/Tests — no output, clean
    - next: review
  timestamp: 2026-10-19T18:11:22.506215+00:00
- actor: claude-code
  id: 01m5anv1x2aa4p6g3k1hc1yj1c
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (2efb94c) — 0 findings, 0 confirmed, 0 refuted; 7 validator pairs attempted, 0 failed; 1 file reviewed (ConnectionTests.swift), 4 .kanban files excluded by .reviewignore
    - next: task moved to done
  timestamp: 2026-10-19T18:12:35.362185+00:00
- actor: claude-code
  id: 01m5anvdn768w5by7jqqa92p40
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (retry wrapper removed); load: 24/24 concurrent runs passed, 0 timeouts
    - test: green — swift test 1062 passed; IntegrationTests 22 passed; lint clean
    - commit: 2efb94c
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-19T18:12:47.399360+00:00
depends_on:
- 01M5A5ACEVQWJ9PC8GXT71WVKM
- 01M5AJHWKFWBSV0SK09TFBETG3
position_column: done
position_ordinal: ff8480
title: 'ConnectionTests: remove withRetryOnSpawnContention now that the descriptor-reuse cause is fixed'
---
## What
`Tests/FoundationModelsCodeContextTests/ConnectionTests.swift` wraps `requestReceivesItsScriptedTypedResponse()` in `withRetryOnSpawnContention`, a retry on `CodeContextError.timeout` added for the flake of 01KWVSJAR801YR97D051YDWPR5 ("occasionally the response never arrives on this attempt"). The test-integrity rule forbids "retry logic added to hide a flaky test".

^t71wvkm found the cause of "the response never arrives": `ProcessLanguageServerConnection.close()` closed the stdout/stderr read ends while the dedicated read loops still read those descriptors by number, and Darwin reuses a freed number at once, so a stale loop read the stdout pipe of the next connection and swallowed its response. ^t71wvkm makes each read loop own its read end (`ProcessUtilities.runReadLoop(name:readEnd:_:)`).

## Change
- Remove `withRetryOnSpawnContention` and its long comment; call `withConnection` once.
- Prove it under load: run `swift test` (root) concurrently several times with CPU load (e.g. 40 `yes > /dev/null`) and confirm no `.timeout` in the test.

Depends on ^t71wvkm landing. #test-flake