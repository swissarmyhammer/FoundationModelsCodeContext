---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5772crvapxer722navmw4ky
  text: |-
    Research done. Current state:
    - LspSession keeps `docs: [DocumentURI: DocState]` with no limit, no owner. `syncOpen` writes `docs` after the `await` (reentrancy race). `didClose(uri:)` has one caller: `LSPIndexWorker.closeDocument`.
    - `LSPIndexWorker.syncAndFetchSymbols` returns nil on a failed `documentSymbols` and the caller returns with no close. The references fallback (`LSPIndexWorker+References.swift`, `fetchCallableSymbols`) has the same leak, and its close can close the file that `processFile` still uses (same URI, nested).
    - Live ops: `LiveOpsCore.syncLiveDocument` (7 callers in LiveOpsCore and LiveOpsExtended) and `DiagnosticsOps.syncAndPull` sync and never close.
    - Rust reference: `swissarmyhammer-lsp/src/session/open_documents.rs` (`MAX_OPEN_DOCUMENTS = 50`, `DocumentOwner` tool/indexer, tool is sticky, LRU by a tick). Rust has no "in use" count; this port adds one, because the card asks that a document that an op uses now is not closed.
    Plan: new `OpenDocuments` value type (owner, LRU tick, use count, limit); per-URI FIFO gate in the session so open and close of one URI run in sequence; the entry goes into the set before the `didOpen` await so the count never goes above the limit; `beginUse`/`endUse`; `closeIfOwned(uri:by:)` replaces `didClose(uri:)`; worker and live ops use them.
  timestamp: 2026-10-18T09:56:43.931814+00:00
- actor: claude-code
  id: 01m578h8qy9esvh9rfq3rrsfka
  text: |-
    Implementation landed.
    - New `LSP/OpenDocuments.swift`: `DocumentOwner` (tool, indexer; tool is sticky) and `OpenDocuments` (entries with owner and LRU tick, use counts, `defaultLimit = 50`).
    - `LspSession`: `init(... maximumOpenDocuments:)` (injectable limit). `syncOpen(uri:text:owner:)` (owner defaults to `.tool`) holds a per-URI FIFO gate, so open and close of one URI run in sequence; a new entry goes into the set before the `didOpen` await, after `makeSpaceForOneDocument()` closes LRU documents that no op uses and that no gate holds. A failed LRU `didClose` fails the open; no candidate throws `LspSessionError.openDocumentLimit`. New `beginUse`/`endUse` and `closeIfOwned(uri:by:)`; `didClose(uri:)` is gone (its one caller was the worker).
    - `LSPIndexWorker`: `withIndexerDocument(...)` syncs with owner indexer, runs the body while in use, then closes when the worker owns it, on every path (failed sync, failed documentSymbols, success; the close is before the store write). The references fallback uses the same helper, so a failed documentSymbols there no longer leaks, and a nested open of the same file no longer closes the file that processFile still uses.
    - Live ops: `LiveOpsCore.syncLiveDocument` became `withLiveDocument(...)`, which keeps the document in use during the request; 7 callers changed. Diagnostics: `syncAndPull` keeps the document in use during the pull.
    - Also named the magic numbers that `swiftlint --only-rule no_magic_numbers` reported in the touched files (`NotReadyErrorCode` in LspSession, `TreeSitterReferenceSearch` in LiveOpsCore).
    Discoveries: a test that the references fallback closes `sample.py` one time passed on the old code (the fallback reuses the symbols of the indexed file and does not reopen it), so I deleted that test. The concurrent-sync test passes because of the insert-before-await; the per-URI gate adds the close/reopen ordering. RED was seen for the three worker tests against the old sources (git stash of LspSession).
  timestamp: 2026-10-18T10:22:19.902364+00:00
