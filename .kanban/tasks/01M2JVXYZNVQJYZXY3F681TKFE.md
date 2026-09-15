---
assignees:
- claude-code
depends_on:
- 01M2JVWH2DV2WCXTBHR6QBVGWQ
position_column: todo
position_ordinal: '8480'
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