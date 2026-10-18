---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m573kcdp98rgztyrd2hxzfjs
  text: |-
    Research:
    - PendingRequestTable (in ProcessLanguageServerConnection.swift) keys by Int. resolveOrBuffer buffers each reply with no waiting continuation. Thus three replies stay in earlyResponses for ever: a late reply after a timeout, a reply for an id that the client never sent, and a second reply for the same id.
    - resolve(id:with:) has one caller: failAfterTimeout. It also has one unit test.
    - All writes to stdin go through the actor (requests, notifications, and the replies of replyTask). Thus the cancel notification goes through notify() on the actor, after awaitResponse throws the timeout.
    - The scripted server has no step key that asserts params. Plan: add the key "expectParams".
    Plan: the table keeps a set of awaited ids (sent, no reply yet). It buffers only the replies for these ids. It keeps a bounded set of timed-out ids, and drops a late reply for one of these ids. resolveOrBuffer returns a disposition, and route() writes a debug record for each dropped reply.
  timestamp: 2026-10-18T08:56:06.326319+00:00
- actor: claude-code
  id: 01m574jstcj8b6hjb77hx18629
  text: |-
    Implementation landed:
    - PendingRequestTable: new `expectResponse(id:)` (before the write) and `abandon(id:)` (write failed). `resolve(id:with:)` is now `timeOut(id:with:)`: it fails the continuation and records the id in `timedOutIDs` (at most `timedOutIDLimit` = 1024 ids, the oldest id goes first). `resolveOrBuffer` now returns `ResponseDisposition` (delivered, buffered, droppedLate, droppedUnknown). It buffers only a reply for an awaited id. A late reply removes its id from `timedOutIDs` and is dropped. A reply for an id that was never sent, and a second reply for one id, are dropped. `failAll` also clears the two id sets.
    - ProcessLanguageServerConnection: `sendRequest` catches `CodeContextError.timeout`, sends `$/cancelRequest` `{ "id": <id> }` through `notify` on the actor (thus in serial order with the writes of `replyTask`), and throws the timeout again. `route()` writes one `.debug` record for each dropped reply. `writeReply` and the cancel path share `logRequestEvent`.
    - Wire.swift: new `CancelParams { id: JSONRPCID }`.
    - scripted-lsp-server.swift: new read key `expectParams`.
    - Discovery (not fixed, out of scope): when the timeout fires before `register` runs, `timeOut` returns false and `awaitResponse` throws `CancellationError`, and the task group then waits for the response. Only a starved scheduler can cause this.
    RED: the new ConnectionTests test failed with `.notRunning` (no cancel was sent, the script stopped). The table tests failed to compile (no API).
  timestamp: 2026-10-18T09:13:15.852079+00:00
- actor: claude-code
  id: 01m574jx0vg5eyksrx1m9pwkny
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift, Sources/FoundationModelsCodeContext/LSP/Wire.swift, Sources/FoundationModelsCodeContext/LSP/ResumeOnce.swift (doc), Tests/FoundationModelsCodeContextTests/PendingRequestTableTests.swift, Tests/FoundationModelsCodeContextTests/ConnectionTests.swift, Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift. `swift test --filter PendingRequestTableTests` 10/10 pass; `swift test --filter ConnectionTests` 25/25 pass; full `swift test` 967 tests in 85 suites pass. `swiftlint lint --quiet --only-rule no_magic_numbers` on the changed files: no findings. `swift format lint`: no findings.
    - next: review
  timestamp: 2026-10-18T09:13:19.131121+00:00
- actor: claude-code
  id: 01m574vrfbz5hrh4cq16tny5vs
  text: |-
    ### test — green
    - evidence: swift test — 967 tests in 85 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete, exit 0. Only warning is a build-system "missing creator for mutated node" note for the mlx-swift_Cmlx bundle (dependency, not this package).
    - next: commit
  timestamp: 2026-10-18T09:18:09.387514+00:00
- actor: claude-code
  id: 01m5755ccn93d3z8g48b0bs1a3
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (16a60d6). 1 finding (1 confirmed, 0 refuted): Tests/FoundationModelsCodeContextTests/ConnectionTests.swift:377 `test-integrity/test-partitioning`.
    - acceptance criteria: the diff sends `$/cancelRequest` on timeout, and `PendingRequestTable` drops late replies with a bounded set of timed-out ids. Tests for the two behaviors are in the diff.
    - next: implement the open item in "Review Findings (2026-10-18 04:18)". The task stays in review.
  timestamp: 2026-10-18T09:23:24.693871+00:00
- actor: claude-code
  id: 01m5755rdsb19v5qgp9kxkjevh
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files
    - test: green — swift test, 967 passed
    - commit: 16a60d6
    - review: findings — Tests/FoundationModelsCodeContextTests/ConnectionTests.swift:377
  timestamp: 2026-10-18T09:23:37.017321+00:00
