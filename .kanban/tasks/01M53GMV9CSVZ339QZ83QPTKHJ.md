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
- actor: claude-code
  id: 01m572aykktj1hrv27hqktvfnd
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (b708579). 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsCodeContextTests/WireTests.swift:373 (reuse/reuse).
    - acceptance: the change sends real client capabilities, workspaceFolders and the configured initializationOptions. The new tests examine these items. The acceptance criteria are satisfied.
    - next: Use one shared encodedObject test helper (it must return NSDictionary). Then do the review again. The task stays in review.
  timestamp: 2026-10-18T08:34:01.459701+00:00
- actor: claude-code
  id: 01m572b89h3yc3v38znep6f837
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files
    - test: green — swift test, 961 passed
    - commit: b708579
    - review: findings — Tests/FoundationModelsCodeContextTests/WireTests.swift:373
  timestamp: 2026-10-18T08:34:11.377751+00:00
- actor: claude-code
  id: 01m572s0db0zpnxpd2w6p3vcng
  text: |-
    Fix of the reuse/reuse finding:
    - New shared helper `TestJSON.encodedObject(_:)` in Tests/FoundationModelsCodeContextTests/TestSupport.swift. It is generic over any Encodable and returns NSDictionary, thus `value(forKeyPath:)` works. TestSupport.swift now imports Testing for `#require`.
    - Removed `WireTests.encodedObject(of:)` and `ResultEncodingTests.encodedObject(_:)`. All call sites use the shared helper.
    - The same encode-then-JSONSerialization step was also in 8 more WireTests tests (request, notification, initialize, didOpen, didChange, didClose, rename, workspaceSymbol params) and in 2 CodeSearchToolTests schema tests. All now call the shared helper. A search of Tests and IntegrationTests finds no other `jsonObject(with:)` after an encode (scripted-lsp-server.swift parses wire input, not an encoded value).
    - ResultEncodingTests: NSDictionary has no `keys`, thus the top-level key checks use `json.allKeys.compactMap { $0 as? String }`.
    - Note: the files edit tool did not apply `replace_all`; it changed only one occurrence. Each site needed its own edit.
  timestamp: 2026-10-18T08:41:42.059270+00:00
- actor: claude-code
  id: 01m572s31h2b8n0s8s399tav1n
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsCodeContextTests/TestSupport.swift, WireTests.swift, ResultEncodingTests.swift, CodeSearchToolTests.swift. `swift test --filter "WireTests|ResultEncodingTests|CodeSearchToolTests"`: 113 tests in 3 suites passed. `swift test`: 961 tests in 85 suites passed, 0 failed. Only warning: the known mlx-swift_Cmlx.bundle "missing creator for mutated node" (dependency).
    - finding WireTests.swift:373 reuse/reuse is checked.
    - next: /review
  timestamp: 2026-10-18T08:41:44.753241+00:00
- actor: claude-code
  id: 01m5735jnkt6jyaj3fm5wh02n7
  text: |-
    ### test — green
    - evidence: swift test: 961 tests in 85 suites passed, 0 failures, 0 skipped; swift build --package-path IntegrationTests --build-tests: Build complete; forced recompile of all test files: 0 warnings from this package (only a SwiftPM "missing creator for mutated node" notice for the mlx-swift_Cmlx dependency bundle)
    - next: commit
  timestamp: 2026-10-18T08:48:33.971297+00:00
- actor: claude-code
  id: 01m573dk9fs8ba8hama04154ax
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6289269). 0 findings, 0 confirmed, 0 refuted. 4 files reviewed. The prior finding (WireTests.swift:373 reuse/reuse) is checked and fixed: one generic helper TestJSON.encodedObject in TestSupport.swift returns NSDictionary, and no other copy of encodedObject exists.
    - next: none. The task is in done.
  timestamp: 2026-10-18T08:52:56.751974+00:00
- actor: claude-code
  id: 01m573dwj7ef9xarhvxgp85djm
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 test files (one shared TestJSON.encodedObject helper)
    - test: green — swift test, 961 passed
    - commit: 6289269
    - review: clean — 0 findings; 1 of 1 prior item checked
  timestamp: 2026-10-18T08:53:06.247695+00:00
depends_on:
- 01M53GMNX7EAT4AWQ756WN1DJV
position_column: done
position_ordinal: ea80
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

## Review Findings (2026-10-18 03:29)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Tests/FoundationModelsCodeContextTests/WireTests.swift:373` `reuse/reuse` — The new private helper `encodedObject(of:)` repeats the encode-then-parse-to-JSON-object step that already exists as `ResultEncodingTests.encodedObject(_:)`. Two copies of the same capability can drift apart. The existing helper is also generic over any Encodable, while this one is fixed to `InitializeParams`. Move the generic helper to a shared test support file, or make the new helper a thin call to it. The return type must stay NSDictionary, not [String: Any], because the tests call `value(forKeyPath:)`, which only NSDictionary provides. Make the generic helper return NSDictionary, or keep this fork and note in a comment why the return type differs.
