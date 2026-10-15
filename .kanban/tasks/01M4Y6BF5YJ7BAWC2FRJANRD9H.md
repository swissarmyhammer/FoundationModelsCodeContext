---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zbvbykg65zssj1t7hcpkqy
  text: |-
    Research done.
    - `CodeContext.blastRadius(scope:maxHops:)` exists (commit 32fff17). Only `CodeContext` conforms to `CodeContextOperating`.
    - `GetDiagnosticsOperation` is in Tools/Navigation, not Tools/Search. Its private `ScopeKind` enum and its scope table are the parts that `get blastradius` also needs. To prevent a copy, I move them to one shared internal type in Tools/, and the two operations use it.
    - The scope `sha` with a single ref `X` resolves to `X..HEAD`. Thus `HEAD~1` gives the files of the last commit.
    - The glob test of `GlobExpansion.expand` is `"*?["`. I move that test to one helper of `GlobExpansion`, and the operation uses the same helper.
    - In `code_search`, the `file` parameter is shared by `list symbol`, `get blastradius` and `find duplicates`. The fused schema keeps one description, and a test checks it. Thus the `@Guide` text of `file` does not change. The scope description tells the model that the scope `file` accepts a glob.
    - Decision for a case that the card does not name: no scope is the same as the scope `file`. A glob with a `symbol` gives a corrective message, because the scope call has no symbol, and the symbol must not be dropped silently.
  timestamp: 2026-10-15T08:46:21.139897+00:00
- actor: claude-code
  id: 01m4zc5ny3kj5gdxhk7s0w5kpj
  text: |-
    Implementation landed. TDD: the new tool-call tests failed first ("Missing required parameter(s): file.", and the glob went to `blastRadius(file:)`), then passed after the change.

    What changed:
    - New `Tools/ToolScopeKind.swift`: the shared scope names, the choice table (from `ToolSupport.choiceTable`), and the missing-`sha` message with `shaScope(_:)`. `GetDiagnosticsOperation` now uses it. Its private `ScopeKind` enum and its scope table are removed. Its behavior does not change.
    - `GlobExpansion.isGlob(_:)` in `DiagnosticsScope.swift`. `expand(pattern:rootDirectory:)` and `GetBlastradiusOperation` use it. A direct unit test is in `DiagnosticsTests`. That test passed at the first run, because the helper is an extraction of existing behavior.
    - `CodeContextOperating.blastRadius(scope:maxHops:)`.
    - `GetBlastradiusOperation`: `scope` (alias `mode`), `sha` (aliases `ref`, `commit`, `revision`, `range`), `file` is optional. Corrective messages for: no `file`, no `sha`, a name that is not a scope, and a `symbol` with the scope `working`, the scope `sha` or a glob.
    - `docs/tools.md`: the op row, the parameter rows, and the `file` rule line.
    - Tests: `ToolTest.expectEachCorrectiveMessage(_:on:)` in `ToolTestSupport.swift`. In `CodeSearchToolTests`, a shared git fixture helper `withChangedScopeFixture(commitsTheChange:_:)`. The engine test from ^4tcwcwp uses this helper now. Its assertions did not change.

    Differences from the card text, for review:
    - The `@Guide` text of `scope` says "The scope of the change:" and not "The scope to diagnose:". The word "diagnose" is not correct for a blast radius. The rest of the text and the `.anyOf` are the same as in `get diagnostics`.
    - The `@Guide` text of `file` did not change. `code_search` fuses one description for `file` across `list symbol`, `get blastradius` and `find duplicates`, and `sharedParameterDescriptionsAreTheSharedText` checks it. The `scope` description and the op description tell the model that the scope `file` accepts a glob.
    - No scope with a glob `file` is the same as the scope `file` with a glob. A glob with a `symbol` gives a corrective message.

    Mistake: I ran `sed -i` one time to replace a test constant name. The shell rules say to edit files only with the file tool. The result was correct, and I checked the diff.

    Full suite: `swift test` 852 tests in 78 suites passed. The one warning is "missing creator for mutated node ... mlx-swift_Cmlx.bundle" from SwiftPM. It was also in the RED run before the change, so it is not new.
  timestamp: 2026-10-15T08:51:59.043189+00:00
