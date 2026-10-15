---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4zb35cgk5j2pd69tddwk1jz
  text: |-
    Research done.
    - `BlastRadiusOps.traverseInbound` starts `visited` with all the roots. Thus a root that a different root calls is not counted. The new function only collects and deduplicates the roots and then calls the same walk.
    - `DiagnosticsScopeResolver.resolvePaths` filters with `isDiagnosableExtension` (LSP modules only). Markdown (`md`) is an indexed tree-sitter extension with no LSP, and `txt` is not an indexed extension. The tests use these two extensions.
    - Tree-sitter resolves a cross-file callee only against the chunks that are already in the index. `Store.drainTsDirty` gives paths in path order. Thus the CodeContext test names the callee file `Callee.swift`, which sorts before `Caller.swift`.
    - `Store` puts its database in `.code-context/` with its own `.gitignore` of `*`. Thus `git status` does not show the index files.
    - The git helpers (`runGit`, `initRepo`, `commitAll`) are private in `DiagnosticsTests`. The new CodeContext test in `CodeSearchToolTests` also needs git. Plan: move these helpers to one shared test helper, so that the two files do not copy them.
    - `ToolTest.withStartedContext` writes one fixture file in its own temporary workspace. Plan: add a variant that starts a `CodeContext` on a root that the test prepared, and make the current helper call it.
  timestamp: 2026-10-15T08:33:07.984660+00:00
- actor: claude-code
  id: 01m4zbgvw564xvw7gcg0tn1n2v
  text: |-
    Implementation landed (TDD).
    - RED: one `swift build --build-tests` run failed because `keepsOnlyDiagnosable` and the new `blastRadius` APIs did not exist.
    - GREEN: the 5 new tests passed in one filtered run. The full `swift test` run gave 844 tests in 78 suites, all passed. The only warning is the build-system warning about the `mlx-swift_Cmlx.bundle` node. That warning was there before this change.
    - Production: `DiagnosticsScopeResolver.resolvePaths` has `keepsOnlyDiagnosable: Bool = true`. It uses `diagnosableExtensions` (LSP modules) or `indexedExtensions` (all of `Languages.all`). The private `isDiagnosableExtension`/`knownExtensions` became `hasExtension(_:in:)` and the two sets. `BlastRadiusOps.blastRadius(store:files:maxHops:)` collects the roots of each file with `findRoots(db:filePath:symbolName: nil)`, removes duplicate roots, and does one `traverseInbound` walk. `CodeContext.blastRadius(scope:maxHops:)` is next to `blastRadius(file:symbol:maxHops:)`.
    - Test helpers: the git helpers moved from `DiagnosticsTests` (private) to the new `Tests/FoundationModelsCodeContextTests/GitTestSupport.swift` (`GitFixture`), so that `CodeSearchToolTests` does not copy them. `ToolTest.withStartedContext(rootDirectory:embeddingDimension:_:)` is new. The old `withStartedContext(source:file:...)` calls it.
    - Not in scope, as the card says: `CodeContextOperating` and the `code_search` tool do not have the scope variant yet. The follow-up card "get blastradius: add the scopes working, file and sha to the code_search tool" holds that work.
  timestamp: 2026-10-15T08:40:36.997699+00:00
- actor: claude-code
  id: 01m4zbh7x7xf02zaebrmn8shfe
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift, Sources/FoundationModelsCodeContext/Ops/BlastRadius.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/CallGraphTests.swift, Tests/FoundationModelsCodeContextTests/DiagnosticsTests.swift, Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift, Tests/FoundationModelsCodeContextTests/ToolTestSupport.swift, Tests/FoundationModelsCodeContextTests/GitTestSupport.swift (new); `swift test`: 844 tests in 78 suites passed, 0 failed, no new warnings
    - next: /review (task stays in doing)
  timestamp: 2026-10-15T08:40:49.319849+00:00
- actor: claude-code
  id: 01m4zbjtmjbymbqsd9rcwzypj8
  text: |-
    ### test — green
    - evidence: swift test — 844 tests in 78 suites passed, 0 failed, 0 skipped. No compiler warning in code that this repository owns.
    - note: One build-system line shows "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It comes from the mlx-swift dependency, not from code in this repository.
    - next: review
  timestamp: 2026-10-15T08:41:41.266206+00:00
- actor: claude-code
  id: 01m4zbk84sfk0q882qjfswg2sg
  text: |-
    ### commit — changed
    - evidence: e6705c7 feat(blast-radius): find the impact of a set of changed files ^4tcwcwp
    - next: review
  timestamp: 2026-10-15T08:41:55.097987+00:00
- actor: claude-code
  id: 01m4zbpyeme4hs9kw3gs8x64ck
  text: |-
    ### review — clean
    - evidence: 0 findings. Scope: `review sha HEAD~1..HEAD` (commit 32fff17). The engine reviewed 8 files and refuted 1 candidate. It did not review 10 `.kanban/` files because of `.reviewignore`. Note: the kanban comment in the commit message gives sha e6705c7. The real commit is 32fff17.
    - next: none. The task is in done.

    ```
    step: review
    outcome: clean
    evidence: 0 findings
    task: ^4tcwcwp
    ```
  timestamp: 2026-10-15T08:43:56.244599+00:00
