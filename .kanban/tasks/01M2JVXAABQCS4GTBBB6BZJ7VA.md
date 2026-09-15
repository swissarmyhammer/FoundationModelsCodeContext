---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2khv4vp1hm6p4fjxfky91fm
  text: |-
    ### research — discoveries
    - `AnyOperation.run` wraps each error that `execute(in:)` throws in `OperationError.executionFailed`, and `OperationTool.call` throws it again. Thus a corrective message must be a return value: each operation returns `ToolOutcome<Result>`, and `.corrective` encodes as one JSON string.
    - New shared helpers on `enum ToolSupport` (later tool tasks must use them): `outcome(of:)` runs one engine call and changes a recoverable `CodeContextError` into `.corrective`; `outcome(after:of:)` does the same after a choice parse; `parseOptionalChoice(_:choices:parameter:)` gives `.value(nil)` for a missing optional choice, so the operation writes `parsed ?? CodeContextDefaults.<name>`; `choiceTable(for:)` makes a choice table from a `CaseIterable` enum with `String` raw values.
    - `@Guide(description: "...", .anyOf([...]))` compiles on a `String?` property, and the `@Operation` macro reads the literal `anyOf` list.
    - periphery runs with `--build-tests`, so a test is a caller. `CodeSearchTool` has a test caller, so it needs no `// periphery:ignore` marker. `CodeContextToolContext` now has a caller, so I removed its marker (a marker with a caller is reported as superfluous).
    - Test support: new `enum TestJSON` with `encodedText(_:)` in TestSupport.swift. Two older test files (`ResultEncodingTests`, `ToolSupportTests`) keep their own private copy.
    - Engine defect found (outside this task): `SymbolOps` sorts matches only by score, so matches with the same score have no fixed order. `searchSymbol(query: "greet")` gave a different order on two calls. I added a new task for the tie-break. The test `defaultsMatchTheDirectEngineCall` uses the query `helper`, which has no tie.
  timestamp: 2026-09-15T22:08:48.502537+00:00