- actor: claude-code
  id: 01m4zc5s0h4t1pa6qsw04n4vfv
  text: |-
    ### implement — changed
    - evidence: 10 files. New: Sources/FoundationModelsCodeContext/Tools/ToolScopeKind.swift. Changed: Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift, Sources/FoundationModelsCodeContext/Tools/CodeContextOperating.swift, Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift, Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift, Tests/FoundationModelsCodeContextTests/DiagnosticsTests.swift, docs/tools.md. `swift test`: 852 tests in 78 suites passed, 0 failures.
    - next: /review
  timestamp: 2026-10-15T08:52:02.193449+00:00
- actor: claude-code
  id: 01m4zc5xbzafxmr0ma7nby0h01
  text: 'Correction to the step record above: the count is 9 source and doc files (1 new, 8 changed), not 10. The file list in that record is correct.'
  timestamp: 2026-10-15T08:52:06.655488+00:00
- actor: claude-code
  id: 01m4zc7j35sq6kk7ptfc586mz5
  text: |-
    ### test — green
    - evidence: swift test — 852 tests in 78 suites passed, 0 failed, 0 skipped; only warning is the known dependency line "missing creator for mutated node ... mlx-swift_Cmlx.bundle"
    - next: review
  timestamp: 2026-10-15T08:53:00.645006+00:00
- actor: claude-code
  id: 01m4zc81mvnj3gtmbs0tjk55d7
  text: |-
    ### commit — changed
    - evidence: d53101d feat(blast-radius): add the scopes working, file and sha to the code_search tool ^janrd9h
    - next: review
  timestamp: 2026-10-15T08:53:16.571694+00:00
- actor: claude-code
  id: 01m4zcdcn2k72mq5faqbh0evcd
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d53101d): 3 findings (3 confirmed, 3 refuted) — Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift:122, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:425, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift:132. docs/tools.md had no matching validator.
    - next: Correct the 3 open items in "## Review Findings (2026-10-15 03:53)". The task stays in review.
  timestamp: 2026-10-15T08:56:11.682587+00:00
- actor: claude-code
  id: 01m4zcdtp2wjbrs1m5fv9b4jnt
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files
    - test: green — swift test, 852 tests in 78 suites passed
    - commit: d53101d
    - review: findings — Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift:122, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:425, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift:132
  timestamp: 2026-10-15T08:56:26.050366+00:00
- actor: claude-code
  id: 01m4zcny43eray21m297snefx9
  text: |-
    Review findings of 2026-10-15 03:53 are corrected. TDD: three new unit tests in ToolSupportTests failed first ("value of type 'ToolScopeKind' has no member 'scope'"), then passed.

    What changed:
    - Finding 1 (duplication): `ToolScopeKind.scope(sha:) -> ChoiceParse<DiagnosticsScope>?` is the one shared map of the kinds `working` and `sha`. It gives `nil` for the kind `file`, because each operation reads `file` and gives its own corrective message. `GetDiagnosticsOperation.reportScope(of:)` and `GetBlastradiusOperation.target(of:)` call it. The `.file` branch and the `symbol` check stay in each operation. `ToolScopeKind.shaScope(_:)` is removed, because the new function holds its body and it has no other caller.
    - Finding 2 (reuse): `GetBlastradiusOperation.missingFileMessage` is internal, and the test uses it. The same cause was in two more places in CodeSearchToolTests: the copy of the `sha` message, and three copies of the `symbol` message. The test now uses `ToolScopeKind.missingShaMessage`, and a new internal `GetBlastradiusOperation.unusedSymbolMessage(for:)` that the operation also uses.
    - Finding 3 (reuse): `ToolTest.expectEachCall` has a `text:` conversion parameter. Its default keeps the raw output. `expectEachCorrectiveMessage` calls `expectEachCall(calls, on: tool, text: decodedString)`, so the two helpers have one loop.

    Not changed: the exact-text checks of the messages from `ToolSupport.parseChoice` (`sideways`, `everything`). That text comes from a format function, not from a copied constant, and ToolSupportTests checks the format.

    Full suite: `swift test` gave 855 tests in 78 suites passed, 0 failed. The only warning is the known SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle".
  timestamp: 2026-10-15T09:00:51.715406+00:00
