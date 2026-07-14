---
comments:
- actor: wballard
  id: 01kwsyb0c0d9znmgf9ggy0rpa2
  text: |-
    Progress: read ProcessLanguageServerConnection.swift (current shape confirms all 12 refactored methods + definition/typeDefinition/implementations route through notifyEmpty/notifyTextDocument/positionParams+requestAtPosition/arrayRequest/locationsRequest exactly as the task describes; no further public-facing changes from ^dy8wf8x beyond what's already tested). Read ConnectionTests.swift, scripted-lsp-server.swift, Wire.swift, LSPTypes.swift, LanguageServerConnection.swift for exact wire shapes.

    Extended scripted-lsp-server.swift's DSL (test-support only, excluded from the build target per Package.swift): "read" no longer requires an id (so it can consume a fire-and-forget notification, which carries none), and gained optional "expectMethod"/"expectURI" assertions so a script can verify the wire shape of a notification it can't get a typed response from otherwise.

    Added 9 new @Test functions to ConnectionTests.swift, all via the existing withConnection helper, covering all 6 required shapes across every named method (initialized/exit, didSave/didClose, hover, prepareRename, prepareCallHierarchy, outgoingCalls/incomingCalls, codeActions/workspaceSymbols, references, definition/typeDefinition/implementations).

    Discovery (test-only, fixed, no production code touched): my first draft of 3 of these tests (outgoingCalls+incomingCalls, codeActions+workspaceSymbols, definition+typeDefinition+implementations) scripted all "read" steps before any "respond" steps. That deadlocks: these calls are awaited *sequentially* (not concurrently like the existing out-of-order test), so the second real request is only sent once the first response arrives — the script's second "read" blocked forever, surfacing as a 30s `.timeout` failure in 3 tests. Fixed by interleaving read/respond per call. All local runs now green.
  timestamp: 2026-07-05T20:08:26.752068+00:00
- actor: wballard
  id: 01kwszp81tbvpnd16pvzw116k2
  text: |-
    really-done verification complete:
    - `swift build` and `swift build --build-tests`: clean, zero warnings beyond the pre-existing unrelated mlx-swift plugin warning.
    - `swift test --filter ConnectionTests` (wrapped in `timeout`, `pkill -9 -f swiftpm-testing-helper` after each run per this task's guidance): 18/18 green across 5 consecutive runs (1 initial + 4 repeats), no flakiness.
    - Attempted one full-suite `swift test` wrapped in a 900s timeout for extra confidence; it did not finish within the window (consistent with the separately-filed, unrelated intermittent full-suite hang tracked by ^vhcye6y). Per this task's instructions this is not blocking and was not root-caused here — ConnectionTests --filter is the reliable gate and is fully green.
    - Adversarial double-check agent: PASS, no findings. Confirmed zero production-code diff (only the two test files changed), correct read/respond interleaving in all 9 new tests, wire-shape fixtures verified against Wire.swift/LSPTypes.swift, and backward compatibility of the scripted-lsp-server.swift DSL change for all pre-existing tests.

    Leaving task in `doing` per process (not moving to review/done).
  timestamp: 2026-07-05T20:32:03.642566+00:00
- actor: wballard
  id: 01kwt0mc27cvqf0zk4kns3724h
  text: |-
    Fixed the 3 round-1 review findings (nesting depth 4 in scripted-lsp-server.swift's "read"/"respond" cases). Pure structural extraction, no DSL behavior change:

    - New `validateReadExpectations(step:message:)` helper (delegating to new `assertExpectedMethod(_:message:)` / `assertExpectedURI(_:message:)`) replaces the two inline `if let ... { guard ... }` blocks in the "read" case. Nesting there is now for > switch/case > guard (depth 3, was 4).
    - New `resolveTargetID(step:requestsReadSoFar:)` dispatcher (delegating to new `resolveTargetID(forURI:requestsReadSoFar:)` / `resolveTargetID(forIndex:requestsReadSoFar:)`) replaces the inline if/else with two guards in the "respond" case. Nesting there is now for > switch/case (depth 2).

    All extracted helper bodies are byte-for-byte equivalent to the original inline logic (same conditions, same error message text, same exit(1) calls) — verified by manual diff review and confirmed independently by the double-check agent.

    really-done verification:
    - `swift build`: clean, zero warnings beyond the pre-existing unrelated mlx-swift plugin warning.
    - `swift build --build-tests`: clean, same caveat.
    - `swift test --filter ConnectionTests` (wrapped in `timeout 180`, followed by `pkill -9 -f swiftpm-testing-helper` per this task's guidance to avoid the unrelated full-suite hang tracked by ^vhcye6y): 18/18 green across 3 consecutive runs, no flakiness.
    - Adversarial double-check agent: PASS, no findings — confirmed logic equivalence, nesting resolved, scope contained to the single test-support file, overload resolution correct (no accidental recursion), and doc-comment conventions matched.

    Only Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift changed (plus routine kanban bookkeeping files). No production code touched. Leaving task in `doing` per process.
  timestamp: 2026-07-05T20:48:30.791919+00:00
- actor: wballard
  id: 01kwt16f4vj1exe85zmveq1scr
  text: |-
    Fixed both round-2 (2026-07-05 15:50) review findings — unlabeled first parameter on non-conversion functions in scripted-lsp-server.swift:

    - `assertExpectedMethod(_ expectMethod: String, message: Data)` -> `assertExpectedMethod(expecting expectMethod: String, message: Data)`
    - `assertExpectedURI(_ expectURI: String, message: Data)` -> `assertExpectedURI(expecting expectURI: String, message: Data)`

    Updated the single call site of each (both inside `validateReadExpectations(step:message:)`) to `assertExpectedMethod(expecting: expectMethod, message: message)` / `assertExpectedURI(expecting: expectURI, message: message)`. Confirmed via grep these are the only call sites in the repo. No other code changed.

    really-done verification:
    - `swift build`: clean, zero warnings beyond the pre-existing unrelated mlx-swift plugin warning.
    - `swift build --build-tests`: clean, same caveat.
    - `swift test --filter ConnectionTests` (each wrapped in `timeout 180`, followed by `pkill -9 -f swiftpm-testing-helper` per this task's guidance to avoid the unrelated full-suite hang tracked by ^vhcye6y): 18/18 green across 3 consecutive runs, no flakiness.
    - Adversarial double-check agent launched to confirm scope and label choice; awaiting verdict before final sign-off.

    Leaving task in `doing` per process.
  timestamp: 2026-07-05T20:58:23.771483+00:00
- actor: wballard
  id: 01kwt1a5kbkk7pae2tfjfgvk9p
  text: |-
    Adversarial double-check verdict: PASS, no findings. Confirmed diff scoped to exactly the two signature renames + two call-site updates in scripted-lsp-server.swift, no missed call sites repo-wide, `expecting:` label reads naturally and matches the file's existing labeling conventions (e.g. resolveTargetID(forURI:)), no collisions, no dangling old-form references, no unrelated code changes.

    Both round-2 (2026-07-05 15:50) findings checked off in the task description. Verification (build clean/zero new warnings, ConnectionTests 18/18 green x3, no flakiness) recorded above. Leaving task in `doing` for review per process.
  timestamp: 2026-07-05T21:00:25.067201+00:00
- actor: wballard
  id: 01kwt1k19bpkncerp9n6rj48zp
  text: |-
    Wrap-up — all three review rounds resolved, task done.

    Round 1 (2026-07-05 15:38): scripted-lsp-server.swift had three guard statements nested 4 levels deep. Fixed by extracting `validateReadExpectations(step:message:)` plus `assertExpectedMethod`/`assertExpectedURI` and `resolveTargetID` helpers, reducing nesting to for > switch/case > (function call / guard).

    Round 2 (2026-07-05 15:50): the two newly-extracted assertion helpers, `assertExpectedMethod`/`assertExpectedURI`, had unlabeled first parameters. Fixed in commit 390b683 by adding `expecting:` argument labels and updating both call sites in `validateReadExpectations`.

    Round 3 (this review, scope HEAD~1..HEAD / commit 390b683): re-ran the full multi-agent review engine against that commit's delta. Verified via `git diff HEAD~1..HEAD` that the commit touches only the two function signatures and their two call sites — an exact match for the round-2 finding, nothing broader. Fresh review returned zero findings (counts: findings 0, confirmed 0). All checklist items from rounds 1 and 2 were already checked off. Task moved doing -> done.

    Original scope gap (extending ConnectionTests with real-subprocess coverage for the twelve refactored helper call sites) remains logged in the task description as the "Not fixed in this pass" note from the initial really-done adversarial sign-off — it was superseded by the nesting/labeling cleanup rounds and is not part of this commit's delta. If that coverage gap still needs addressing, it should be tracked as its own follow-up task rather than reopening this one.

    Unrelated, separately tracked issues (not caused by this task): kanban ^vhcye6y (full-test-suite-only intermittent hang) and 01KWSZY7MD8GYWZ3YVHNSSME48 (DiagnosticsScope bug).
  timestamp: 2026-07-05T21:05:15.563960+00:00
position_column: done
position_ordinal: '9e80'
title: Add ConnectionTests coverage for refactored LSP helper call sites
---
Sources/FoundationModelsCodeContext/LSP/ProcessLanguageServerConnection.swift was refactored to extract shared helpers (notifyEmpty, notifyTextDocument, positionParams/requestAtPosition, arrayRequest, locationsRequest) from previously duplicated inline logic. Manual line-by-line diff review confirms the extraction is behavior-preserving (same method names, param shapes, defaults, optional-array normalization).

However, adversarial review (double-check agent) found: Tests/FoundationModelsCodeContextTests/ConnectionTests.swift is the only test file exercising ProcessLanguageServerConnection against a real subprocess, and all four of its tests only call documentSymbols — a method the refactor did not touch. None of the twelve refactored methods (initialized, exit, didSave, didClose, hover, references, prepareCallHierarchy, outgoingCalls, incomingCalls, prepareRename, codeActions, workspaceSymbols) nor definition/typeDefinition/implementations (which route through the also-refactored positionRequest/locationsRequest) are exercised anywhere in the suite against the real connection. FakeLanguageServerConnection is an independent hand-written conformance and provides no coverage of this file.

Suggested fix: extend ConnectionTests (or the scripted-lsp-server test DSL) with cases that drive at least one representative call through each new helper's distinct shape against the real subprocess: a no-payload notification (initialized/exit), a textDocument/* notification (didSave/didClose), a position-keyed single-result request (hover/prepareRename), a position-keyed array/optional-array request (prepareCallHierarchy), a non-position array request (workspaceSymbols/codeActions), and a LocationsResult-wrapped request (references, definition/typeDefinition/implementations).

Not fixed in this pass: task scope was running/fixing the existing test suite (157/157 pass, ConnectionTests stress-tested 13x with no flakiness, build clean apart from a pre-existing third-party mlx-swift plugin warning), not authoring new coverage. Logged here per really-done adversarial sign-off gate so the gap isn't silently dropped.

## Review Findings (2026-07-05 15:38)

- [x] `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift:118` — Guard statement nested 4 levels deep (for > guard > switch/case > if > guard) exceeds recommended maximum of 3 and makes the code harder to follow. Extract the expectMethod validation into a separate helper function, or restructure the case block to move validation logic outside the if statement. **Fixed**: extracted `assertExpectedMethod(_:message:)` (and its expectURI sibling) into a new `validateReadExpectations(step:message:)` helper called from the "read" case, reducing nesting to for > switch/case > guard.
- [x] `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift:136` — Guard statement nested 4 levels deep (for > guard > switch/case > if > guard) exceeds recommended maximum of 3 and makes the code harder to follow. Extract the URI matching logic into a separate helper function to reduce nesting depth and improve readability. **Fixed**: extracted `assertExpectedURI(_:message:)`, called from the same `validateReadExpectations(step:message:)` helper as above.
- [x] `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift:143` — Guard statement nested 4 levels deep (for > guard > switch/case > else > guard) exceeds recommended maximum of 3 and makes the code harder to follow. Extract the index-based request lookup logic into a separate helper function to reduce nesting depth and improve readability. **Fixed**: extracted `resolveTargetID(forURI:requestsReadSoFar:)` and `resolveTargetID(forIndex:requestsReadSoFar:)`, both called from a new `resolveTargetID(step:requestsReadSoFar:)` dispatcher used by the "respond" case, reducing nesting to for > switch/case > (function call).

## Review Findings (2026-07-05 15:50)

Scope: HEAD~1..HEAD (commit 8063f51) — round-2 nesting fix delta only. Verified against `git diff HEAD~1..HEAD`: both findings target `assertExpectedMethod` and `assertExpectedURI`, functions newly introduced by this commit; not a re-flag of the round-1 nesting findings above.

- [x] `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift:111` — First parameter of non-conversion function should be labeled. The rule states "Omit the first argument label only for value-preserving conversions. Otherwise, label it." This assertion function is neither a conversion nor a factory method, so the first parameter needs a label. Add a label to the first parameter: `func assertExpectedMethod(expecting expectMethod: String, message: Data)` or `func assertExpectedMethod(expected expectMethod: String, message: Data)`. **Fixed**: renamed to `assertExpectedMethod(expecting expectMethod: String, message: Data)`; updated its single call site in `validateReadExpectations(step:message:)`.
- [x] `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift:122` — First parameter of non-conversion function should be labeled. Same as above — this assertion function needs its first parameter labeled. Add a label to the first parameter: `func assertExpectedURI(expecting expectURI: String, message: Data)` or `func assertExpectedURI(expected expectURI: String, message: Data)`. **Fixed**: renamed to `assertExpectedURI(expecting expectURI: String, message: Data)`; updated its single call site in `validateReadExpectations(step:message:)`.
