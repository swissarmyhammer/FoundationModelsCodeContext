---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2kvj1hq6m7gf5j658ert7dy
  text: |-
    ### implement — changed
    - evidence: 15 files. New: Sources/FoundationModelsCodeContext/Tools/Index/{GetStatusOperation,GetLspStatusOperation,RebuildIndexOperation,DetectProjectsOperation,CodeIndexTool}.swift, Tools/CodeContextTools.swift, Tests/FoundationModelsCodeContextTests/{CodeIndexToolTests,CodeContextToolsTests,CodeContextToolsPublicAPITests}.swift. Changed: Tools/ToolSupport.swift, Tools/CodeContextDefaults.swift, Tools/Search/CodeSearchTool.swift, Tools/Navigation/CodeNavigationTool.swift, Tests/{ToolTestSupport,TestSupport,CodeSearchToolTests,CodeNavigationToolTests,CallerEmbedderPublicAPITests}.swift.
    - `get status`, `get lsp_status` and `detect projects` are structs with no parameters, because their engine calls have none. A parameterless `@Generable @Operation` struct is legal: the Extras example `ListNotes` has the same shape.
    - `rebuild index` parses `layer` with `ToolSupport.parseChoice`. The table is `ToolSupport.choiceTable(for: RebuildLayer.self)`, not a hand-written table, because the raw value of each `RebuildLayer` case is already the name that the card asks for: treesitter, lsp, embedding, all. The match ignores `_`, so `tree_sitter` also finds `treesitter`.
    - `CodeContextTools.make`, `toolNames` and `operationNames` are the only new public API. `make` is generic over `Connection: LanguageServerConnection` and gives `[any Tool]`, so a host needs no `import Operations`.
    - The card asks for `make(context:includesSchemaInInstructions:)`. `ToolSupport.makeOperationTool` now takes that value, and the `make` function of each of the three tools passes it. No `make` calls `OperationTool(...)` directly.
    - The default of that value is the new `CodeContextDefaults.includesSchemaInInstructions`, so the three tools always start with the same value and the literal `true` has one place.
    - Discovery: Swift does not apply a default argument to a function reference. `make: CodeSearchTool.make` therefore stopped compiling when `make` took the second parameter. The two existing suites now give a closure: `make: { try CodeSearchTool.make(context: $0) }`.
    - To prevent a duplicate of the setup, `ToolTest.withStartedContext(source:file:embeddingDimension:_:)` is new and holds the workspace, the `CodeContext` and the stop. `withIndexedTool` now calls it, and `CodeContextToolsTests` uses it directly.
    - To prevent a second copy of the caller-defined embedder, `CallerDefinedEmbedder` moved from a private nested type of CallerEmbedderPublicAPITests to TestSupport.swift. Both public-API suites now use that one type.
    - `aliasTablesAreSafe` reads the tables of all three tools and each operation's `parameterMetadata`. For the parameter rule it reports a collision only when an alias normalizes to a name or an alias of a **different** parameter, because two aliases of one parameter both name that parameter and cannot misroute a value.
    - next: /test (full suite).
  timestamp: 2026-09-16T00:58:35.959912+00:00
- actor: claude-code
  id: 01m2kvj6kqgnz47vrk4vv8r5as
  text: |-
    ### test — green
    - evidence: `swift test` exit 0 — 616 tests in 56 suites passed, 0 failed, 0 skipped. The full log has no `error:` line and no `warning:` line (the count of both is 0). The test time was 4.7 seconds.
    - The count is 12 tests more than the 604 tests of the last task, because this task adds 12 tests: 6 in CodeIndexToolTests, 5 in CodeContextToolsTests and 1 in CodeContextToolsPublicAPITests.
    - `swift build --build-tests` exit 0, with 0 errors and 0 warnings.
    - `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - `swift build --package-path IntegrationTests --build-tests` exit 0, with 0 errors and 0 warnings.
    - The first build gave one error and four warnings, and both are now corrected: `#expect` takes a `Comment`, so the message of the parameter-alias check must be one interpolated literal and not two strings with `+`; and `indexStatus()` and `lspStatus()` do not throw, so the `try` on those four calls was not necessary.
    - next: /commit.
  timestamp: 2026-09-16T00:58:41.143402+00:00