- actor: claude-code
  id: 01m4zcp0wf7nsp1rav1cncba0b
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/Tools/ToolScopeKind.swift, Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift, Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift, Tests/FoundationModelsCodeContextTests/ToolSupportTests.swift, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift. `swift test`: 855 tests in 78 suites passed, 0 failed. The 3 findings are checked.
    - next: /review
  timestamp: 2026-10-15T09:00:54.543108+00:00
- actor: claude-code
  id: 01m4zcqka9vfexwj9b6ws19reh
  text: |-
    ### test — green
    - evidence: swift test — 855 tests in 78 suites passed, 0 failed, 0 skipped. Only warning: the known dependency line "missing creator for mutated node ... mlx-swift_Cmlx.bundle". No warning in code this repository owns.
    - next: review
  timestamp: 2026-10-15T09:01:46.185613+00:00
- actor: claude-code
  id: 01m4zcqz4r0qgh6wt3tjdbrjvj
  text: |-
    ### commit — changed
    - evidence: 2bf2a3b refactor(blast-radius): share one scope mapping and one copy of each message ^janrd9h
    - next: review iteration 2
  timestamp: 2026-10-15T09:01:58.296817+00:00
- actor: claude-code
  id: 01m4zcxcxe8bv8pd4s38d5sm42
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (2bf2a3b), 2 findings (2 confirmed, 2 refuted) — Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift:114, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:453. All 3 items of "Review Findings (2026-10-15 03:53)" are checked.
    - next: fix the 2 open items of "Review Findings (2026-10-15 04:02)". The task stays in review.

    ```
    step: review
    outcome: findings
    evidence: 2 findings — Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift:114, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:453
    task: ^janrd9h
    ```
  timestamp: 2026-10-15T09:04:56.238058+00:00
- actor: claude-code
  id: 01m4zcxt4k2cw7wxqbyd5rm6e8
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 6 files
    - test: green — swift test, 855 tests in 78 suites passed
    - commit: 2bf2a3b
    - review: findings — Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift:114, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:453
  timestamp: 2026-10-15T09:05:09.779344+00:00
- actor: claude-code
  id: 01m4zd7fzej0m3wnsb3z5x92st
  text: |-
    Review findings of 2026-10-15 04:02 are corrected. TDD: the new test `theDiagnosticsAndTheBlastRadiusGiveOneMessageForTheScopeFileWithNoFile` failed first (the two texts were different), then passed after the change.

    What changed:
    - Finding 1 (invariant-propagation): `ToolScopeKind.missingFileMessage` is the one copy of the `file` message, next to `missingShaMessage`. `GetDiagnosticsOperation.reportScope(of:)` and `GetBlastradiusOperation.fileTarget()` use it. `GetBlastradiusOperation.missingFileMessage` and the inline diagnostics text are removed.
      - The one wording: "Give the parameter `file` for the scope `file`. It accepts a path relative to the workspace root or a glob. For a different set of files, give the scope `working` or `sha`."
      - Why this wording: `blastRadius(file:)` does not accept an absolute path (the store keys are relative paths). Thus the shared text does not say "an absolute path". The `@Guide` text and `docs/tools.md` still tell the model that `get diagnostics` accepts an absolute path. The first sentence did not change, so the old `hasPrefix` check in `theDiagnosticsScopeAndSeverityGiveTheCorrectiveOutput` still passes.
      - New tests in CodeNavigationToolTests: `theDiagnosticsScopeFileWithNoFileNamesTheParameterAndTheScope` (key words) and `theDiagnosticsAndTheBlastRadiusGiveOneMessageForTheScopeFileWithNoFile` (the two operations give the same text).
    - Finding 2 (no-test-cheating): no test in this change compares an output with a production constant now. The tests assert the key words of each message: the parameter name and the scope name, for example "parameter `symbol`" and "scope `working`".
      - `ToolTest.CorrectiveCall` holds the arguments and the key words. `ToolTest.expectEachCorrectiveMessage` decodes the message and calls the new `ToolTest.expectKeyWords(_:in:context:sourceLocation:)`.
      - `expectEachCall` and `expectEachCorrectiveMessage` share one loop: the private generic `checkEachOutput(of:on:_:)`. The `text:` parameter of `expectEachCall` is removed, because no caller used it after this change.
      - Same cause, fixed in the whole change: `ToolSupportTests.theScopeKindShaWithNoShaGivesTheCorrectiveMessage` compared with `ToolScopeKind.missingShaMessage`. It now asserts the key words.
      - `GetBlastradiusOperation.unusedSymbolMessage(for:)` is private again, because no test uses it.
    - Finding 1 also says "use it ... in the tests". The user instruction for finding 2 says the tests must not compare with a production constant. I followed the user instruction: the tests assert key words, and no test reads `missingFileMessage`.

    Not changed: `anUnknownSymbolForGetCallgraphGivesACorrectiveString` compares with `ToolSupport.correctiveMessage(for:)`. That test is older than this change.

    Full suite: `swift test` gave 857 tests in 78 suites passed, 0 failed. The only warning is the known SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle".
  timestamp: 2026-10-15T09:10:27.054516+00:00
