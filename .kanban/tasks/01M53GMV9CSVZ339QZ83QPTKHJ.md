---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m570z91hz3bqhp5rbqtk9qtn
  text: |-
    Research:
    - `LanguageServerConnection` is a public protocol with `initialize(rootURI:)`. A change of that signature breaks public API and each fake. Thus the options go to `ProcessLanguageServerConnection.init` (new parameter `initializationOptions`, default nil). `LSPDaemon.processConnectionFactory()` gives `spec.initializationOptions` to it.
    - `LSPDaemon.spawnSpec(for:location:)` makes a copy of the spec with all fields. It must also copy `initializationOptions`, or a server found in an extra search directory loses its options.
    - `JSONValue` (Wire.swift) is internal. A public `ServerSpec` field cannot use an internal type, thus `JSONValue` becomes public.
    - No language module has initialization options now (no `initializationOptions` text in Sources). Only the field is added; no module gets a value.
    - The client does not process `client/registerCapability` (it only answers null), thus each capability sends `dynamicRegistration: false`.
    - The client decodes `CodeAction` objects and uses `codeAction/resolve` and `prepareRename`, thus the capabilities declare `codeActionLiteralSupport`, `dataSupport`, `resolveSupport` and `prepareSupport`.
  timestamp: 2026-10-18T08:10:10.353737+00:00
- actor: claude-code
  id: 01m571r67exxtj3fsweqxykgzy
  text: |-
    ### implement — changed
    - evidence: Sources: LSP/Wire.swift (InitializeParams with initializationOptions, ClientCapabilities, WorkspaceFolder; JSONValue is now public), Languages/ServerSpec.swift (initializationOptions with default nil; the 30 s and 60 s defaults are now named constants because swiftlint no_magic_numbers flagged them), LSP/LSPDaemon.swift (spawnSpec copies the options; processConnectionFactory gives them to the connection), LSP/ProcessLanguageServerConnection.swift (init parameter initializationOptions, sent by initialize). Tests: WireTests (6 new tests), LSPDaemonTests (extra-search-directory copy keeps the options), ConnectionTests (2 new end-to-end tests through processConnectionFactory), Support/scripted-lsp-server.swift (new read key expectInitializationOptions). plan.md handshake line updated.
    - RED: `swift build --build-tests` failed with "extra argument 'initializationOptions' in call". GREEN: `swift test` 961 tests in 85 suites passed; `swift build --package-path IntegrationTests --build-tests` complete; `swiftlint lint --quiet --only-rule no_magic_numbers` on the changed files gives no violation.
    - Note: no language module in Sources sets initialization options; only the field is wired.
    - next: /review
  timestamp: 2026-10-18T08:23:46.670348+00:00
- actor: claude-code
  id: 01m572235ebsg1bdk6rq1hac62
  text: |-
    ### test — green
    - evidence: swift test: 961 tests in 85 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests: Build complete. Only warning: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle (dependency build artifact, not this package).
    - next: commit
  timestamp: 2026-10-18T08:29:11.214568+00:00
depends_on:
- 01M53GMNX7EAT4AWQ756WN1DJV
position_column: doing
position_ordinal: '80'
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
- [x] `initialize` sends real capabilities and the configured options.
- [x] The tests above pass.

#lsp-fix