- actor: claude-code
  id: 01m578hbdb02bvzw35kr4fs533
  text: |-
    ### implement — changed
    - evidence: Sources: LSP/OpenDocuments.swift (new), LSP/LspSession.swift, Index/LSPIndexWorker.swift, Index/LSPIndexWorker+References.swift, Ops/LiveOpsCore.swift, Ops/LiveOpsExtended.swift, Diagnostics/Diagnose.swift. Tests: LspSessionOpenDocumentsTests.swift (new, 10 tests), LSPIndexWorkerTests.swift (+2), LSPIndexWorkerReferencesTests.swift (+1), Support/AsyncGate.swift (new), Support/FakeLanguageServerConnection.swift, Support/LspSessionTestSupport.swift, LspSessionTests.swift. Affected suites: 146 tests in 14 suites passed. Full `swift test`: 979 tests in 86 suites passed. `swiftlint lint --quiet --only-rule no_magic_numbers` on changed files: clean.
    - next: /review
  timestamp: 2026-10-18T10:22:22.635592+00:00
- actor: claude-code
  id: 01m578z5pxb7tzh2kdbd9nfmqp
  text: |-
    ### test — green
    - evidence: swift test: 979 tests in 86 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests: Build complete, no call-site changes needed; changed files recompiled with zero warnings from this package (only a mlx-swift_Cmlx dependency build-system warning)
    - next: commit
  timestamp: 2026-10-18T10:29:55.549342+00:00
- actor: claude-code
  id: 01m5799qa3z1xtabgd4ybj1esf
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (e2ce0f5). 3 findings (3 confirmed, 3 refuted). Sources/FoundationModelsCodeContext/Diagnostics/Diagnose.swift:160, Tests/FoundationModelsCodeContextTests/LspSessionOpenDocumentsTests.swift:36, Tests/FoundationModelsCodeContextTests/Support/AsyncGate.swift:16.
    - acceptance: the change has a test for each of the five items in the Tests list. The review step did not run the tests. The test step must show that they pass.
    - next: correct the 3 findings, then run the test step and the review step again. The task stays in review.
  timestamp: 2026-10-18T10:35:41.251984+00:00
- actor: claude-code
  id: 01m579a38yfps0kx34nxxwpsy0
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 13 files
    - test: green — swift test, 979 passed
    - commit: e2ce0f5
    - review: findings — Sources/FoundationModelsCodeContext/Diagnostics/Diagnose.swift:160, Tests/FoundationModelsCodeContextTests/LspSessionOpenDocumentsTests.swift:36, Tests/FoundationModelsCodeContextTests/Support/AsyncGate.swift:16
  timestamp: 2026-10-18T10:35:53.502515+00:00
- actor: claude-code
  id: 01m579cwkpasgjstzhhb51tbvx
  text: |-
    Picked up the 3 review findings. Research:
    - The path check, the disk read and the URI build occur in Diagnose.syncAndPull, LSPIndexWorker.processFile, LSPIndexWorker+References.fetchCallableSymbols and LiveOpsCore.withLiveDocument. Three copies of the disk read exist (Diagnose, LSPIndexWorker, LiveOpsCore) and two copies of the URI build. Diagnose pulls diagnostics also when the read fails, thus the helper must give the URI with an optional text, and `nil` only when the filter rejects the path.
    - Plan: new `Index/LanguageServerDocument.swift` (failable init from a `PathFilter`, static `uri(relativePath:rootDirectory:)` and `readText(relativePath:rootDirectory:)`), plus `SharedPathFilter.acceptedDocument(relativePath:rootDirectory:)`. Delete the three private copies.
    - RestartGate (LspSupervisorTests) starts open and has `close()`; AsyncGate starts closed. Plan: give AsyncGate `init(isOpen:)` and `close()`, delete RestartGate.
    - URI helpers: openedURIs and pulledURIs (LSPPathCheckTests), closedURIs and didOpenCount (LspSessionOpenDocumentsTests). Plan: one generic `uris(where:)` on FakeLanguageServerConnection in Support/.
  timestamp: 2026-10-18T10:37:24.982907+00:00