- actor: claude-code
  id: 01m4zd7km8em3n5k1qe9dd2pme
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/Tools/ToolScopeKind.swift, Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift, Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift, Tests/FoundationModelsCodeContextTests/CodeNavigationToolTests.swift, Tests/FoundationModelsCodeContextTests/ToolSupportTests.swift. `swift test`: 857 tests in 78 suites passed, 0 failed. The 2 findings of 2026-10-15 04:02 are checked.
    - next: /review

    ```
    step: implement
    outcome: changed
    evidence: 7 files (3 Sources, 4 Tests); swift test — 857 tests in 78 suites passed, 0 failed
    task: ^janrd9h
    ```
  timestamp: 2026-10-15T09:10:30.792892+00:00
- actor: claude-code
  id: 01m4zd94e92pw202h5aq81mx1n
  text: |-
    ### test — green
    - evidence: swift test — 857 tests in 78 suites passed, 0 failed, 0 skipped. The only warning is the known dependency line about mlx-swift_Cmlx.bundle. No warning from code that this repository owns.
    - next: review
  timestamp: 2026-10-15T09:11:20.777528+00:00
- actor: claude-code
  id: 01m4zd9jfsp3tmbrcks4hxxwb4
  text: |-
    ### commit — changed
    - evidence: c791725 refactor(diagnostics): share one missing file message and test its key words ^janrd9h
    - next: review
  timestamp: 2026-10-15T09:11:35.161937+00:00
- actor: claude-code
  id: 01m4zdda8ygxzp5js6dezqe5s3
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c791725), 7 files reviewed, 0 findings (0 confirmed, 2 refuted). All prior findings in "## Review Findings (2026-10-15 03:53)" and "## Review Findings (2026-10-15 04:02)" are checked. No conflict found.
    - next: none. The task is in done.

    ```
    step: review
    outcome: clean
    evidence: 0 findings
    task: ^janrd9h
    ```
  timestamp: 2026-10-15T09:13:37.822895+00:00
- actor: claude-code
  id: 01m4zddkcqy4mjgbwwpjjpm1zd
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 7 files
    - test: green — swift test, 857 tests in 78 suites passed
    - commit: c791725
    - review: clean — 0 findings
  timestamp: 2026-10-15T09:13:47.159455+00:00
depends_on:
- 01M4Y6B1V0P9AVNN12M4TCWCWP
position_column: done
position_ordinal: df80
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
- [x] Add `blastRadius(scope:maxHops:)` to `CodeContextOperating`.
- [x] Add `scope` and `sha` to `GetBlastradiusOperation`, and make `file` optional. Add the corrective messages.
- [x] Update `docs/tools.md`.

