---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2k748t24qx8w21268547wcg
  text: |-
    ### precondition — done
    - The Extras resolver change is on FoundationModelsExtras origin/main at 8ec26d4 (parent d0048eb).
    - It adds `OperationResolver(verbAliases:nounAliases:inferOp:)` and a separator-free fallback match. Alias keys are compacted (lowercase, with no `_`, `-` or space).
    - Limit: the fallback does not split one token. `gettypedefinition` with no separator does not match.
    - Extras `swift test` exit 0 (9 new OperationResolverTests).
    - next: `swift package update foundationmodelsextras` resolves to 8ec26d4 or later.
  timestamp: 2026-09-15T19:01:33.122669+00:00
- actor: claude-code
  id: 01m2kehc34mtbqhd5dzqwc99xp
  text: |-
    ### research — discoveries
    - Extras origin/main is 8ec26d4. Its manifest declares tools 6.2 and has no Router dependency. Product `Operations`.
    - `Package.resolved` is gitignored in this repo and in IntegrationTests, so the update does not change a tracked file.
    - The engine defaults are also written in the op engines, not only in `CodeContext.swift`: `SymbolOps` (50 x2), `GrepCode` (`[]`, 50), `CallGraphOps` (.outbound, 2), `BlastRadiusOps` (3), `SearchCode` and `ManagerQueries` (20, .default), `FindDuplicatesOps` (0.85, 100, 5), `LiveOpsCore` (false x3, false, private `defaultMaxImplementations` 20), `Settle` (300 ms, 5 s), `Diagnose` (.warning, true, 300 ms, 5 s, 100). So that each default is written one time, these default arguments also use `CodeContextDefaults`.
    - `CodeContextDefaults` must be `@usableFromInline`: public default arguments refer to it.
    - Rule "a function belongs to a type" (swift immutability rule): `correctiveMessage(for:)` and `parseChoice(_:choices:parameter:)` are `static` functions on `enum ToolSupport`, not top-level functions. Later tasks call `ToolSupport.parseChoice(...)` and `ToolSupport.correctiveMessage(for:)`.
    - `CodeContextToolContext` and `CodeContextOperating` have no caller until the later tool tasks, so each has a `// periphery:ignore` marker with the reason in the doc comment above it (dead-code-swift staging contract).
  timestamp: 2026-09-15T21:11:02.500478+00:00
- actor: claude-code
  id: 01m2kf3ff12sbt74q0cvbw7a9q
  text: |-
    ### implement — changed
    - evidence: 17 files. New: Sources/FoundationModelsCodeContext/Tools/{CodeContextDefaults,CodeContextOperating,CodeContextToolContext,ToolSupport}.swift, Tests/FoundationModelsCodeContextTests/ToolSupportTests.swift. Changed: Package.swift (tools 6.2, Extras dependency, `Operations` on main and test targets), CodeContext.swift, Ops/{QueryAST,CallGraph,BlastRadius,GrepCode,SymbolOps,SearchCode,ManagerQueries,FindDuplicates,LiveOpsCore}.swift, Diagnostics/{Diagnose,Settle}.swift (default arguments use `CodeContextDefaults`; the private `LiveOpsCore.defaultMaxImplementations` is removed).
    - `swift package update foundationmodelsextras` exit 0 (root and `--package-path IntegrationTests`); Extras at 8ec26d4; `rg -c nounAliases` on OperationResolver.swift gives 8. A stale `.build/checkouts/EventSource` (from the removed Router) blocked the first update; I removed it.
    - `swift package dump-package | rg -c FoundationModelsExtras` = 3; `show-dependencies` has no Router line; the acceptance `rg` on CodeContext.swift gives no output.
    - `swift build` exit 0; `swift build --package-path IntegrationTests --build-tests` exit 0; `swift format lint -r --strict ...` exit 0; `swift test --filter ToolSupportTests` 8/8 pass.
    - next: /test (full suite).
  timestamp: 2026-09-15T21:20:55.777373+00:00
