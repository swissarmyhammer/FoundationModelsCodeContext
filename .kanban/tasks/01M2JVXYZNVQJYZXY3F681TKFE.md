---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2ksfamz4tcv9js3bcfjx85s
  text: |-
    ### implement — changed
    - evidence: 9 files. New: Sources/FoundationModelsCodeContext/Tools/Navigation/{GetDefinitionOperation,GetTypeDefinitionOperation,GetHoverOperation,GetReferencesOperation,GetImplementationsOperation,CodeNavigationTool}.swift, Tests/FoundationModelsCodeContextTests/{CodeNavigationToolTests,ToolTestSupport}.swift. Changed: Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift.
    - Each operation follows the pattern of the `code_search` operations: `@Operation` with the three arguments, `@OperationParam` aliases, `value ?? CodeContextDefaults.<name>` for each optional parameter, and `ToolSupport.outcome { }` for the engine call. No operation of this task parses a choice, so no `parseChoice` call is necessary.
    - `get references` gives `maxResults` to the engine as it is, because the engine reads `nil` as "no limit". `get implementations` uses `?? CodeContextDefaults.implementationsMaxResults`.
    - The shared `line` and `character` descriptions say that the numbers are 0-based and that `character` is a UTF-16 offset. The standard aliases of a position are `row` for `line` and `column`/`col` for `character`.
    - Discovery: with an indexed workspace and no running language server, each of the five operations answers from the LSP index, not from tree-sitter. The test first expected `.treeSitter` and the run gave `.lspIndex` for all five results. The tests and the suite doc comment now say `lspIndex`. A later task that tests a fall-back layer must use this fact.
    - To prevent a duplicate of the tool-test setup, the shared helpers are now `enum ToolTest` in the new ToolTestSupport.swift (`withIndexedTool(source:file:embeddingDimension:make:_:)`, `expectEachCall(_:on:)`, `decodedString(_:)`). CodeSearchToolTests calls the same helpers, so no block is copied.
    - `swift test --filter "CodeNavigationToolTests|CodeSearchToolTests"`: 18 tests in 2 suites pass. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - next: /test (full suite).
  timestamp: 2026-09-16T00:22:09.823290+00:00