- actor: claude-code
  id: 01m5762wgb0z2fwpee0espfvjz
  text: |-
    Review finding test-partitioning (ConnectionTests.swift `aTimedOutRequestSendsCancelRequestWithItsID`):
    - Decision: option (a), move the test to the integration package. ProcessLanguageServerConnection makes its Process and its stdin and stdout pipes in `init`, and `writeToStdin` writes to that pipe. No small seam lets the cancel write go to an in-process writer. A seam needs a change to the init and to the process ownership of the actor. That is a refactor of production code, and it is not in the scope of this finding.
    - Moved test: IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LSPCancelRequestTests.swift. It uses `ScriptedLSPServer.withConnection` and hover requests (thus no copy of `documentSymbolJSON`). The integration helper has no clock parameter, and the integration package has no ManualClock. Thus the test uses the real clock and the request timeout of `ScriptedLSPServer` (10 s). The test takes approx. 10 s.
    - Removed from ConnectionTests: the test and its constant `cancelTestRequestTimeout`.
    - Fail check: with the `cancelOnServer(id:)` call removed for a short time, the moved test failed with `.notRunning`. The call is back (git checkout of the source file).
    - Scope: the older scripted-process tests in ConnectionTests stay in the unit target. They existed before this task, and the review rules drop findings that ask to refactor tests that already existed.
  timestamp: 2026-10-18T09:39:31.467146+00:00
- actor: claude-code
  id: 01m5762zb32ekkrgz59t2g1ns1
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsCodeContextTests/ConnectionTests.swift (test removed), IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LSPCancelRequestTests.swift (new). `swift test --package-path IntegrationTests --filter LSPCancelRequestTests` 1/1 pass; `swift test --filter "ConnectionTests|PendingRequestTableTests"` 34/34 pass; full `swift test` 966 tests in 85 suites pass. `swiftlint lint --only-rule no_magic_numbers` on the 2 files: no findings. `swift format lint`: no findings. Finding in "Review Findings (2026-10-18 04:18)" is checked.
    - next: review
  timestamp: 2026-10-18T09:39:34.371739+00:00
- actor: claude-code
  id: 01m576g2y73b7bcm15jvw6jxvn
  text: |-
    ### test — green
    - evidence: swift test (root) 966 tests in 85 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests complete; swift test --package-path IntegrationTests --filter LSPCancelRequestTests 1 test in 1 suite passed. Only warning is the build-system note "missing creator for mutated node" for the mlx-swift_Cmlx bundle. It comes from the mlx-swift dependency, not from this package.
    - next: commit
  timestamp: 2026-10-18T09:46:44.039316+00:00
- actor: claude-code
  id: 01m576r3syettcxy8qkxhhnrx8
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (2aaf7e4): 0 findings, 0 confirmed, 0 refuted (7 attempted, 0 failed). The prior finding is checked. The test aTimedOutRequestSendsCancelRequestWithItsID is now in IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LSPCancelRequestTests.swift. It is not in the unit target.
    - next: none. The task is in done.
  timestamp: 2026-10-18T09:51:07.070575+00:00
- actor: claude-code
  id: 01m576rde6p413g2sjnh9knz7p
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 files (cancel test moved to the integration package)
    - test: green — swift test, 966 passed; integration LSPCancelRequestTests 1 passed
    - commit: 2aaf7e4
    - review: clean — 0 findings; 1 of 1 prior item checked
  timestamp: 2026-10-18T09:51:16.934534+00:00
position_column: done
position_ordinal: eb80
title: Send $/cancelRequest on a request timeout and drop late replies
---
## Problem
- `failAfterTimeout` (`Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift:753-761`) fails the request but sends nothing to the server. The server continues to do the work.
- A reply that comes after the timeout goes to `resolveOrBuffer`. No continuation waits for it, so it stays in `earlyResponses` (`:95-104`) forever. Ids are not used again, so this is a memory leak.

## Change
- On timeout, send the notification `$/cancelRequest` with `{ "id": <id> }`.
- Keep a set of timed-out ids. When a reply for one of these ids comes, drop it and remove the id from the set.

## Tests
- On a timeout, the fake server gets `$/cancelRequest` with the correct id.
- A reply that comes after the timeout is not kept in `earlyResponses`.

## Acceptance criteria
- [x] `$/cancelRequest` is sent on each timeout.
- [x] Late replies do not stay in memory.
- [x] The tests above pass.

#lsp-fix

## Review Findings (2026-10-18 04:18)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsCodeContextTests/ConnectionTests.swift:377` `test-integrity/test-partitioning` — The new test `aTimedOutRequestSendsCancelRequestWithItsID` is in the unit test target and starts a real child process (the `swift` interpreter running `scripted-lsp-server.swift`). This is an integration test in the unit target. The unit target must hold only fast tests that need no external system. The test also adds to the cost of every default local run and every TDD cycle. Move the scripted-process connection tests, including this one, to the integration package (`IntegrationTests/`) or to a dedicated integration target. Run it with `swift test --package-path IntegrationTests`, and make sure CI runs that target. If the file must stay in the unit target, replace the spawned process with an in-process fake connection that drives `route(message:serverName:sinks:)` and `PendingRequestTable` directly, and check the `$/cancelRequest` write through a seam that does not start a process.
