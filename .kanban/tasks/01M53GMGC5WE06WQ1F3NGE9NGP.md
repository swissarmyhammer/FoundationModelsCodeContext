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
position_column: doing
position_ordinal: '80'
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