- actor: claude-code
  id: 01m2ksftt9x9hywggpxpk3hxaa
  text: |-
    ### test — green
    - evidence: `swift test` exit 0 — 599 tests in 53 suites passed, 0 failed, 0 skipped. The full log has no `error:` line and no `warning:` line. The run took 4.8 seconds of test time.
    - `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - `swift build --package-path IntegrationTests --build-tests` exit 0, 0 warnings and 0 errors in the log.
    - `swift test --filter "CodeNavigationToolTests|CodeSearchToolTests"`: 18 tests in 2 suites pass, each run less than 0.1 seconds.
    - next: /commit.
  timestamp: 2026-09-16T00:22:26.377838+00:00
depends_on:
- 01M2JVWH2DV2WCXTBHR6QBVGWQ
position_column: doing
position_ordinal: '80'
title: 'code_navigation tool: position operations'
---
## What
Make the `code_navigation` `OperationTool<CodeContextToolContext>` with its first five operations, using the Notes example pattern. Follow ALL the rules in ^6bzj7va ("Rules for every operation in every tool task": `<Verb><Noun>Operation` names in files with the same name, `@Operation(verb:noun:description:)` with all three arguments, optional parameters as `value ?? CodeContextDefaults.<name>`, shared parameter names keep one type and one description, standard parameter aliases, tool resolver with verb and noun aliases, recoverable errors give `ToolOutcome.corrective`).

Positions: `line` and `character` are 0-based (`character` is a UTF-16 offset), and the shared `@Guide` descriptions must say so. `file` is relative to the context root. Without a running language server these operations fall back to the LSP index and then tree-sitter, and the result's `sourceLayer` tells which layer answered.

Shared `file` description in `code_navigation` (the first operation registers it, so every navigation operation uses this exact text): "A file path relative to the workspace root. `get diagnostics` also accepts an absolute path or a glob."

`code_navigation` tool tables (all in `CodeNavigationTool`):
- `verbAliases`: `find` → `get`, `lookup` → `get`, `goto` → `get`, `list` → `get`, `check` → `get`, `query` → `search`. (Real verbs: get, search.)
- `nounAliases`: `def` → `definition`, `typedef` → `type_definition`, `type` → `type_definition`, `info` → `hover`, `docs` → `hover`, `reference` → `references`, `refs` → `references`, `usages` → `references`, `implementation` → `implementations`, `impls` → `implementations`, `code_action` → `code_actions`, `actions` → `code_actions`, `fixes` → `code_actions`, `rename` → `rename_edits`, `inbound_call` → `inbound_calls`, `incoming_calls` → `inbound_calls`, `callers` → `inbound_calls`, `workspace_symbols` → `workspace_symbol`, `symbol` → `workspace_symbol`, `symbols` → `workspace_symbol`, `diagnostic` → `diagnostics`, `errors` → `diagnostics`, `problems` → `diagnostics`. (Real nouns: definition, type_definition, hover, references, implementations, code_actions, rename_edits, inbound_calls, workspace_symbol, diagnostics.)

- [ ] `Sources/FoundationModelsCodeContext/Tools/Navigation/GetDefinitionOperation.swift` (`get`/`definition`: `file: String`, `line: Int`, `character: Int` (all with the standard aliases), `includeSource: Bool?` (aliases `withSource`, `source`) → `includeSource ?? CodeContextDefaults.includeSource`) and `Tools/Navigation/GetTypeDefinitionOperation.swift` (`get`/`type_definition`, same parameters and aliases).
- [ ] `Tools/Navigation/GetHoverOperation.swift`: `get`/`hover`: `file`, `line`, `character` (standard aliases).
- [ ] `Tools/Navigation/GetReferencesOperation.swift`: `get`/`references`: `file`, `line`, `character`, `includeDeclaration: Bool?` (aliases `withDeclaration`, `includeDecl`; `?? CodeContextDefaults.referencesIncludeDeclaration`), `maxResults: Int?` (standard aliases; pass `nil` through, because the engine treats `nil` as "no limit").
- [ ] `Tools/Navigation/GetImplementationsOperation.swift` (`get`/`implementations`: `file`, `line`, `character`, `includeSource: Bool?`, `maxResults: Int?` → `?? CodeContextDefaults.implementationsMaxResults`) and `Tools/Navigation/CodeNavigationTool.swift`: `enum CodeNavigationTool` with `static let name = "code_navigation"`, a description, `static let verbAliases` and `static let nounAliases` (tables above), `static func operations()` and `static func make(context:)` that passes the resolver.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `CodeNavigationTool.make` succeeds with the op strings `get definition`, `get type_definition`, `get hover`, `get references`, `get implementations`.
- [ ] Each operation returns the JSON of the engine result (including `sourceLayer`) for an indexed workspace with no running language server.
- [ ] `get references` and `get implementations` with no optional parameters return the same JSON as the direct engine calls with no optional arguments.
- [ ] Aliases work: `get typedefinition`, `type_definition get`, `goto def`, `find references`, `find reference`, `get refs`, and `{"op": "get hover", "path": ..., "row": ..., "column": ...}` dispatch to the correct operation with the correct values.
- [ ] A missing required `line` gives the framework's corrective "missing required" output.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeNavigationToolTests.swift` (uses `import FoundationModels` and `import Operations`, and `@testable import FoundationModelsCodeContext`): build `CodeContext<FakeLanguageServerConnection>` as in `CodeContextE2ETests.swift` with `autoInstall: LspAutoInstall(isEnabled: false)` and no project markers (so no daemon starts), write and index a small Swift file, `start()`, then call each operation through `tool.call(arguments: GeneratedContent(properties:))` and assert on the JSON keys and the `sourceLayer` value. Add `defaultsMatchTheDirectEngineCall`, `aliasesDispatchToTheCanonicalOperation` (the alias cases in the acceptance criteria), and a test for a missing required parameter.
- [ ] `swift build` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature