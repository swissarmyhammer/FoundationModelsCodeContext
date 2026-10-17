---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
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
- [ ] `$/cancelRequest` is sent on each timeout.
- [ ] Late replies do not stay in memory.
- [ ] The tests above pass.

#lsp-fix