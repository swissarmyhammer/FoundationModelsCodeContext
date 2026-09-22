---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34ps14yxbeq6fpedarvwve5
  text: |-
    Research before the code:

    - `LspSession` gives two nonisolated members that the ops can read without `await`: `serverName` (the command, for example `pylsp`) and `capabilities` (`ServerCapabilities` with `callHierarchy`, `workspaceSymbol`, `implementation`).
    - `LspSupervisor` has `anySession()` only. To ask each session that advertises `workspaceSymbolProvider`, the supervisor needs a `sessions()` that gives each running session. `anySession()` then becomes `sessions().first`.
    - `LiveOpsCore.implementations` uses the shared `cascade(liveLayer:indexedLayers:empty:)`. `cascade` calls `liveLayer` one time, first. Thus the op can call the live layer before `cascade` and give the result to `cascade`. This keeps the cascade and lets the live layer also give the "not supported" fact.
    - No test makes an `ImplementationsResult` or a `WorkspaceSymbolsResult` directly, thus a new field with a default of `nil` changes no test.
    - `Tests/.../ResultEncodingTests.swift` tests the JSON that the tools give. This is where the difference between "not supported" and "no results" is visible in the tool text: a `String?` field is absent from the JSON when it is `nil`.
    - `FakeLanguageServerConnection.setInitializeResult(to:)` and `ServerCapabilities.noGatedMethod` make a daemon whose session advertises nothing, thus a supervisor test can make a "server without the method".
  timestamp: 2026-09-22T14:02:07.390785+00:00
- actor: claude-code
  id: 01m34qh7tyqj6s0w4yk3j968x9
  text: |
    ### implement — changed
    - evidence: 6 files. Sources: LSP/LspSession.swift (new `NotSupportedText` that makes the sentence one time for both ops), LSP/LspSupervisor.swift (new `sessions()`; `anySession()` is now `sessions().first`), Ops/LiveOpsCore.swift (`ImplementationsResult.notSupportedReason`, and `liveImplementations` now gives a `LiveImplementations` value that holds the result and the reason, thus the cascade to the index layers stays the same), Ops/LiveOpsExtended.swift (`WorkspaceSymbolsResult.notSupportedReason`; `workspaceSymbols` asks each running session that advertises `workspaceSymbolProvider`). Tests: LiveOpsExtendedTests.swift (+3 tests, shared daemon fixtures), LayeredOpsTests.swift (+3 tests), ResultEncodingTests.swift (+4 tests). Docs: docs/language-servers.md, new section "What an empty result means".
    - Red first: the two behavior tests failed with `notSupportedReason` = nil before the code, and they pass after it.
    - `swift build` ok; `swift test` 691 tests, 62 suites, 0 failures; `swift format lint -s -r Sources Tests` clean; the IntegrationTests package builds against the change (that package has no edit, thus its tests did not run).
    - next: /test
  timestamp: 2026-09-22T14:15:20.670795+00:00
- actor: claude-code
  id: 01m34qn37vfrp02azdb00sf0dm
  text: |-
    ### test — green
    - evidence: `swift test` — 691 tests, 62 suites, 0 failed, 0 skipped, 0 warnings (in-scope). `swift test --package-path IntegrationTests` — 2 tests, 2 suites, 0 failed (only the out-of-scope third-party mlx-swift "missing creator for mutated node" note). `swift format lint -s -r Sources Tests` — clean, exit 0. `swift format lint -s -r IntegrationTests/Tests` — clean, exit 0. No disabled or skipped tests found in the code.
    - next: ready for review.
  timestamp: 2026-09-22T14:17:27.035534+00:00
position_column: doing
position_ordinal: '80'
title: workspaceSymbols and implementations give an empty result when the server does not have the method
---
Source: a question from foundationmodelsacpagent-08 on 2026-09-22, after ^0ykcm6j.

## What happens

After ^0ykcm6j, `LspSession` does not send `workspace/symbol` or `textDocument/implementation` to a server that does not advertise them. It throws `LspSessionError.notAdvertised`. But the ops hide this error:

- `LiveOpsExtended.workspaceSymbols` (Ops/LiveOpsExtended.swift) catches every error and gives `WorkspaceSymbolsResult(symbols: [])`. It also uses `supervisor.anySession()`, so the answer comes from any running server, not a server of a known language.
- `LiveOpsCore.liveImplementations` (Ops/LiveOpsCore.swift) catches every error and gives `nil`. The cascade then goes to the index layer. When the index has nothing, the result is `ImplementationsResult(implementations: [], sourceLayer: .none)`.

Thus for pylsp an empty answer can mean "no results" or "this server does not have the method". A caller (and a model that uses the tools) cannot tell the difference. FoundationModelsACPAgent must tell the models which of the two it is.

## Proposed change

1. Add a field to `WorkspaceSymbolsResult` and `ImplementationsResult` (for example `unsupported: [String]`, the server commands that do not advertise the method, or one `notSupportedReason: String?`). Set it when a session throws `LspSessionError.notAdvertised`.
2. `workspaceSymbols`: ask each running session that advertises `workspaceSymbolProvider`, not one `anySession()`. When no running session advertises it, set the field.
3. `implementations`: keep the cascade to the index layers, but when the live layer failed with `notAdvertised`, keep that fact in the result.
4. The tool output (the `code_navigation` / `code_search` tools) must show this as text, for example "the language server for this file does not support implementations".
5. Do not change the result for other errors (timeouts, a server that is not running).

## Acceptance

- [x] With a fake server that does not advertise `workspaceSymbolProvider`, `workspaceSymbols` gives an empty list AND a field that says the server does not support it.
- [x] With a fake server that does not advertise `implementationProvider`, `implementations` gives the same kind of answer.
- [x] With a server that advertises the method and has no match, the result is empty and the field is not set.
- [x] The tool text shows "not supported" differently from "no results".
- [x] docs/language-servers.md tells which result a caller gets in each case.