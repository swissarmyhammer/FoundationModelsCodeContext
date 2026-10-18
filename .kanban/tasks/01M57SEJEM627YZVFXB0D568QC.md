---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57srd7hw0z887vwjkpefxee
  text: |-
    Research and evidence. The orphan came from a test run that crashed. The current code does not leave an orphan.
    - The orphan: pid 98867, ppid 1, pgid 98867, started Sun Oct 18 00:28:06 2026 (CDT). Its command line was `swift-frontend -frontend -interpret .../Support/scripted-lsp-server.swift ... -- [{"action":"read"},{"text":"Content-Length: -5\r\n\r\n","action":"writeRaw"},{"action":"hang"}]`. This is a process of this test suite, thus I killed it with SIGTERM. It stopped.
    - Time line: the ^s4fmb5k research comment is at 00:25:45 CDT (05:25:45 UTC). The orphan started at 00:28:06 CDT. The ^s4fmb5k fix commit 7f351ac is at 00:56:51 CDT. The process-group commit fc2d112 (^pv4r1ch) is at 07:42:21 CDT. Thus the orphan started before the fix and before the process-group change.
    - The ^s4fmb5k comment records the RED run of this test: "RED was a process crash: Fatal error: Range requires lowerBound <= upperBound". The old decoder trapped on `Content-Length: -5`. The crash stopped the test binary before `withConnection` called `close()`. The script was at its `hang` step, which sleeps for ever and does not read stdin. Thus no step stopped the server, and launchd (pid 1) became its parent.
    - The current code: `ProcessGroupChild` starts the server as the leader of a new group. The reader loop sends SIGKILL to the group at a bad header (`closeOutOfStepConnection`). `close()` sends SIGTERM, then SIGKILL, to the group and waits for the reap. `deinit` sends SIGKILL to the group.
    - Check 1: `swift test --skip-build --filter 'ConnectionTests/aNegativeContentLengthFailsThePendingRequestAndStopsTheServer'` ran 10 times, one run at a time. Each run: 1 test passed. Before the first run and after each run: 0 `swift-frontend ... scripted-lsp-server` processes.
    - Check 2: one full root `swift test`: 1015 tests in 90 suites passed, exit 0. Before the run: 0 processes. After the run: 0 processes. The only warning is the known `missing creator for mutated node` for the mlx-swift_Cmlx bundle (^kw00hcn).
    - No code change. A new test is not necessary: the ^vqpcb1t and ^pv4r1ch tests already prove with `processExists(pid)` that `close()` reaps the server and that no process of the group stays (ConnectionTests `aRequestTimeoutThatPropagatesUncaughtStillClosesTheConnectionAndReapsTheProcess`, IntegrationTests `LanguageServerProcessGroupTests`).
    - Gap that stays: when the test binary crashes, no code of the connection runs, and a script at a `hang` step stays alive. I added a follow-up task for this.
  timestamp: 2026-10-18T15:23:19.665053+00:00
- actor: claude-code
  id: 01m57srwr6c064ac09d91edfsz
  text: |-
    ### implement — no-change
    - evidence: no files changed. The orphan (pid 98867, started 00:28:06 CDT) came from the crashed RED run of ^s4fmb5k, before fix 7f351ac and before process-group commit fc2d112. I killed it. `swift test --skip-build --filter 'ConnectionTests/aNegativeContentLengthFailsThePendingRequestAndStopsTheServer'` x10: 10 of 10 passed, 0 orphans after each run. Full `swift test`: 1015 tests in 90 suites passed, exit 0, 0 `scripted-lsp-server` processes before and after. Only warning: the known mlx-swift_Cmlx `missing creator for mutated node` (^kw00hcn). Acceptance criterion checked. Follow-up task ^qma01sw: the `hang` step must stop at the end of stdin, so that a crashed test binary leaves no orphan.
    - next: /review
  timestamp: 2026-10-18T15:23:35.558294+00:00
- actor: claude-code
  id: 01m57sssdx6xc20z2y3nrs0he5
  text: |-
    ### commit — changed
    - evidence: 481df88 chore(kanban): record the cause of the orphan test server ^0d568qc (6 files)
    - next: none. This comment is written after the commit, so the board file for this task shows one new change that is not committed.
  timestamp: 2026-10-18T15:24:04.925784+00:00
- actor: claude-code
  id: 01m57sv8wav47daqqpmgpw8m1f
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 481df88): findings 0, confirmed 0, refuted 0. 0 files reviewed. 6 of 6 files are `.kanban/` files, and `.reviewignore` excludes them. Acceptance criterion check: the research comment records that the orphan (pid 98867, started 00:28:06 CDT) came from the crashed RED run of ^s4fmb5k. `git log` agrees: fix 7f351ac is at 00:56:51 and process-group commit fc2d112 is at 07:42:21, both after the orphan started. The comment records one full `swift test` run (1015 tests, exit 0) with 0 `scripted-lsp-server` processes after the run. `pgrep -fl scripted-lsp-server` now shows 0 processes. Follow-up task ^qma01sw is in todo.
    - next: none. Task moved to done.
  timestamp: 2026-10-18T15:24:53.514234+00:00
- actor: claude-code
  id: 01m57svk04h8tz0vaczftvjq3b
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — orphan came from the crashed RED run of ^s4fmb5k; current code leaves no orphan (10 repeated runs, 1 full run, 0 orphans)
    - test: skipped — no code change; implement ran swift test, 1015 passed
    - commit: 481df88 (kanban records only)
    - review: clean — 0 findings; acceptance criterion met by the recorded evidence
  timestamp: 2026-10-18T15:25:03.876772+00:00
position_column: done
position_ordinal: f780
title: An orphan scripted-lsp-server process of the negative Content-Length test stays alive after a test run
---
## Problem
During ^kw00hcn, `pgrep` showed one `swift-frontend -frontend -interpret .../Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` process with PPID 1. Its age was 9 h 44 min. Its script argument was `[{"action":"read"},{"text":"Content-Length: -5\r\n\r\n","action":"writeRaw"},{"action":"hang"}]`. This is the script of `ConnectionTests.aNegativeContentLengthFailsThePendingRequestAndStopsTheServer`.

The test expects `isRunning()` to become `false`. But the `swift-frontend` child of `/usr/bin/env swift` stayed alive after the test run, with no parent.

The cause is not known. Possible causes: the test run was stopped before the cleanup; or the stop of the connection kills the `swift` driver process and not the `swift-frontend` child.

## Change
- Find if a full `swift test` run can leave this process alive. Count the `scripted-lsp-server.swift` processes before and after one run.
- If the run leaves the process, make the stop of the connection kill the full process tree or process group of the server.

## Acceptance criteria
- [x] After one full `swift test` run, no `scripted-lsp-server.swift` process stays alive, or the task records that the process came from a stopped run. #bug