## Acceptance Criteria
- [x] `{"op": "get blastradius", "file": "<f>", "symbol": "helper"}` gives the same result as before this change.
- [x] `{"op": "get blastradius", "scope": "working"}` gives the blast radius of the files that the working tree changes.
- [x] `{"op": "get blastradius", "scope": "sha", "sha": "HEAD~1"}` gives the blast radius of the files that the last commit changes.
- [x] A call with the scope `sha` and no `sha`, a call with no scope and no `file`, and a call with the scope `working` and a `symbol` each give a corrective message. They do not throw.
- [x] `CodeContextTools.operationNames` does not change, and `docs/tools.md` shows the new parameters.

## Tests
- [x] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift`: add tests that call the tool with `GeneratedContent`, in the same way as the current `get blastradius` tests near lines 157 and 184:
  - The scope `working` in a temporary git repository, where the callee file has a change.
  - The scope `sha` after a commit that changes the callee file.
  - Each of the three corrective-message cases.
- [x] Keep the current `get blastradius` tests of `CodeSearchToolTests.swift`. Do not change them, and they must pass.
- [x] If a test compares the tool schema text (for example the `@Guide` text near line 42), update the expected text.
- [x] Run `swift test`. All the tests must pass, with no new warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-10-15 03:53)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `docs/tools.md` — no validator matches this file

- [x] `Sources/FoundationModelsCodeContext/Tools/Search/GetBlastradiusOperation.swift:122` `duplication/duplication` — The mapping from a scope kind to a DiagnosticsScope is written twice. The `.working` and `.sha` branches of `target(of:)` repeat the mapping that `reportScope(of:)` in GetDiagnosticsOperation.swift already holds (`.working` gives `.workingTree`, `.sha` gives `ToolScopeKind.shaScope(sha)`). If one operation changes how a scope kind maps, the other can drift out of sync. Move the kind-to-scope mapping for `.working` and `.sha` into one shared function on `ToolScopeKind`, for example `ToolScopeKind.scope(of:sha:)` that returns `ChoiceParse<DiagnosticsScope>`. Call it from both `reportScope(of:)` and `target(of:)`. Keep the `.file` branch and the `symbol` check in each operation, because their corrective messages differ.
- [x] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:425` `reuse/reuse` — The test copies the text of the private `missingFileMessage` constant from `GetBlastradiusOperation`. If the production text changes, the copy must be changed too, or the test fails for the wrong reason. If the test should check the message text, keep one exact-text check. Otherwise make the production constant visible to tests with `@testable` access (internal, not private), and use it from the test. Do not keep two copies of the same text.
- [x] `Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift:132` `reuse/reuse` — `expectEachCorrectiveMessage` repeats the loop of `expectEachCall` line for line. The only difference is that the output is decoded from one JSON string before the comparison. This is a near-match that was not extended. Give `expectEachCall` a decode step, or a second parameter that takes the output-to-text conversion. Use one loop for both helpers. The decode step can default to the raw output.

## Review Findings (2026-10-15 04:02)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsCodeContext/Tools/Navigation/GetDiagnosticsOperation.swift:114` `completeness/invariant-propagation` — The corrective message for scope `file` with no `file` parameter is still written inline in `reportScope(of:)`. The commit states that each corrective message keeps one copy. The sibling copy in `GetBlastradiusOperation.missingFileMessage` is a separate text, and the two texts already differ. The diagnostics copy says 'an absolute path or a glob'. The blast-radius copy says 'or a glob' only. A later edit to one copy does not reach the other. Move the `file` corrective message into one shared place, for example a static on `ToolScopeKind` next to `missingShaMessage`. Use it in both operations and in the tests. Choose one wording first, because the two copies disagree. Add a test for the diagnostics `file` message, because no test in this change asserts it.
- [x] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift:453` `test-integrity/no-test-cheating` — The expected text is taken from the production function `GetBlastradiusOperation.unusedSymbolMessage(for:)`, so the assertion compares the function output with itself. The test cannot fail if the wording of the message changes or breaks. The same pattern is used at lines 430, 434, 438, 459 and 465. Keep one literal copy of each corrective message in the test, as the earlier version of this test did, and compare the tool output with that literal. Keep the shared constant only for production use. Another option is to assert the key words of each message, such as the parameter name and the scope name, so that a change in wording still fails.
