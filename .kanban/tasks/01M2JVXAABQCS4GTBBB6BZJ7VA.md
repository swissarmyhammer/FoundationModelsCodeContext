---
assignees:
- claude-code
depends_on:
- 01M2JVWH2DV2WCXTBHR6QBVGWQ
position_column: todo
position_ordinal: '8280'
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

- [ ] `Sources/FoundationModelsCodeContext/Tools/Search/GetSymbolOperation.swift`: `@Operation(verb: "get", noun: "symbol", description: "...")`, `query: String` (aliases `name`, `symbol`), `maxResults: Int?` (standard aliases) → `getSymbol(query:maxResults: maxResults ?? CodeContextDefaults.maxQueryResults)`.
- [ ] `Tools/Search/SearchSymbolOperation.swift` (`search`/`symbol`: `query` (aliases `name`, `symbol`), `kind: String?` (aliases `symbolKind`, `type`; names `function|method|type|other` mapped to `SymbolMetaType`), `maxResults`) and `Tools/Search/ListSymbolOperation.swift` (`list`/`symbol`: `file: String` (standard aliases)).
- [ ] `Tools/Search/GetCallgraphOperation.swift` (`get`/`callgraph`: `symbol: String` (aliases `name`, `locator`), `direction: String?` (alias `dir`; names `inbound|outbound|both`), `maxDepth: Int?` (alias `depth`)) and `Tools/Search/GetBlastradiusOperation.swift` (`get`/`blastradius`: `file: String` (standard aliases), `symbol: String?` (alias `name`), `maxHops: Int?` (aliases `hops`, `depth`)).
- [ ] `Tools/Search/CodeSearchTool.swift`: `enum CodeSearchTool` with `static let name = "code_search"`, a description, `static let verbAliases` and `static let nounAliases` (tables above), `static func operations() -> [AnyOperation<CodeContextToolContext>]`, and `static func make(context: CodeContextToolContext) throws -> OperationTool<CodeContextToolContext>` that passes the resolver.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `CodeSearchTool.make` succeeds (no `SchemaFusionError`), and the tool's op strings are `get symbol`, `search symbol`, `list symbol`, `get callgraph`, `get blastradius`.
- [ ] Each operation returns the JSON of the engine result for a real indexed workspace.
- [ ] An operation called with no optional parameters returns the same JSON as the direct engine call with no arguments.
- [ ] Aliases work: `get call_graph`, `callgraph get`, `lookup symbol`, `get impact`, and `{"op": "get symbol", "name": ...}` and `{"op": "list symbol", "path": ...}` all dispatch to the correct operation.
- [ ] An unknown symbol for `get callgraph` and an invalid `direction` give a corrective string, not a thrown error.
- [ ] The fused schema's `symbol` and `query` descriptions are the shared descriptions above.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift` (uses `import FoundationModels` and `import Operations`, and `@testable import FoundationModelsCodeContext`): build `CodeContext<FakeLanguageServerConnection>` with `withTemporaryWorkspace`, `FakeEmbedder`, `FakeFileEventSource`, `fakeConnectionFactory` and `autoInstall: LspAutoInstall(isEnabled: false)` (see `CodeContextE2ETests.swift`; no project markers), write a small Swift file, `start()`, then call `tool.call(arguments: GeneratedContent(properties: ["op": "get symbol", "query": ...]))` for each operation and assert on the JSON. Add `defaultsMatchTheDirectEngineCall` (for `get callgraph` and `get blastradius`), `aliasesDispatchToTheCanonicalOperation` (the alias cases in the acceptance criteria), corrective-path tests for an unknown symbol and an invalid `direction`, and `sharedParameterDescriptionsAreTheSharedText` that reads `tool.parameters`.
- [ ] `swift build` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature