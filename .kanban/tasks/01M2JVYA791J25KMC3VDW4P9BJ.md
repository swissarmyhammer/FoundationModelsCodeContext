---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2ktgctrvh21ghj614fmk595
  text: |-
    ### implement — changed
    - evidence: 7 files. New: Sources/FoundationModelsCodeContext/Tools/Navigation/{GetCodeActionsOperation,GetRenameEditsOperation,GetInboundCallsOperation,SearchWorkspaceSymbolOperation,GetDiagnosticsOperation}.swift. Changed: Tools/Navigation/CodeNavigationTool.swift, Tests/FoundationModelsCodeContextTests/CodeNavigationToolTests.swift.
    - Each new operation follows the pattern of the five position operations: `@Operation` with the three arguments, `@OperationParam` aliases, and `ToolSupport.outcome { }` for the engine call. The descriptions of `file`, `line` and `character` are the same words as the registered descriptions, so the fused schema keeps one description for each shared name.
    - `get code_actions` gives an empty list of diagnostics to the engine. A `Diagnostic` is not a supported parameter type, so the operation has no diagnostics parameter. The doc comment says this.
    - `get diagnostics` parses `scope` with `parseChoice` and a private table that maps `working`, `file` and `sha` to a private `enum ScopeKind`. It parses `severity` with `parseOptionalChoice` and a table of the four severity names. A missing `severity` is `CodeContextDefaults.diagnosticsSeverity`, and the other five arguments of the engine call are the `CodeContextDefaults.diagnostics*` constants.
    - The scope becomes a `DiagnosticsScope`: `.working` gives `.workingTree`; `.file` needs `file`; `.sha` needs `sha`. A scope with no `file` or no `sha` gives a corrective string, and the engine call does not run.
    - `CodeNavigationTool.operations()` now gives ten operations, and the description of the tool names the five new operations.
    - Discovery: the temporary workspace of the tool tests is not a git repository. `scope: "working"` and `scope: "sha"` there both fail in git, so each one gives the corrective string of `CodeContextError.spawnFailed`. The two tests use this fact.
    - `swift build --build-tests` exit 0. `swift test --filter CodeNavigationToolTests`: 10 tests in 1 suite pass. `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - next: /test (full suite).
  timestamp: 2026-09-16T00:40:13.400205+00:00
- actor: claude-code
  id: 01m2kth8q181400fkf9brgk6zt
  text: |-
    ### test — green
    - evidence: `swift test` exit 0 — 604 tests in 53 suites passed, 0 failed, 0 skipped. The full log has no `error:` line and no `warning:` line. The test time was 5.0 seconds.
    - `swift test --filter CodeNavigationToolTests`: 10 tests in 1 suite pass, each run less than 0.2 seconds.
    - `swift format lint -r --strict Sources Tests Examples IntegrationTests Package.swift` exit 0.
    - `swift build --package-path IntegrationTests --build-tests` exit 0, with 0 errors and 0 warnings in the log.
    - The suite count is 5 tests more than the 599 tests of the last task, because this task adds 5 tests.
    - next: /commit.
  timestamp: 2026-09-16T00:40:41.953797+00:00
depends_on:
- 01M2JVXYZNVQJYZXY3F681TKFE
- 01M2JVWWAYY3VPYYH3XFAGWVZ8
position_column: doing
position_ordinal: '80'
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