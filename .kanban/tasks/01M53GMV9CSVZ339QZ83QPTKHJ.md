---
assignees:
- claude-code
depends_on:
- 01M53GMNX7EAT4AWQ756WN1DJV
position_column: todo
position_ordinal: '8880'
title: Send real client capabilities and the configured initializationOptions in initialize
---
## Problem
`InitializeParams` (`Sources/FoundationModelsCodeContext/LSP/Wire.swift:233-243`) always sends `capabilities = EmptyPayload()` and has no `initializationOptions` field. `ServerSpec` (`Languages/ServerSpec.swift:10-38`) has no field for these options. Thus the client does not tell the server that it supports pull diagnostics, `publishDiagnostics`, hierarchical document symbols, call hierarchy or workspace folders. Some servers then send less data or a different format.

## Change
- Add an optional `initializationOptions` (JSON value) to `ServerSpec`, and send it in `initialize`.
- Send client capabilities for the features that the code uses: `textDocument.synchronization` (with `didSave`), `textDocument.publishDiagnostics`, `textDocument.diagnostic`, `textDocument.documentSymbol.hierarchicalDocumentSymbolSupport = true`, `textDocument.callHierarchy`, `textDocument.references`, `textDocument.definition`, `textDocument.hover`, `textDocument.rename`, `textDocument.codeAction`, `workspace.workspaceFolders = true`, `workspace.configuration = true`, `window.workDoneProgress = true`.
- Send `workspaceFolders` with the root.
- Declare only capabilities that the client handles. `workspace.configuration` and `workDoneProgress` need the task "Answer server-to-client LSP requests and accept string ids" to be done first.

## Tests
- The encoded `initialize` request has the capabilities above.
- A `ServerSpec` with `initializationOptions` sends them. A spec with no options sends no `initializationOptions` field (or `null`).

## Acceptance criteria
- [ ] `initialize` sends real capabilities and the configured options.
- [ ] The tests above pass.

#lsp-fix