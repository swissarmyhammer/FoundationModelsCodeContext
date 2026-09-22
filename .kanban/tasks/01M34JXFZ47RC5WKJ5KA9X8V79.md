---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: workspaceSymbols and implementations give an empty result when the server does not have the method
---
Source: a question from foundationmodelsacpagent-08 on 2026-09-22, after ^0ykcm6j.

## What happens

After ^0ykcm6j, `LspSession` does not send `workspace/symbol` or `textDocument/implementation` to a server that does not advertise them. It throws `LspSessionError.notAdvertised`. But the ops hide this error:

- `LiveOpsExtended.workspaceSymbols` (Ops/LiveOpsExtended.swift:491-500) catches every error and gives `WorkspaceSymbolsResult(symbols: [])`. It also uses `supervisor.anySession()`, so the answer comes from any running server, not a server of a known language.
- `LiveOpsCore.liveImplementations` (Ops/LiveOpsCore.swift:681-685) catches every error and gives `nil`. The cascade then goes to the index layer. When the index has nothing, the result is `ImplementationsResult(implementations: [], sourceLayer: .none)`.

Thus for pylsp an empty answer can mean "no results" or "this server does not have the method". A caller (and a model that uses the tools) cannot tell the difference. FoundationModelsACPAgent must tell the models which of the two it is.

## Proposed change

1. Add a field to `WorkspaceSymbolsResult` and `ImplementationsResult` (for example `unsupported: [String]`, the server commands that do not advertise the method, or one `notSupportedReason: String?`). Set it when a session throws `LspSessionError.notAdvertised`.
2. `workspaceSymbols`: ask each running session that advertises `workspaceSymbolProvider`, not one `anySession()`. When no running session advertises it, set the field.
3. `implementations`: keep the cascade to the index layers, but when the live layer failed with `notAdvertised`, keep that fact in the result.
4. The tool output (the `code_navigation` / `code_search` tools) must show this as text, for example "the language server for this file does not support implementations".
5. Do not change the result for other errors (timeouts, a server that is not running).

## Acceptance

- [ ] With a fake server that does not advertise `workspaceSymbolProvider`, `workspaceSymbols` gives an empty list AND a field that says the server does not support it.
- [ ] With a fake server that does not advertise `implementationProvider`, `implementations` gives the same kind of answer.
- [ ] With a server that advertises the method and has no match, the result is empty and the field is not set.
- [ ] The tool text shows "not supported" differently from "no results".
- [ ] docs/language-servers.md tells which result a caller gets in each case.