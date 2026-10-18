---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m56z69yt543pf527gcp5e9fb
  text: |-
    Research:
    - `route` in ProcessLanguageServerConnection.swift runs on the reader thread (static, no actor). It has no access to stdin. A reply from the reader thread must not write stdin directly: the reader would block when the stdin pipe of the server is full, and the server can block on its full stdout pipe. That is a deadlock.
    - Plan: the reader loop puts each reply payload in an AsyncStream. A stored reply task on the actor reads the stream and writes each reply through `writeToStdin`, so that all writes stay serial on the actor. The reader closure finishes the stream when the loop stops; `close()` also finishes it and cancels the task.
    - Add `JSONRPCID` (number or string) in Wire.swift. `JSONRPCEnvelopePeek.id` and `JSONRPCResponseEnvelope.id` decode it. A string id that holds a decimal number matches the pending request with that number.
    - Add a route kind on the peek: response / server request / notification / unroutable.
    - Add a new file LSP/ServerRequestReply.swift that makes the reply payload: workspace/configuration -> array of null, one per item; client/registerCapability, client/unregisterCapability, window/workDoneProgress/create -> result null; other -> error -32601.
    - The scripted server gets a "request" action and "read" expectations `expectID`, `expectResult`, `expectErrorCode`.
    - The first client request id is 0, thus the collision test uses id 0 and asserts it on the first read.
  timestamp: 2026-10-18T07:39:03.514837+00:00
- actor: claude-code
  id: 01m570937d2sw2cg5g6p0fy7f0
  text: |-
    Implementation landed.
    - RED: before the fix, the collision test failed with `WireError.missingResult` (the client took the server request as the response). The string-id test and the unknown-method test failed with `.timeout(30 s)`, because the client dropped the string-id message and gave no reply.
    - Wire.swift: new `JSONRPCID` (number or string, encodes back in the same form, `requestNumber` reads "5" as 5). New `JSONRPCRoute` and `JSONRPCEnvelopePeek.route`. `JSONRPCResponseEnvelope.id` decodes `JSONRPCID`, thus a response with id "5" matches the pending request 5. `JSONRPCErrorPayload` is now `Codable`.
    - New LSP/ServerRequestReply.swift: makes the reply payload for each server request.
    - ProcessLanguageServerConnection.swift: `route` switches on the route. The reader loop puts each reply in an AsyncStream (`MessageSinks.replies`); `replyTask` writes each reply through the actor (`writeReply(_:)`). The task holds `self` weakly, one write at a time. `replyTask` is `nonisolated(unsafe)`, the same pattern as `LspSession.notificationConsumerTask`: a plain actor var cannot be assigned in the nonisolated init after the task captures `self` (compile error).
    - What did not work: `self.replyTask = Task { [weak self] in await self?.writeReplies(...) }` with a plain `var` does not compile. A loop inside one actor method also keeps the actor alive for the whole loop; the final form holds `self` only per write.
    - Lint: the no_magic_numbers gate also showed three old literals in touched files (`BoundedTailBuffer(maxChunks: 20)`, the default `.seconds(30)` request timeout, the 3600 s sleep of the scripted server). I named them as constants.
    - Scripted server DSL: new "request" action; "read" now takes `expectID`, `expectResult`, `expectErrorCode`.
    - The earlyResponses leak (^nge9ngp) is not changed.
  timestamp: 2026-10-18T07:58:03.501266+00:00
- actor: claude-code
  id: 01m57096q95zmgy87aytf4kr36
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift, Sources/FoundationModelsCodeContext/LSP/Wire.swift, Sources/FoundationModelsCodeContext/LSP/ServerRequestReply.swift (new), Tests/FoundationModelsCodeContextTests/ConnectionTests.swift, Tests/FoundationModelsCodeContextTests/WireTests.swift, Tests/FoundationModelsCodeContextTests/ServerRequestReplyTests.swift (new), Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift, Tests/FoundationModelsCodeContextTests/TestSupport.swift. `swift test --filter 'ConnectionTests|WireTests|ServerRequestReplyTests|PendingRequestTableTests|ContentSafety|LSPDaemonTests'`: 130 tests in 6 suites passed. Full `swift test`: 953 tests in 85 suites passed, 0 failures. `swiftlint lint --quiet --only-rule no_magic_numbers <changed files>`: clean.
    - next: /review
  timestamp: 2026-10-18T07:58:07.081679+00:00
- actor: claude-code
  id: 01m570hj53dbv9bjjzycjg8x2k
  text: |-
    ### test — green
    - evidence: swift test (root) - 953 tests in 85 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests - Build complete, 0 warnings from this package (only a third-party mlx-swift_Cmlx.bundle SwiftPM warning)
    - next: commit
  timestamp: 2026-10-18T08:02:40.931756+00:00
- actor: claude-code
  id: 01m570twwm8hfmm0qa44ynbmk0
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (7e5ce1e). 0 findings, 0 confirmed, 0 refuted. 14 validator runs, 0 failed. 8 files reviewed. 4 .kanban files are excluded by .reviewignore. Acceptance criteria: ConnectionTests has the three tests. They are aServerRequestWithThePendingIDGetsAReplyAndTheRequestGetsItsTrueResponse, aServerRequestWithAStringIDGetsAReplyWithTheSameStringID and anUnknownServerRequestGetsAMethodNotFoundError. The test step was green (953 tests passed).
    - next: none. The task moved to done.
  timestamp: 2026-10-18T08:07:46.836821+00:00
- actor: claude-code
  id: 01m570v80ta0nxrjkede2e43mk
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files
    - test: green — swift test, 953 passed
    - commit: 7e5ce1e
    - review: clean — 0 findings
  timestamp: 2026-10-18T08:07:58.234952+00:00
position_column: done
position_ordinal: e980
title: Answer server-to-client LSP requests and accept string ids
---
## Problem
- `route` (`Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift:848-851`) sends each message that has an `id` to `resolveOrBuffer`. It does not check for a `method` field.
- Thus server requests (`client/registerCapability`, `workspace/configuration`, `window/workDoneProgress/create`) never get an answer. Some servers wait for these answers.
- If the id of a server request is the same as the id of a pending request, the code takes it as the response to that request. If no request is pending with that id, the code keeps it and gives it to a later request.
- `JSONRPCEnvelopePeek.id` is `Int?` (`LSP/Wire.swift:219-222`). A message with a string id does not decode and is dropped.

## Change
- A message with `id` and `method` is a server request. Send a reply:
  - `workspace/configuration`: an array of `null`, one for each item.
  - `client/registerCapability`, `client/unregisterCapability`, `window/workDoneProgress/create`: result `null`.
  - Other methods: error `MethodNotFound` (-32601).
- A message with `id` and no `method` is a response.
- Decode `id` as an integer or a string.

## Tests
- The fake server sends `workspace/configuration` with id 1 while client request 1 is pending. The client replies to the server, and request 1 still gets its true response.
- A server request with a string id gets a reply with the same string id.
- An unknown server request gets a `MethodNotFound` error.

## Acceptance criteria
- [x] Each server request gets a reply.
- [x] Server requests are never taken as responses.
- [x] The tests above pass.

#lsp-fix