- actor: claude-code
  id: 01m2kjezfw0fg48yrzsvervwyb
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Sources/FoundationModelsCodeContext/Tools/Search/{GetSymbolOperation,SearchSymbolOperation,ListSymbolOperation,GetCallgraphOperation,GetBlastradiusOperation,CodeSearchTool}.swift, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift. Changed: Tools/ToolSupport.swift (`parseOptionalChoice`, `choiceTable(for:)`, `outcome(of:)`, `outcome(after:of:)`), Tools/CodeContextToolContext.swift (removed the `// periphery:ignore` marker and its reason line, because the type now has a caller), Tests/.../TestSupport.swift (`enum TestJSON`).
    - TDD: the first build failed on the new test file (red); then the operations made it pass.
    - `swift test --filter "CodeSearchToolTests|ToolSupportTests"`: 15 tests pass. `swift test --filter CodeSearchToolTests`: 8 runs in a row, 7/7 pass each time (after the fix of the flaky search-symbol case, see the research comment and ^a7byaqk).
    - `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - swiftlint (`no_magic_numbers`, `force_unwrapping`, `force_try`, `force_cast`, `missing_docs`) on Tools/ and the changed test files: 0 findings.
    - periphery (`--retain-public`, tests indexed, `--report-exclude Tests/**`): 0 findings in the changed files. The remaining unused `CodeContextOperating` requirements are the calls of the later tool tasks (that file is not in this diff).
    - next: /test (full suite).
  timestamp: 2026-09-15T22:19:38.364754+00:00
- actor: claude-code
  id: 01m2kqemp4a75gs924q1ej1hjj
  text: |-
    ### test — green
    - evidence: `swift test` exit 0 — 587 tests in 52 suites passed, 0 failed, 0 skipped, 0 warnings, 0 errors. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0. `swift build --package-path IntegrationTests --build-tests` exit 0, 0 warnings.
    - The first full run hung: `DiagnosticsTests.settleTimeoutFlagsReportPending` waited in `ManualClock.waitForWaiter(count: 2)` for more than 25 minutes (`sample` of the test process gave the stack). The cause is in the test, not in the engine: after an update, the waiters of the previous race stay registered until the settle task cancels them, so a count of 2 can be satisfied by stale waiters. The test then moves the clock a second time, the old debounce deadline passes, `settle` can return `.settled` early, and no waiter is left for the next wait. The comment at the old line 182 named this gap, and the 5 ms real sleep only made it less probable.
    - Fix (test code only, the cause removed from the whole file): `DiagnosticsTests.continuousUpdatesResultInPendingAtHardTimeout` and `settleTimeoutFlagsReportPending` now wait with `waitForWaiter(withDeadline: clock.now.advanced(by: settleWindow))` — the deadline of the new race, which an old waiter cannot have. This is the same fix that task `^vhcye6y` made for `updateAtT200RestartsQuiescenceWindowSoSettleFiresAtT500NotT300`. The 5 ms sleeps are removed, and the settle window has a name (`settleWindow`, and `CodeContextDefaults.diagnosticsSettleWindow` in the pipeline test).
    - `swift test --filter DiagnosticsTests`: 10 runs in a row, 19/19 tests pass each time, no run over 1.3 seconds (each run had a 240-second kill limit, and no run reached it), while a test loop of another package loaded the machine.
    - next: /commit.
  timestamp: 2026-09-15T23:46:50.180637+00:00
depends_on:
- 01M2JVWH2DV2WCXTBHR6QBVGWQ
position_column: doing
position_ordinal: '80'
title: 'code_search tool: symbol and graph operations'
---
## What
Make the `code_search` `OperationTool<CodeContextToolContext>` with its first five operations. Follow the Notes example pattern (`FoundationModelsExtras/Examples/NotesTool/Sources/NotesToolCore/AddNote.swift`, `NotesTool.swift`): one file for each operation, an internal `@Generable @Operation` struct, and `execute(in:)` in an extension.

Rules for every operation in every tool task:
- **Names:** name each operation struct `<Verb><Noun>Operation` (for example `GetSymbolOperation`), in a file with the same name (`GetSymbolOperation.swift`). No new file can have the same name as a file in `Sources/FoundationModelsCodeContext` (Swift stops the build with "filename used twice"), and no new type can have the same name as a type in the module (for example `public enum GrepCode` and `public enum SearchCode` already exist).
- **Macro:** every `@Operation` gives all three arguments: `@Operation(verb: "...", noun: "...", description: "...")`. `description:` is required.
- **Defaults:** for an optional tool parameter, pass `value ?? CodeContextDefaults.<name>` (from ^6qbvgwq). Do not write a literal default in an operation.
- **Shared parameters:** the fused schema keeps the FIRST description of a shared parameter name, so each shared name has one type and one description that is correct for every operation that uses it.
- **Parameter aliases:** put `@OperationParam(aliases: [...])` on each parameter as the tables in the tool cards say. The key matcher already ignores case, `_` and `-`, so `max_results` or `file_path` need no alias. These standard aliases apply to a parameter name in every tool: `file` ← `path`, `filePath`, `filename`; `line` ← `row`, `lineNumber`; `character` ← `column`, `col`, `char`, `offset`; `maxResults` ← `limit`, `max`. An alias must not normalize to another parameter name of the same operation.
- **Tool resolver:** each tool's `make` passes `OperationResolver(verbAliases: Self.verbAliases, nounAliases: Self.nounAliases)`. A verb-alias key must not be a real verb of that tool, and a noun-alias key must not be a real noun of that tool, because the matcher applies aliases before it compares, and such a key would send a real op to a different op. The Extras default verb aliases (`show`, `read`, `fetch` → `get`) also apply.
- **Errors and choices:** enum parameters are `String` with `@Guide(.anyOf([...]))`, and `execute` parses them with `parseChoice(_:choices:parameter:)`. A recoverable `CodeContextError` or an invalid choice returns `ToolOutcome.corrective`; other errors are rethrown. File paths are relative to the context root.

Shared descriptions in `code_search` (use these exact meanings):
- `query`: "Text to search for: a symbol name for `get symbol` and `search symbol`, or free text for `search code`." (`query ast` uses a different parameter, `astQuery`.)
- `symbol`: "For `get callgraph`: a symbol name, or a `<file>:<line>:<column>` locator with 0-based numbers. For `get blastradius`: the name of a symbol inside `file`."
- `file`: "A file path relative to the workspace root."

`code_search` tool tables (all in `CodeSearchTool`):
- `verbAliases`: `lookup` → `get`, `locate` → `get`, `ls` → `list`, `enumerate` → `list`, `match` → `grep`. (Real verbs: get, search, list, grep, find, query.)
- `nounAliases`: `symbols` → `symbol`, `graph` → `callgraph`, `calls` → `callgraph`, `impact` → `blastradius`, `source` → `code`, `duplicate` → `duplicates`, `dupes` → `duplicates`. (Real nouns: symbol, callgraph, blastradius, code, duplicates, ast.)

- [x] `Sources/FoundationModelsCodeContext/Tools/Search/GetSymbolOperation.swift`: `@Operation(verb: "get", noun: "symbol", description: "...")`, `query: String` (aliases `name`, `symbol`), `maxResults: Int?` (standard aliases) → `getSymbol(query:maxResults: maxResults ?? CodeContextDefaults.maxQueryResults)`.
- [x] `Tools/Search/SearchSymbolOperation.swift` (`search`/`symbol`: `query` (aliases `name`, `symbol`), `kind: String?` (aliases `symbolKind`, `type`; names `function|method|type|other` mapped to `SymbolMetaType`), `maxResults`) and `Tools/Search/ListSymbolOperation.swift` (`list`/`symbol`: `file: String` (standard aliases)).
- [x] `Tools/Search/GetCallgraphOperation.swift` (`get`/`callgraph`: `symbol: String` (aliases `name`, `locator`), `direction: String?` (alias `dir`; names `inbound|outbound|both`), `maxDepth: Int?` (alias `depth`)) and `Tools/Search/GetBlastradiusOperation.swift` (`get`/`blastradius`: `file: String` (standard aliases), `symbol: String?` (alias `name`), `maxHops: Int?` (aliases `hops`, `depth`)).
- [x] `Tools/Search/CodeSearchTool.swift`: `enum CodeSearchTool` with `static let name = "code_search"`, a description, `static let verbAliases` and `static let nounAliases` (tables above), `static func operations() -> [AnyOperation<CodeContextToolContext>]`, and `static func make(context: CodeContextToolContext) throws -> OperationTool<CodeContextToolContext>` that passes the resolver.
- [x] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [x] `CodeSearchTool.make` succeeds (no `SchemaFusionError`), and the tool's op strings are `get symbol`, `search symbol`, `list symbol`, `get callgraph`, `get blastradius`.
- [x] Each operation returns the JSON of the engine result for a real indexed workspace.
- [x] An operation called with no optional parameters returns the same JSON as the direct engine call with no arguments.
- [x] Aliases work: `get call_graph`, `callgraph get`, `lookup symbol`, `get impact`, and `{"op": "get symbol", "name": ...}` and `{"op": "list symbol", "path": ...}` all dispatch to the correct operation.
- [x] An unknown symbol for `get callgraph` and an invalid `direction` give a corrective string, not a thrown error.
- [x] The fused schema's `symbol` and `query` descriptions are the shared descriptions above.

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift` (uses `import FoundationModels` and `import Operations`, and `@testable import FoundationModelsCodeContext`): build `CodeContext<FakeLanguageServerConnection>` with `withTemporaryWorkspace`, `FakeEmbedder`, `FakeFileEventSource`, `fakeConnectionFactory` and `autoInstall: LspAutoInstall(isEnabled: false)` (see `CodeContextE2ETests.swift`; no project markers), write a small Swift file, `start()`, then call `tool.call(arguments: GeneratedContent(properties: ["op": "get symbol", "query": ...]))` for each operation and assert on the JSON. Add `defaultsMatchTheDirectEngineCall` (for `get callgraph` and `get blastradius`), `aliasesDispatchToTheCanonicalOperation` (the alias cases in the acceptance criteria), corrective-path tests for an unknown symbol and an invalid `direction`, and `sharedParameterDescriptionsAreTheSharedText` that reads `tool.parameters`.
- [x] `swift build` exits 0.
- [x] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature