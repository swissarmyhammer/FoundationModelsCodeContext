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
depends_on:
- 01M5A5ACEVQWJ9PC8GXT71WVKM
- 01M5AJHWKFWBSV0SK09TFBETG3
position_column: doing
position_ordinal: '8180'
title: 'ConnectionTests: remove withRetryOnSpawnContention now that the descriptor-reuse cause is fixed'
---
## What
`Tests/FoundationModelsCodeContextTests/ConnectionTests.swift` wraps `requestReceivesItsScriptedTypedResponse()` in `withRetryOnSpawnContention`, a retry on `CodeContextError.timeout` added for the flake of 01KWVSJAR801YR97D051YDWPR5 ("occasionally the response never arrives on this attempt"). The test-integrity rule forbids "retry logic added to hide a flaky test".

^t71wvkm found the cause of "the response never arrives": `ProcessLanguageServerConnection.close()` closed the stdout/stderr read ends while the dedicated read loops still read those descriptors by number, and Darwin reuses a freed number at once, so a stale loop read the stdout pipe of the next connection and swallowed its response. ^t71wvkm makes each read loop own its read end (`ProcessUtilities.runReadLoop(name:readEnd:_:)`).

## Change
- Remove `withRetryOnSpawnContention` and its long comment; call `withConnection` once.
- Prove it under load: run `swift test` (root) concurrently several times with CPU load (e.g. 40 `yes > /dev/null`) and confirm no `.timeout` in the test.

Depends on ^t71wvkm landing. #test-flake