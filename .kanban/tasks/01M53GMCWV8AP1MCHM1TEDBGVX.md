---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Close LSP documents on all paths and limit the number of open documents
---
## Problem
- `LSPIndexWorker.processFile` closes the document on success (`Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift:365`, `closeDocument` at `:429-435`). But when `documentSymbols` throws, it returns at `:342-344` and does not close the document.
- Live ops (`Ops/LiveOpsCore.swift:847-849`) and diagnostics (`Diagnostics/Diagnose.swift:145-149`) call `syncOpen` and never close.
- `LspSession.docs` (`LSP/LspSession.swift:155`) has no size limit. Each open document makes the server do work on each change.

## Change
- In `processFile`, close the document with a `defer` after a good `syncOpen`.
- Add an LRU limit to `LspSession` (for example 50 open documents). When the limit is passed, send `didClose` for the oldest document that no op uses now.
- Make the limit injectable for tests.
- Give each open document an owner: tool or indexer. A `syncOpen` from a live op or from diagnostics sets the owner to tool, and the owner stays tool. Now the worker always closes the document (`LSPIndexWorker.swift:365`, then `LspSession.swift:616-617`), also when a live op opened it and uses it now. The worker must close only the documents that it owns, on all paths: success, failed `syncOpen`, failed `documentSymbols`, failed call hierarchy and failed store write.
- Check-then-act race: `syncOpen` (`LspSession.swift:270-280`) reads `docs`, waits for the send, and then writes `docs`. This is actor reentrancy. Two calls at the same time can send two `didOpen` messages or the same version two times, and a `didClose` between the steps can make `syncOpen` skip a reopen. Update `docs` before the `await`, or put the open and close of each URI in sequence.
- At the limit, close the least recently used document first. If that `didClose` fails, the open must fail, so the count never goes above the limit. (This is the Rust design: `MAX_OPEN_DOCUMENTS = 50`.)

## Tests
- When `documentSymbols` throws, the fake connection gets `didClose` for that document.
- After N+1 live-op opens with a limit of N, the oldest document gets `didClose`, and the session has N open documents.
- A document that an op uses now is not closed.
- A live op opens a document, then the worker indexes the same file: the worker does not send `didClose` for it.
- Two `syncOpen` calls at the same time for one URI send one `didOpen` only.

## Acceptance criteria
- [ ] No document leak on the failure path.
- [ ] The number of open documents stays at the limit or less.
- [ ] The tests above pass.

#lsp-fix