- actor: claude-code
  id: 01m57a1snp93en1neava6xtz05
  text: |-
    Review findings corrected.
    - Finding 1 (duplication): new `Index/LanguageServerDocument.swift`. A failable init takes the relative path, the root and a `PathFilter`. It gives `nil` when the filter rejects the path, and otherwise the URI and the disk text (the text is `nil` when the read fails, because diagnostics must pull also then). `SharedPathFilter.acceptedDocument(relativePath:rootDirectory:)` is the same for the shared filter. Static `uri(relativePath:rootDirectory:)` and `readText(relativePath:rootDirectory:)` (with the safe-path check) are the one URI build and the one disk read. Callers: Diagnose.syncAndPull (and its watched URIs), LSPIndexWorker.processFile, fetchCallableSymbols, LiveOpsCore.withLiveDocument and LiveOpsCore.readSourceRange. Deleted three private copies of readFileContents and Diagnose.documentURI. New LanguageServerDocumentTests (5 tests). TreeSitterWorker and QueryAST also read files, but they are not LSP prologue copies and are not in the changed files, thus not changed.
    - Finding 2 (reuse): `Support/FakeLanguageServerConnection+URIs.swift` adds `uris(where:)`. closedURIs and didOpenCount (LspSessionOpenDocumentsTests) and openedURIs and pulledURIs (LSPPathCheckTests) are each one call to it; each case match stays at its call site.
    - Finding 3 (reuse): AsyncGate has `init(isOpen:)` and `close()` now. RestartGate is deleted; LspSupervisorTests and GatedConnection use `AsyncGate(isOpen: true)`.
  timestamp: 2026-10-18T10:48:50.102832+00:00
- actor: claude-code
  id: 01m57a1wmnf8dk6yn25sepga1g
  text: |-
    ### implement — changed
    - evidence: Sources: Index/LanguageServerDocument.swift (new), Diagnostics/Diagnose.swift, Index/LSPIndexWorker.swift, Index/LSPIndexWorker+References.swift, Ops/LiveOpsCore.swift. Tests: LanguageServerDocumentTests.swift (new), Support/FakeLanguageServerConnection+URIs.swift (new), Support/AsyncGate.swift, LspSessionOpenDocumentsTests.swift, LSPPathCheckTests.swift, LspSupervisorTests.swift. `swift build --build-tests`: no warnings from this package. Affected suites: 172 tests in 10 suites passed. Full `swift test`: 984 tests in 87 suites passed, 0 failed. `swift build --package-path IntegrationTests --build-tests`: Build complete. `swiftlint --only-rule no_magic_numbers` on changed files: clean. 3 of 3 findings checked.
    - next: /test, then /review
  timestamp: 2026-10-18T10:48:53.141054+00:00
- actor: claude-code
  id: 01m57aapnt7seb8m3533yrsw7b
  text: |-
    ### test — green
    - evidence: swift test (root) — 984 tests in 87 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete, exit 0. The only warning is a build-system message about the mlx-swift_Cmlx bundle from a dependency, not from this package.
    - next: commit
  timestamp: 2026-10-18T10:53:41.946573+00:00
- actor: claude-code
  id: 01m57aky7fct4appsr0hh83db3
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (a5abe2d). 1 finding (1 confirmed, 1 refuted). All 3 prior items are checked. Open: Sources/FoundationModelsCodeContext/Index/LanguageServerDocument.swift:31 (swift/initialization).
    - next: Fix the open item in the "Review Findings (2026-10-18 05:54)" section. Then run review again.
  timestamp: 2026-10-18T10:58:44.591681+00:00
- actor: claude-code
  id: 01m57am8qm7316cmmn6pxe52kd
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 11 files (shared LanguageServerDocument, uris(where:), one AsyncGate)
    - test: green — swift test, 984 passed
    - commit: a5abe2d
    - review: findings — Sources/FoundationModelsCodeContext/Index/LanguageServerDocument.swift:31
  timestamp: 2026-10-18T10:58:55.348521+00:00