- actor: claude-code
  id: 01m2kvrzrr1z6xkxdynvqvv5zh
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (d07f508) — 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed, 0 skipped). 18 files reviewed; the 4 `.kanban/` files are excluded by `.reviewignore`.
    - No finding is open, because this is iteration 1 and it gave no finding.
    - Each box of the card is now checked: the four operation files of Tools/Index, CodeIndexTool with its two alias tables, CodeContextTools with `make`, `toolNames` and `operationNames`, the three tools with 9, 10 and 4 operations, the safe alias tables, the alias dispatch of `get lspstatus`, `get lsp`, `refresh index`, `scan projects`, `list project` and `rebuild index` with `target: tree_sitter`, the corrective string of an invalid layer, the registration on a `LanguageModelSession`, `swift build`, `swift build --package-path IntegrationTests --build-tests`, `swift format lint` and `swift test`.
    - next: move the task to done.
  timestamp: 2026-09-16T01:02:23.512524+00:00
- actor: claude-code
  id: 01m2kvs57jpqynmv9h6nv7g76a
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 new files (Tools/Index/{GetStatusOperation,GetLspStatusOperation,RebuildIndexOperation,DetectProjectsOperation,CodeIndexTool}.swift, Tools/CodeContextTools.swift, and the three new test suites CodeIndexToolTests, CodeContextToolsTests, CodeContextToolsPublicAPITests), and 6 changed files (ToolSupport.swift and CodeContextDefaults.swift for `includesSchemaInInstructions`, the `make` function of the two other tools, ToolTestSupport.swift for the shared `withStartedContext`, TestSupport.swift for the shared `CallerDefinedEmbedder`, and the call sites in the three older test files).
    - test: green — `swift test` 616 tests in 56 suites passed, 0 failed, 0 skipped, 0 warnings; `swift build --build-tests` exit 0; `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0; `swift build --package-path IntegrationTests --build-tests` exit 0.
    - commit: d07f508
    - review: clean — `review sha HEAD~1..HEAD` 0 findings (7 attempted, 0 failed, 0 refuted). No finding was open from a previous iteration.
  timestamp: 2026-09-16T01:02:29.106916+00:00
depends_on:
- 01M2JVXMF987MDJWG7533EJV0T
- 01M2JVYA791J25KMC3VDW4P9BJ
- 01M2JVWWAYY3VPYYH3XFAGWVZ8
position_column: done
position_ordinal: c880
title: code_index tool and the public CodeContextTools factory
---
## What
Make the `code_index` tool and the one public entry point that gives a host all three tools for one `CodeContext`. Follow ALL the rules in ^6bzj7va ("Rules for every operation in every tool task": `<Verb><Noun>Operation` names in files with the same name, `@Operation(verb:noun:description:)` with all three arguments, no file or type name that is already in the module, tool resolver with verb and noun aliases).

`code_index` tool tables (all in `CodeIndexTool`):
- `verbAliases`: `check` → `get`, `refresh` → `rebuild`, `scan` → `detect`, `discover` → `detect`, `find` → `detect`, `list` → `detect`. (Real verbs: get, rebuild, detect.)
- `nounAliases`: `state` → `status`, `progress` → `status`, `index_status` → `status`, `lsp` → `lsp_status`, `servers` → `lsp_status`, `server_status` → `lsp_status`, `language_servers` → `lsp_status`, `project` → `projects`, `languages` → `projects`. (Real nouns: status, lsp_status, index, projects. `index` cannot be a noun alias for `status`, because it is a real noun of `rebuild index`.)

- [ ] `Sources/FoundationModelsCodeContext/Tools/Index/GetStatusOperation.swift` (`get`/`status`, no parameters → `indexStatus()`) and `Tools/Index/GetLspStatusOperation.swift` (`get`/`lsp_status`, no parameters → `lspStatus()`).
- [ ] `Tools/Index/RebuildIndexOperation.swift` (`rebuild`/`index`: `layer: String` (alias `target`; names `treesitter|lsp|embedding|all` mapped to `RebuildLayer` through `parseChoice(_:choices:parameter:)`, so `tree_sitter` also works); an invalid name gives a corrective string) and `Tools/Index/DetectProjectsOperation.swift` (`detect`/`projects`, no parameters → `detectProjects()`).
- [ ] `Tools/Index/CodeIndexTool.swift`: `enum CodeIndexTool` with `static let name = "code_index"`, a description, `static let verbAliases` and `static let nounAliases` (tables above), `static func operations()` and `static func make(context:)` that passes the resolver.
- [ ] `Tools/CodeContextTools.swift`: `public enum CodeContextTools` with `public static func make<Connection>(context: CodeContext<Connection>, includesSchemaInInstructions: Bool = true) throws -> [any Tool]` that returns the `code_search`, `code_navigation` and `code_index` tools built on one internal `CodeContextToolContext`; `public static let toolNames: [String]`; and `public static let operationNames: [String: [String]]` (tool name → op strings, computed from each tool's `operations()`), so code outside the module (the example, docs tests) can list the op strings without `import Operations`.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English. Every new public declaration has a doc comment.

## Acceptance Criteria
- [ ] `CodeContextTools.make(context:)` returns three tools named `code_search`, `code_navigation`, `code_index`, with 9, 10 and 4 operations.
- [ ] `CodeContextTools.operationNames` equals the op strings of the three tools.
- [ ] The only new public API is `CodeContextTools` (`make`, `toolNames`, `operationNames`).
- [ ] The alias tables of all three tools are safe: in each tool, no verb-alias key is a real verb, no noun-alias key is a real noun, every alias value is a real verb or noun, and in each operation no parameter alias normalizes to another parameter name or another alias of the same operation.
- [ ] Aliases work: `get lspstatus`, `get lsp`, `refresh index`, `scan projects`, `list project`, and `{"op": "rebuild index", "target": "tree_sitter"}` dispatch to the correct operation.
- [ ] The three tools can be given to `LanguageModelSession(tools:instructions:)` (construction only, no model call).
- [ ] `rebuild index` with `layer: "bogus"` gives a corrective string.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeIndexToolTests.swift` (uses `import FoundationModels` and `import Operations`): each operation through `tool.call(arguments:)` against a started `CodeContext<FakeLanguageServerConnection>` in a temporary workspace with `autoInstall: LspAutoInstall(isEnabled: false)` and no project markers at `start()`. `rebuild index` with `layer: "treesitter"` returns a JSON `RebuildIndexResult`. For `detect projects`, write the `Package.swift` marker AFTER `start()` and then call the operation (`detectProjects()` only publishes projects and starts no daemon), and assert the JSON names the Swift project. Add the invalid-layer corrective test and `aliasesDispatchToTheCanonicalOperation` (the alias cases in the acceptance criteria).
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeContextToolsTests.swift`: `makeReturnsTheThreeNamedTools`, `eachToolHasTheExpectedOperationCount`, `operationNamesMatchTheTools`, `aliasTablesAreSafe` (the rules in the acceptance criteria, for all three tools, read from each tool's `verbAliases`, `nounAliases` and each operation's `parameterMetadata`), `toolsCanBeRegisteredOnALanguageModelSession` (same idea as Extras `Tests/OperationsTests/OperationToolTests.swift`), and a separate file `CodeContextToolsPublicAPITests.swift` with a plain `import FoundationModelsCodeContext` (no `@testable`) that shows `CodeContextTools.make`, `toolNames` and `operationNames` are public.
- [ ] `swift build` exits 0, and `swift build --package-path IntegrationTests --build-tests` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature