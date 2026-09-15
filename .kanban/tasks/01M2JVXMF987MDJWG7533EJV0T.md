---
assignees:
- claude-code
depends_on:
- 01M2JVXAABQCS4GTBBB6BZJ7VA
- 01M2JVWWAYY3VPYYH3XFAGWVZ8
position_column: todo
position_ordinal: '8380'
title: 'code_search tool: text, similarity and AST operations'
---
## What
Add the last four operations to the `code_search` tool. Follow ALL the rules in ^6bzj7va ("Rules for every operation in every tool task": `<Verb><Noun>Operation` names in files with the same name, `@Operation(verb:noun:description:)` with all three arguments, optional parameters as `value ?? CodeContextDefaults.<name>`, shared parameter names keep one type and the shared description, standard parameter aliases, enum-like strings use `parseChoice(_:choices:parameter:)`, recoverable errors give `ToolOutcome.corrective`). The `code_search` verb and noun alias tables are in ^6bzj7va.

Name collisions to avoid: the target already has the files `Ops/GrepCode.swift`, `Ops/SearchCode.swift`, `Ops/FindDuplicates.swift`, `Ops/QueryAST.swift` and the types `public enum GrepCode` and `public enum SearchCode`. Files or structs named `GrepCode`, `SearchCode` or `FindDuplicates` stop the build. Use the names below.

- [ ] `Sources/FoundationModelsCodeContext/Tools/Search/GrepCodeOperation.swift`: `struct GrepCodeOperation`, `@Operation(verb: "grep", noun: "code", description: "...")`: `pattern: String` (aliases `regex`, `query`), `languages: [String]?` (aliases `extensions`, `langs`; extensions without the dot), `filePattern: String?` (aliases `glob`, `include`; POSIX glob), `maxResults: Int?` (standard aliases) → `grepCode(pattern:languages: languages ?? CodeContextDefaults.grepLanguages, filePattern:maxResults: maxResults ?? CodeContextDefaults.maxQueryResults)`. An invalid regex gives a corrective string.
- [ ] `Tools/Search/SearchCodeOperation.swift`: `struct SearchCodeOperation`, `search`/`code`: `query: String` (aliases `text`, `q`), `topK: Int?` (aliases `limit`, `maxResults`, `k`) → `searchCode(query:topK: topK ?? CodeContextDefaults.searchTopK, weights: CodeContextDefaults.searchWeights)`.
- [ ] `Tools/Search/FindDuplicatesOperation.swift`: `struct FindDuplicatesOperation`, `find`/`duplicates`: `file: String?` (standard aliases), `minSimilarity: Double?` (aliases `threshold`, `similarity`), `minChunkBytes: Int?` (aliases `minBytes`, `minSize`), `maxPerChunk: Int?` (alias `perChunk`) → `findDuplicates(...)` with the `CodeContextDefaults.duplicate*` constants for missing values.
- [ ] `Tools/Search/QueryAstOperation.swift`: `struct QueryAstOperation`, `query`/`ast`: `language: String` (alias `lang`), `astQuery: String` (aliases `query`, `sexp`, `pattern`; a tree-sitter S-expression; the canonical name is not `query`, because `query` already means a symbol or text query in this tool), `maxResults: Int?` (standard aliases) → `queryAST(language:query:options: QueryASTOptions(maxResults: maxResults ?? CodeContextDefaults.queryASTMaxResults))`. An unknown language or an invalid query gives a corrective string. Add the four operations to `CodeSearchTool.operations()`.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `CodeSearchTool.make` succeeds with nine operations: the five from ^6bzj7va plus `grep code`, `search code`, `find duplicates`, `query ast`.
- [ ] `find Sources/FoundationModelsCodeContext -name '*.swift' -exec basename {} \; | sort | uniq -d` gives no output (no two files have the same name).
- [ ] The fused schema has a parameter `astQuery`, and `query`, `file` and `maxResults` have one type each.
- [ ] `search code` and `find duplicates` called with no optional parameters return the same JSON as the direct engine calls with no arguments.
- [ ] Aliases work: `{"op": "query ast", "query": ...}` dispatches the S-expression to `astQuery`; `{"op": "grep code", "regex": ...}`, `{"op": "search code", "limit": 5}`, `find dupes` and `search source` dispatch to the correct operation.
- [ ] An invalid grep regex and an invalid AST query give corrective strings.

## Tests
- [ ] Extend `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift`: one success test for each new operation against an indexed temporary workspace (`FakeEmbedder` gives embeddings for `search code` and `find duplicates`), `newOperationDefaultsMatchTheDirectEngineCall`, `newOperationAliasesDispatch` (the alias cases in the acceptance criteria), corrective tests for an invalid regex and an invalid AST query, `toolExposesNineOperations` that checks the op strings, and `fusedSchemaHasAstQueryParameter`.
- [ ] `swift build` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature