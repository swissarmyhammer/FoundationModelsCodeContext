---
assignees:
- claude-code
depends_on:
- 01M2JVXYZNVQJYZXY3F681TKFE
- 01M2JVWWAYY3VPYYH3XFAGWVZ8
position_column: todo
position_ordinal: '8580'
title: 'code_navigation tool: edit, call and diagnostics operations'
---
## What
Add the last five operations to the `code_navigation` tool. Follow ALL the rules in ^6bzj7va ("Rules for every operation in every tool task": `<Verb><Noun>Operation` names in files with the same name, `@Operation(verb:noun:description:)` with all three arguments, optional parameters as `value ?? CodeContextDefaults.<name>`, standard parameter aliases) and the position rules, shared `file` description and alias tables in ^681tkfe (0-based `line`/`character`, root-relative `file`).

The user decided that `path` and `file` are aliases. So `get diagnostics` uses the canonical parameter name `file` (with the standard aliases `path`, `filePath`, `filename`), not `path`.

- [ ] `Sources/FoundationModelsCodeContext/Tools/Navigation/GetCodeActionsOperation.swift`: `get`/`code_actions`: `file` (standard aliases), `startLine: Int` (aliases `fromLine`, `startRow`), `startCharacter: Int` (aliases `startColumn`, `fromColumn`), `endLine: Int` (aliases `toLine`, `endRow`), `endCharacter: Int` (aliases `endColumn`, `toColumn`), `only: [String]?` (aliases `kinds`, `actionKinds`) → `codeActions(...)` with `diagnostics: []`. The operation does not take diagnostics, because a `Diagnostic` is not a supported parameter type; say this in the doc comment.
- [ ] `Tools/Navigation/GetRenameEditsOperation.swift`: `get`/`rename_edits`: `file`, `line`, `character` (standard aliases), `newName: String` (aliases `name`, `to`, `newSymbol`) → `renameEdits(...)`. It returns the edits only and changes no file.
- [ ] `Tools/Navigation/GetInboundCallsOperation.swift` (`get`/`inbound_calls`: `file`, `line`, `character`) and `Tools/Navigation/SearchWorkspaceSymbolOperation.swift` (`search`/`workspace_symbol`: `query: String` (aliases `name`, `symbol`)).
- [ ] `Tools/Navigation/GetDiagnosticsOperation.swift`: `get`/`diagnostics`: `scope: String` (alias `mode`), `file: String?` (standard aliases, so `path` works), `sha: String?` (aliases `ref`, `commit`, `revision`, `range`), `severity: String?` (aliases `level`, `minSeverity`). Parse `scope` with `parseChoice(_:choices:parameter:)` and a table that maps `working`, `file` and `sha` to a private `enum ScopeKind { case working, file, sha }`. Then make the `DiagnosticsScope`: `.working` → `.workingTree`; `.file` → requires `file` (a relative path, absolute path or glob) → `.file(file)`; `.sha` → requires `sha` → `.sha(sha)`. Parse `severity` with the table `error` → `.error`, `warning` → `.warning`, `information` → `.information`, `hint` → `.hint`; a missing `severity` is `CodeContextDefaults.diagnosticsSeverity`. Call `diagnostics(scope:severity:includeDependents:settleWindow:hardTimeout:perReportCap:)` with the `CodeContextDefaults.diagnostics*` constants for the other arguments. A missing `file`/`sha`, an invalid name, and a git failure (`CodeContextError.spawnFailed`, for example `scope: "working"` in a directory that is not a git repository, or a bad `sha`) give a corrective string. Add the five operations to `CodeNavigationTool.operations()`.
- [ ] Write every doc comment, `@Guide` description and operation description in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `CodeNavigationTool.make` succeeds with ten operations: the five from ^681tkfe plus `get code_actions`, `get rename_edits`, `get inbound_calls`, `search workspace_symbol`, `get diagnostics`.
- [ ] `get diagnostics` gives a corrective string (not a thrown error) for: `scope: "file"` with no `file`; `scope: "sha"` with no `sha`; `scope: "bogus"` (the message lists `working, file, sha`); `severity: "loud"`; `scope: "working"` in a temporary directory that is not a git repository; `scope: "sha"` with a bad `sha`.
- [ ] `get diagnostics` with `scope: "file"` and a real file path returns a JSON `DiagnosticsReport`, both with the key `file` and with the alias key `path`.
- [ ] Aliases work: `get codeactions`, `get code_action`, `get inboundcalls`, `get callers`, `search symbol`, `get errors`, and `{"op": "get rename_edits", "name": ...}` dispatch to the correct operation.
- [ ] With no running language server, `get rename_edits` returns `canRename: false` and `search workspace_symbol` returns an empty list, as JSON.

## Tests
- [ ] Extend `Tests/FoundationModelsCodeContextTests/CodeNavigationToolTests.swift`: one test for each new operation against the same no-daemon workspace (`get diagnostics` success uses `scope: "file"`, one call with `file` and one with `path`); corrective tests for each case in the acceptance criteria; `newOperationAliasesDispatch` (the alias cases in the acceptance criteria); and `toolExposesTenOperations` that checks the op strings.
- [ ] `swift build` exits 0.
- [ ] `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exits 0.
- [ ] `swift test` exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tools #feature