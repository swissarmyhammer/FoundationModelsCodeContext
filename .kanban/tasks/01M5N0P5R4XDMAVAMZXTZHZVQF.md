---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5n1apgbvrar05bvtyqbf1sz
  text: |-
    ### test — green
    - evidence: red on old code: `stoppingTheIndexTaskDuringAReferencesRequestSendsNoMoreRequests` (worker sent all 10 references after the cancel), `aCancelledRequestEndsAtOnceAndSendsCancelRequestWithItsID` (cancelled request still waiting after 10 s). Green after fix: `swift test` 1078/1078, `swift test --package-path IntegrationTests` 22/22, only the allowed mlx warning.
    - fix: `sendRequest` checks cancellation before the write; `awaitRegisteredResponse` resolves the pending id on cancel through new `PendingRequestTable.cancel(id:)` (handles cancel before register; late reply dropped) and sends `$/cancelRequest`; worker loops stop on cancel, a stopped file writes nothing and is not counted as a failure.
    - next: commit, push, sha to the acp-agent bench session.
  timestamp: 2026-10-23T18:45:46.635469+00:00
position_column: done
position_ordinal: ff8880
title: Stop of code context waits minutes on an LSP index task that keeps sending requests after the cancel
---
## What happened
SWE-bench run bench24-1023 (FoundationModelsACPAgent, 2026-10-23), instance 3 (django__django-13925): after the ACP session closed, the LSP servers shut down 322 s later (13 s and 8 s for the instances before). In that window: 571 lsp requests on the wire (~1.8/s), 566 debug records "the LSP index task stops before the index of a file is complete; the file stays dirty for the next pass", pylsp at 96 % CPU. Evidence: FoundationModelsACPAgent/bench/preds.bench24-1023.telemetry.jsonl, ts 18:20:50Z..18:26:20Z.

## Cause
`CodeContext.stop()` cancels each LSP index task and awaits it. Two things keep the cancelled task alive:
1. `ProcessLanguageServerConnection.awaitResponse(id:)` — on cancel, the timeout branch throws at once, but the task group still waits for the response child, a continuation that only the server's reply resolves. A cancelled request thus waits for pylsp's full (slow) answer. And `sendRequest` writes new requests in a cancelled task.
2. `LSPIndexWorker` per-symbol loops (references fallback, call-site `definition` targets, call hierarchy) never check cancellation, so after the cancel the worker sends one request for each symbol and call site of the file, each one waiting for the reply (1). The debug record is written once per request.

The file staying dirty is correct (it was not indexed); `run` exits after the batch, so no new pass starts. The fix is to make the cancel prompt.

## Fix
- [ ] Failing test: cancelling `LSPIndexWorker.run` during a references request sends no more requests and ends promptly (`LSPIndexWorkerReferencesTests`).
- [ ] Failing test: a cancelled, unanswered request on a real connection ends at once, sends `$/cancelRequest` with its id, and a late reply does not answer the next request (`ConnectionTests`).
- [ ] Connection: no write in a cancelled task; on cancel resolve the pending id with `CancellationError` (table drops a late reply) and send `$/cancelRequest`.
- [ ] Worker: stop each per-symbol / per-call-site loop when the task is cancelled; a stopped file is not counted as a failure.

#bug