- actor: claude-code
  id: 01m4zbq561kdbbr8akmc28wsp7
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 files
    - test: green — swift test, 844 tests in 78 suites passed
    - commit: 32fff17
    - review: clean — 0 findings
  timestamp: 2026-10-15T08:44:03.137836+00:00
position_column: done
position_ordinal: de80
title: 'Blast radius: find the impact of a set of changed files (engine)'
---
## What

At the moment, `BlastRadiusOps.blastRadius(store:file:symbol:maxHops:)` starts from one file only. Add an engine operation that starts from a scope: the working tree, a file or a glob, or the files that a commit changes. The scope is the same as the scope of `get diagnostics`. Then a model can ask "what can this change affect?" This idea comes from the pull-request impact feature of Graphicle.

This task changes only the engine and the public API of `CodeContext`. A different task changes the `code_search` tool and depends on this task.

Approach:
- `Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift`:
  - Keep the public name `DiagnosticsScope`.
  - At the moment, `DiagnosticsScopeResolver.resolvePaths(scope:rootDirectory:)` keeps only the extensions that have a language server (`isDiagnosableExtension`). Blast radius must keep each indexed extension (`Languages.all.flatMap { $0.fileExtensions }`), because tree-sitter also makes call edges.
  - Add a parameter for this filter, for example `keepsOnlyDiagnosable: Bool = true`. The default keeps the behavior of `get diagnostics`.
- `Sources/FoundationModelsCodeContext/Ops/BlastRadius.swift`:
  - Add `BlastRadiusOps.blastRadius(store:files:maxHops:)`.
  - Collect the roots of each file with the private `findRoots(db:filePath:symbolName:)`, with `symbolName: nil`. Remove the duplicate roots. Then do one `traverseInbound(db:roots:maxHops:)` walk.
  - Do not count a root as an affected symbol, even when a different root calls it. `visited` already starts with all the roots, thus this is the current behavior.
  - When a file has no indexed symbols, do not throw. When no file has a symbol, return an empty `BlastRadius`.
  - Keep the current `blastRadius(store:file:symbol:maxHops:)` unchanged. `Diagnose.swift` calls it.
- `Sources/FoundationModelsCodeContext/CodeContext.swift`:
  - Add `public func blastRadius(scope: DiagnosticsScope, maxHops: Int = CodeContextDefaults.blastRadiusMaxHops) async throws -> BlastRadius`.
  - It resolves the scope with `DiagnosticsScopeResolver.resolvePaths(scope:rootDirectory:keepsOnlyDiagnosable: false)` and then calls the new `BlastRadiusOps` function.
  - Put it next to the current `blastRadius(file:symbol:maxHops:)`, near line 548.

Subtasks:
- [x] Add the extension-filter parameter to `DiagnosticsScopeResolver.resolvePaths`.
- [x] Add `BlastRadiusOps.blastRadius(store:files:maxHops:)`.
- [x] Add `CodeContext.blastRadius(scope:maxHops:)`.

## Acceptance Criteria
- [x] `BlastRadiusOps.blastRadius(store:files:maxHops:)` with two files gives the roots of the two files. It also gives the inbound callers of the two files in one hop list, with each symbol and each file counted one time only.
- [x] A root that calls a different root is not in `hops`.
- [x] A list of files that has no indexed symbols gives an empty `BlastRadius`, and the function does not throw.
- [x] `resolvePaths(scope:rootDirectory:keepsOnlyDiagnosable: false)` keeps a changed `.md` file. The default call does not keep it.
- [x] `CodeContext.blastRadius(scope: .workingTree)` in a temporary git repository gives the callers of a symbol in a file that has a change.
- [x] `get diagnostics` and the current `blastRadius(file:symbol:maxHops:)` do not change their behavior. All the tests that exist at the moment pass.

## Tests
- [x] `Tests/FoundationModelsCodeContextTests/CallGraphTests.swift`, `BlastRadiusOpsTests`: add tests for two files (one merged walk), for a root that calls a root, and for files that have no symbols. Use the call-graph fixtures that the file already uses.
- [x] `Tests/FoundationModelsCodeContextTests/DiagnosticsTests.swift`: add a test for `keepsOnlyDiagnosable: false` near `workingTreeScopeResolvesModifiedUntrackedAndStagedFiles`. Use the git helper of the file, which calls `GitShell.run`.
- [x] `Tests/FoundationModelsCodeContextTests/CodeSearchToolTests.swift`: add a `CodeContext.blastRadius(scope: .workingTree)` test next to the current `context.blastRadius(file:...)` tests (near line 125). Use a temporary git repository with a caller file and a callee file. Change the callee file, and make sure that the result holds the caller.
- [x] Run `swift test`. All the tests must pass, with no new warnings.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #feature #blastradius