- actor: claude-code
  id: 01m2kg4c6bpraw3amk8aj981zh
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` — 3 findings (3 confirmed, 0 refuted): Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:66, Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:69, Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift:16
    - next: implement the 3 findings (iteration 2).
  timestamp: 2026-09-15T21:38:53.771302+00:00
- actor: claude-code
  id: 01m2kg4hd8n16xba8etdmex0wj
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — Package.swift (tools 6.2, Extras `Operations` on the main and test targets), 4 new files in Sources/FoundationModelsCodeContext/Tools, ToolSupportTests.swift, engine defaults moved to `CodeContextDefaults` in CodeContext.swift, Ops/* and Diagnostics/*.
    - test: green — `swift test` 580 tests in 51 suites passed, 0 failed, 0 skipped, 0 warnings; `swift format lint -r --strict` exit 0; `swift build --package-path IntegrationTests --build-tests` exit 0.
    - commit: 0dc724b
    - review: findings — 3: `Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:66` code-hygiene/magic-numbers-swift "Magic numbers should be replaced by named constants."; `Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:69` code-hygiene/magic-numbers-swift "Magic numbers should be replaced by named constants."; `Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift:16` code-hygiene/dead-code-swift "protocol `CodeContextOperating` is superfluousIgnoreCommand."
  timestamp: 2026-09-15T21:38:59.112635+00:00
- actor: claude-code
  id: 01m2kg92k9mbqe0eshsgyr2ba8
  text: |-
    ### implement — changed
    - evidence: 2 files. Tools/CodeContextDefaults.swift: the literals `300` and `5` are now the named `private static let diagnosticsSettleWindowMilliseconds` and `diagnosticsHardTimeoutSeconds`; `diagnosticsSettleWindow` and `diagnosticsHardTimeout` use them (findings :66 and :69). Tools/CodeContextOperating.swift: removed the superfluous `// periphery:ignore` marker and its reason line, because the protocol has a reference (finding :16). `CodeContextToolContext` keeps its marker, because it has no caller yet.
    - `swift build` exit 0, no warnings; `swift format lint -r --strict ...` exit 0.
    - next: /test (full suite).
  timestamp: 2026-09-15T21:41:27.785320+00:00
position_column: doing
position_ordinal: '80'
title: 'Tool foundation: add Extras Operations, the tool context and corrective output'
---
## What
Prepare the main target `FoundationModelsCodeContext` for operation-based FoundationModels tools. The user decided: the tool code goes in the one main target (examples and integration tests stay separate targets), there are three tools (`code_search`, `code_navigation`, `code_index`), each tool operates on one `CodeContext`, `path` and `file` are aliases, multi-word nouns work with and without `_`, and the tools have thoughtful aliases.

Framework facts (FoundationModelsExtras, product `Operations`): operations are `@Generable @Operation(verb:noun:description:)` structs (all three macro arguments are required) that conform to `OperationDefinition` with one shared `Context: Sendable` and `func execute(in context: Context) async throws -> Output` (`Output: Encodable & Sendable`). `OperationTool<Context>(name:description:context:operations:resolver:)` fuses them. Parameters can be only `String`, `Int`, `Double`, `Bool`, arrays and optionals. `@OperationParam(aliases:)` works at dispatch only (aliases are not in the schema). The parameter-key matcher ignores case, `_` and `-`. `@Guide(.anyOf)` values are NOT enforced at dispatch. `OperationError.executionFailed` is rethrown and stops the model's turn; FoundationModelsSkills returns recoverable errors as a corrective output instead (see `CorrectiveOutcome` in `FoundationModelsSkills/Sources/FoundationModelsSkills/Operations/OperationSupport.swift`).

**Precondition (Extras change):** the Extras agent (`foundationmodelsextras-34`) adds `OperationResolver(verbAliases:nounAliases:inferOp:)` and op matching that ignores `_`, `-` and spaces inside compound verbs and nouns (so `get typedefinition`, `get type_definition` and `type_definition get` all resolve). Start this task only after that commit is on Extras `origin/main`.

