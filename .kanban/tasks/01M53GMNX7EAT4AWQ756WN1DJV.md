---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
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
- [ ] Each server request gets a reply.
- [ ] Server requests are never taken as responses.
- [ ] The tests above pass.

#lsp-fix