- actor: claude-code
  id: 01m57b7x97y2mwb7g3mhfpjv4b
  text: |-
    Finding swift/initialization (LanguageServerDocument.swift:31) corrected.
    - `LanguageServerDocument.init?` now does the path check and the URI build only. It keeps `relativePath`, `rootDirectory` and `uri`. The `text` property is gone. New `func readText() -> String?` reads the disk text each time a caller calls it.
    - Callers call `readText()` where they sync the document: Diagnose.syncAndPull (it still pulls diagnostics when the read gives `nil`), LSPIndexWorker.processFile (it still marks an unreadable file indexed), fetchCallableSymbols, LiveOpsCore.withLiveDocument. LiveOpsCore.readSourceRange already uses the explicit static `readText(relativePath:rootDirectory:)`; no change.
    - Other types of this task: OpenDocuments.init(limit:), AsyncGate.init(isOpen:), GatedConnection.init(gate:) and the LspSession test init only set stored values. No slow work, no change. The task in LspSession.init that consumes notifications is from an earlier commit (135efdc), not from this task.
    - LanguageServerDocumentTests: tests use `readText()`; new test `theDiskReadOccursAtReadTextAndNotAtInit` writes new text after init and expects the new text. RED: compile failure (no instance `readText()`).
  timestamp: 2026-10-18T11:09:38.983519+00:00
- actor: claude-code
  id: 01m57b80cz8b0kjzhwrm8gf2js
  text: |-
    ### implement — changed
    - evidence: Sources: Index/LanguageServerDocument.swift, Diagnostics/Diagnose.swift, Index/LSPIndexWorker.swift, Index/LSPIndexWorker+References.swift, Ops/LiveOpsCore.swift. Tests: LanguageServerDocumentTests.swift. `swift test --filter LanguageServerDocumentTests`: 6 tests passed. Affected suites (LSPIndexWorker, LSPIndexWorkerReferences, LSPPathCheck, Diagnostics, LayeredOps, LiveOpsExtended, LspSessionOpenDocuments, LanguageServerDocument): 134 tests in 8 suites passed. Full `swift test`: 985 tests in 87 suites passed, 0 failed. `swiftlint --only-rule no_magic_numbers` on changed files: clean. 1 of 1 open finding checked.
    - next: /test, then /review
  timestamp: 2026-10-18T11:09:42.175010+00:00
- actor: claude-code
  id: 01m57bhct7vwtpm19yg4e047fe
  text: |-
    ### test — green
    - evidence: swift test: 985 tests in 87 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests: Build complete, exit 0. Only warning is from the mlx-swift_Cmlx bundle (dependency, not this package).
    - next: commit
  timestamp: 2026-10-18T11:14:49.799242+00:00
position_column: doing
position_ordinal: '80'
title: Close LSP documents on all paths and limit the number of open documents
---
## Problem
- `LSPIndexWorker.processFile` closes the document on success (`Sources/FoundationModelsCodeContext/Index/LSPIndexWorker.swift:365`, `closeDocument` at `:429-435`). But when `documentSymbols` throws, it returns at `:342-344` and does not close the document.
- Live ops (`Ops/LiveOpsCore.swift:847-849`) and diagnostics (`Diagnostics/Diagnose.swift:145-149`) call `syncOpen` and never close.
- `LspSession.docs` (`LSP/LspSession.swift:155`) has no size limit. Each open document makes the server do work on each change.