- [ ] `Package.swift`: change `// swift-tools-version: 6.1` to `6.2` (Extras requires 6.2). Add `.package(url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git", branch: "main")` with a comment in the same style as the Ranker entry. Add `.product(name: "Operations", package: "FoundationModelsExtras")` to the `FoundationModelsCodeContext` target AND to the `FoundationModelsCodeContextTests` target (the tool tests use `OperationTool`, `AnyOperation` and `GeneratedContent` directly; follow the existing comment rule for Ranker in the test target). Run `swift package update foundationmodelsextras` (and with `--package-path IntegrationTests`) so the resolved Extras has `nounAliases`.
- [ ] Add `Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift`: an internal `enum CodeContextDefaults` with one named constant for each engine default: `maxQueryResults = 50`, `includeSource = false`, `callGraphDirection = CallGraphDirection.outbound`, `callGraphMaxDepth = 2`, `blastRadiusMaxHops = 3`, `grepLanguages: [String] = []`, `searchTopK = 20`, `searchWeights = SearchWeights.default`, `duplicateMinSimilarity = 0.85`, `duplicateMinChunkBytes = 100`, `duplicateMaxPerChunk = 5`, `queryASTMaxResults = 50`, `referencesIncludeDeclaration = false`, `implementationsMaxResults = 20`, `diagnosticsSeverity = DiagnosticSeverity.warning`, `diagnosticsIncludeDependents = true`, `diagnosticsSettleWindow = Duration.milliseconds(300)`, `diagnosticsHardTimeout = Duration.seconds(5)`, `diagnosticsPerReportCap = 100`. Change the default arguments of the public `CodeContext` methods (and `QueryASTOptions.maxResults`) to use these constants, and make `CodeContext.defaultMaxQueryResults` and `CodeContext.defaultIncludeSource` return them, so each default has one source. Public signatures do not change.
- [ ] Add `Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift`: an internal `protocol CodeContextOperating: Sendable` with exactly these 23 `CodeContext` methods (same signatures, no default arguments, find them by name, not by line): `detectProjects`, `indexStatus`, `lspStatus`, `rebuildIndex`, `getSymbol`, `searchSymbol`, `listSymbols`, `callGraph`, `blastRadius`, `grepCode`, `searchCode`, `findDuplicates`, `queryAST`, `definition`, `typeDefinition`, `hover`, `references`, `implementations`, `codeActions`, `renameEdits`, `inboundCalls`, `workspaceSymbols`, `diagnostics`; and `extension CodeContext: CodeContextOperating {}`. In the same folder add `CodeContextToolContext.swift`: an INTERNAL `struct CodeContextToolContext: Sendable` that holds `let operating: any CodeContextOperating` (internal, because no public API takes or returns it; `CodeContextTools.make` returns `[any Tool]`). A protocol requirement cannot have default arguments, so every operation passes each optional tool parameter as `value ?? CodeContextDefaults.<name>`.
- [ ] Add `Sources/FoundationModelsCodeContext/Tools/ToolSupport.swift`: (1) `enum ToolOutcome<Success: Encodable & Sendable>: Encodable, Sendable` with `.success(Success)` (encodes the value) and `.corrective(String)` (encodes a bare JSON string); (2) `func correctiveMessage(for error: CodeContextError) -> String?` that returns a message for the recoverable cases `.notFound`, `.pattern`, `.query`, `.spawnFailed` (a git failure, for example a directory that is not a git repository or a bad commit) and `nil` for the others; (3) `enum ChoiceParse<T> { case value(T), corrective(String) }` and `func parseChoice<T>(_ raw: String?, choices: [(name: String, value: T)], parameter: String) -> ChoiceParse<T>` that matches a name (case-insensitive, and ignoring `_` and `-`) or gives a corrective message that lists the allowed names. A name table is necessary because `DiagnosticSeverity` has `Int` raw values. When a choice needs a second value at call time (the diagnostics `scope` needs `file` or `sha`), the table maps the name to a private kind enum, and the operation checks the second value and makes the final value itself (see ^dw4p9bj).
- [ ] Write every comment in ASD-STE100 Simplified Technical English. No new file can have the same name as a file that is already in `Sources/FoundationModelsCodeContext`, and no new type can have the same name as a type in the module.

## Acceptance Criteria
- [ ] `swift package dump-package | rg -c FoundationModelsExtras` gives a count; `swift package show-dependencies --format json | rg -c -i foundationmodelsrouter` gives no output (Extras does not add Router).
- [ ] `rg -n "nounAliases" .build/checkouts/FoundationModelsExtras/Sources/Operations/OperationResolver.swift` gives a count (the resolved Extras has the precondition change).
- [ ] `CodeContext` conforms to `CodeContextOperating`, and the protocol has the 23 methods listed above.
- [ ] Each engine default is written one time, in `CodeContextDefaults`; `rg -n "maxDepth: Int = 2|maxHops: Int = 3|topK: Int = 20|minSimilarity: Double = 0.85" Sources/FoundationModelsCodeContext/CodeContext.swift` gives no output.
- [ ] `CodeContextToolContext` is not public.
- [ ] A corrective outcome encodes as a JSON string, and a success outcome encodes as the value.
- [ ] `parseChoice` accepts each name (any letter case, with or without `_`) and rejects an unknown name with the list of allowed names.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/ToolSupportTests.swift`: `successOutcomeEncodesTheValue`, `correctiveOutcomeEncodesABareString`, `parseChoiceAcceptsEachNameInAnyCaseAndSeparator`, `parseChoiceRejectsAnUnknownNameWithTheAllowedList`, `recoverableErrorsGiveACorrectiveMessage` (includes `.spawnFailed`), `otherErrorsGiveNoCorrectiveMessage`, `codeContextDefaultsMatchThePublicDefaults` (for example `CodeContext<FakeLanguageServerConnection>.defaultMaxQueryResults == CodeContextDefaults.maxQueryResults` and `QueryASTOptions().maxResults == CodeContextDefaults.queryASTMaxResults`).
- [ ] All existing tests stay green (the public default values do not change).
- [ ] `swift build` exits 0, and `swift build --package-path IntegrationTests --build-tests` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature

## Review Findings (2026-09-15 16:23)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [ ] `Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:66` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Sources/FoundationModelsCodeContext/Tools/CodeContextDefaults.swift:69` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift:16` `code-hygiene/dead-code-swift` — protocol `CodeContextOperating` is superfluousIgnoreCommand.