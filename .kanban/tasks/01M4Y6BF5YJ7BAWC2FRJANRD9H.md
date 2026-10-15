---
assignees:
- claude-code
depends_on:
- 01M4Y6B1V0P9AVNN12M4TCWCWP
position_column: todo
position_ordinal: '8180'
title: 'get blastradius: add the scopes working, file and sha to the code_search tool'
---
## What

Give the `get blastradius` operation of `code_search` the same `scope` parameter as `get diagnostics`. The scopes are `working`, `file` and `sha`. The engine work is in the task ^4tcwcwp. This task depends on that task.

Approach:
- `Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift`:
  - Add `func blastRadius(scope: DiagnosticsScope, maxHops: Int) async throws -> BlastRadius` to the protocol.
  - `extension CodeContext: CodeContextOperating {}` (line 103) is the only type that conforms to it.
- `Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift`:
  - Add an optional `scope: String?` parameter with the alias `mode`, and an optional `sha: String?` parameter with the aliases `ref`, `commit`, `revision` and `range`. Copy the `@Guide` text and the `.anyOf(["working", "file", "sha"])` from `GetDiagnosticsOperation.swift`.
  - Make `file` optional (`String?`).
  - Parse `scope` with `ToolSupport.parseChoice`, in the same way as `GetDiagnosticsOperation.parsedScope()` / `reportScope(of:)`.
  - Rules:
    - When `scope` is `nil` or `file`, and `file` has no glob characters, call the current `blastRadius(file:symbol:maxHops:)`. This keeps the current calls unchanged.
    - When `scope` is `file` and `file` is a glob, call `blastRadius(scope: .file(file), maxHops:)`.
    - When `scope` is `working`, call `blastRadius(scope: .workingTree, maxHops:)`.
    - When `scope` is `sha`, call `blastRadius(scope: .sha(sha), maxHops:)`.
  - Give a corrective message when the call has no `file` for the scope `file` (or for no scope), or no `sha` for the scope `sha`. Also give a corrective message when the call gives `symbol` with the scope `working` or `sha`.
  - Update the `@Operation` description so that it names the scopes.
- `docs/tools.md`: update the `get blastradius` row near line 71, and the parameter rows near lines 90–92. Add the rows for `scope` and `sha`, and change `file` to "only for the scope file".

Subtasks:
- [ ] Add `blastRadius(scope:maxHops:)` to `CodeContextOperating`.
- [ ] Add `scope` and `sha` to `GetBlastradiusOperation`, and make `file` optional. Add the corrective messages.
- [ ] Update `docs/tools.md`.

## Acceptance Criteria
- [ ] `{"op": "get blastradius", "file": "<f>", "symbol": "helper"}` gives the same result as before this change.
- [ ] `{"op": "get blastradius", "scope": "working"}` gives the blast radius of the files that the working tree changes.
- [ ] `{"op": "get blastradius", "scope": "sha", "sha": "HEAD~1"}` gives the blast radius of the files that the last commit changes.
- [ ] A call with the scope `sha` and no `sha`, a call with no scope and no `file`, and a call with the scope `working` and a `symbol` each give a corrective message. They do not throw.
- [ ] `CodeContextTools.operationNames` does not change, and `docs/tools.md` shows the new parameters.

## Tests
- [ ] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift`: add tests that call the tool with `GeneratedContent`, in the same way as the current `get blastradius` tests near lines 157 and 184:
  - The scope `working` in a temporary git repository, where the callee file has a change.
  - The scope `sha` after a commit that changes the callee file.
  - Each of the three corrective-message cases.
- [ ] Keep the current `get blastradius` tests of `CodeSearchToolTests.swift`. Do not change them, and they must pass.
- [ ] If a test compares the tool schema text (for example the `@Guide` text near line 42), update the expected text.
- [ ] Run `swift test`. All the tests must pass, with no new warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.