## Change
- In `processFile`, close the document with a `defer` after a good `syncOpen`.
- Add an LRU limit to `LspSession` (for example 50 open documents). When the limit is passed, send `didClose` for the oldest document that no op uses now.
- Make the limit injectable for tests.
- Give each open document an owner: tool or indexer. A `syncOpen` from a live op or from diagnostics sets the owner to tool, and the owner stays tool. Now the worker always closes the document (`LSPIndexWorker.swift:365`, then `LspSession.swift:616-617`), also when a live op opened it and uses it now. The worker must close only the documents that it owns, on all paths: success, failed `syncOpen`, failed `documentSymbols`, failed call hierarchy and failed store write.
- Check-then-act race: `syncOpen` (`LspSession.swift:270-280`) reads `docs`, waits for the send, and then writes `docs`. This is actor reentrancy. Two calls at the same time can send two `didOpen` messages or the same version two times, and a `didClose` between the steps can make `syncOpen` skip a reopen. Update `docs` before the `await`, or put the open and close of each URI in sequence.
- At the limit, close the least recently used document first. If that `didClose` fails, the open must fail, so the count never goes above the limit. (This is the Rust design: `MAX_OPEN_DOCUMENTS = 50`.)

## Tests
- When `documentSymbols` throws, the fake connection gets `didClose` for that document.
- After N+1 live-op opens with a limit of N, the oldest document gets `didClose`, and the session has N open documents.
- A document that an op uses now is not closed.
- A live op opens a document, then the worker indexes the same file: the worker does not send `didClose` for it.
- Two `syncOpen` calls at the same time for one URI send one `didOpen` only.

## Acceptance criteria
- [ ] No document leak on the failure path.
- [ ] The number of open documents stays at the limit or less.
- [ ] The tests above pass.

#lsp-fix

## Review Findings (2026-10-18 05:30)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsCodeContext/Diagnostics/Diagnose.swift:160` `duplication/duplication` — The guard on the path filter, the read of the disk text, and the build of the document URI are repeated in three places: here in syncAndPull, in processFile, and in fetchCallableSymbols. Copies of this prologue can drift apart, for example when the filter check or the URI form changes in one place only. Extract one shared helper that takes the relative path, the root, and the path filter, and returns the URI and the disk text, or nil when the filter rejects the file or the read fails. Call it from all three sites. Keep the per-site work (beginToolUse for tools, withIndexerDocument for the indexer) at each call site.
- [x] `Tests/FoundationModelsCodeContextTests/LspSessionOpenDocumentsTests.swift:36` `reuse/reuse` — The new `closedURIs` helper repeats the shape of the existing `openedURIs` helper: it runs `compactMap` over `connection.calls` and returns the URI of one call case. The only difference is the matched case (`.didClose` instead of `.didOpen`). A second copy means two places to fix if the recorded-call shape changes. Move one generic helper to the shared test support (for example `Tests/FoundationModelsCodeContextTests/Support/`) that takes the case extractor, for example `uris(of connection:, where: (FakeLanguageServerConnection.Call) -> DocumentURI?)`. Then express `closedURIs`, and ideally `openedURIs` and `pulledURIs`, as one-line calls to it. Keep the per-case matches as the parameters so each case stays visible at its call site.
- [x] `Tests/FoundationModelsCodeContextTests/Support/AsyncGate.swift:16` `reuse/reuse` — The new AsyncGate actor reimplements the gate that RestartGate already has. RestartGate.waitUntilOpen is the same suspend-until-open logic. Two copies of one gate must now be kept in step, and they can drift apart. Reuse one gate. Either make RestartGate a typealias or thin wrapper over AsyncGate, or delete RestartGate and have LspSupervisorTests use AsyncGate. If RestartGate has behavior that AsyncGate lacks, add that parameter to AsyncGate instead of writing a second type.

## Review Findings (2026-10-18 05:54)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsCodeContext/Index/LanguageServerDocument.swift:31` `swift/initialization` — The failable `init?` does disk I/O. Its `text = Self.readText(...)` reads the whole file, and the `acceptsDocument` check before it touches the filesystem. A caller that only needs the URI, or that builds the document in a loop, pays for a file read on every construction. The rule says `init` does no slow work and that reads belong in an explicit call the caller makes. Keep `init?` to the path check and the URI build, and make the disk text a lazy or explicit read. For example, store `uri` in `init?` and add `func readText() -> String?` that callers invoke where they sync the document. If the eager read is intended, say so in the type's doc comment as a documented exception to the rule.
