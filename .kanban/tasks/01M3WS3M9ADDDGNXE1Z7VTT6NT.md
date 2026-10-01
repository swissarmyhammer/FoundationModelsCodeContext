---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wszqyrhwmcrcr63k4ksyky
  text: |-
    Research done.
    - `publishIndexingStatus()` in CodeContext.swift makes `IndexProgress` from `IndexAdmin.indexStatus`. `isDrained` needs `filesLspIndexed >= filesWalked`.
    - `LSPIndexWorker.run` keeps a dirty file dirty while `sessionProvider` gives nil, and drains it when a session appears (test `runSleepsForSessionUnavailableSleepThenDrainsOnceASessionAppears`). Thus a file that stays dirty is indexed when the server starts later.
    - `BinaryLookup` reads the real `$PATH`. There is no seam to make intelephense start later in a CodeContext test. The E2E test is gated on intelephense absent from `$PATH`, the same as the existing PHP auto-install tests.
    Rule decided: add `IndexProgress.filesLspUnavailable`, the count of LSP-dirty files whose server is settled and does not run (`.notFound`, or `.failed` at the give-up count). `isDrained` uses `filesLspIndexed + filesLspUnavailable >= filesWalked`. The files stay dirty, thus a later `forceRestart` indexes them. The JSON of `IndexProgress` gets the new key.
  timestamp: 2026-10-01T22:39:59.448240+00:00
- actor: claude-code
  id: 01m3wtccyrhwr8tjzbzgt6jbjg
  text: |-
    Implementation landed (TDD).
    - RED: `CodeContextE2ETests.isReadyBecomesTrueWhenTheServerOfAnLspDirtyFileIsNotFound` failed on `state.isReady`.
    - Rule: new `IndexProgress.filesLspUnavailable` (default 0). `isDrained` uses `filesLspIndexed + filesLspUnavailable >= filesWalked`. `CodeContext.publishIndexingStatus()` counts the LSP-dirty files whose server is `CodeContextState.isSettledAndNotRunning` (`.notFound`, or `.failed` at the give-up count). The files stay dirty. Thus the `LSPIndexWorker` indexes them when a `forceRestart()` starts the server (existing test `LSPIndexWorkerTests.runSleepsForSessionUnavailableSleepThenDrainsOnceASessionAppears` covers that drain; new test `theFileOfANotFoundServerStaysLspDirty` covers that the file stays dirty).
    - Public contract change: the JSON of `IndexProgress` has a new key `filesLspUnavailable`. The two JSON tests (`ResultEncodingTests.indexProgressEncodesEveryLayerCount`, `ToolSupportTests.successOutcomeEncodesTheValue`) now expect it. plan.md has a paragraph on the rule.
    - Constraint: `BinaryLookup` reads the real `$PATH`, thus the two E2E tests are gated on intelephense absent (same gate as the existing PHP auto-install tests). There is no seam to make a CodeContext server start later in a unit test.
    - `isSettled` and `maxConsecutiveFailures` in `CodeContextState` are now `nonisolated`, so the actor `CodeContext` can call `isSettledAndNotRunning` with no main-actor hop.
  timestamp: 2026-10-01T22:46:54.168728+00:00
- actor: claude-code
  id: 01m3wtcgm4n2j3jhsk9w78ry8b
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/CodeContextState.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/CodeContextE2ETests.swift, Tests/FoundationModelsCodeContextTests/CodeContextStateTests.swift, Tests/FoundationModelsCodeContextTests/ResultEncodingTests.swift, Tests/FoundationModelsCodeContextTests/ToolSupportTests.swift, plan.md. `swift test`: 755 tests in 68 suites passed, 0 failures, 0 compiler warnings.
    - next: /review
  timestamp: 2026-10-01T22:46:57.924319+00:00
- actor: claude-code
  id: 01m3wtp3eyttbja1chpecedn15
  text: |-
    ### test - green
    - evidence: swift test (root) - 755 tests in 68 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 11 tests in 8 suites passed, 0 failed, 0 skipped. swift format lint -s -r Sources Tests - exit 0, no findings.
    - note: Each run printed one build-system warning, "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency product. It does not come from code in this repo.
    - next: review
  timestamp: 2026-10-01T22:52:12.126982+00:00
- actor: claude-code
  id: 01m3wtpkp0c87n8ecep0rfxjee
  text: |-
    ### commit — changed
    - evidence: 78b78b1 fix(index): count LSP-unavailable files as drained so isReady becomes true
    - next: review
  timestamp: 2026-10-01T22:52:28.736622+00:00
- actor: claude-code
  id: 01m3wv5g4q1z2w713x13q120ap
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (4dc5dfc). 1 finding, 1 confirmed, 0 refuted. Sources/FoundationModelsCodeContext/CodeContext.swift:1013 (duplication/duplication).
    - next: Do the open item in the "Review Findings (2026-10-01 17:52)" section. Then do the review again.
  timestamp: 2026-10-01T23:00:36.631618+00:00
- actor: claude-code
  id: 01m3wv5tc0gxfw24bx1hcn66wx
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files (CodeContextState.swift, CodeContext.swift, 4 test files, plan.md)
    - test: green — swift test 755 passed; IntegrationTests 11 passed; swift format lint 0 findings
    - commit: 4dc5dfc
    - review: findings — Sources/FoundationModelsCodeContext/CodeContext.swift:1013 (duplication: lspFileExtension)
  timestamp: 2026-10-01T23:00:47.104534+00:00
- actor: claude-code
  id: 01m3wvhx91nep9awyfhxyv1tak
  text: |-
    Review finding fixed (duplication: lspFileExtension).
    - Discovery: the line refs of the finding are not exact. Diagnose.swift `documentURI` and Walker.swift `relativePath` do not get a file extension. The real copies of the extension logic were in CodeContext.swift (`lspFileExtension`, `session(forFilePath:)`), DiagnosticsScope.swift (`isDiagnosableExtension`), Walker.swift (`enumerateFiles`), Watcher.swift (`acceptedRelativePath`), GrepCode.swift (`ChunkFilter.matchesLanguage`), ProjectDetection.swift (`subtreeFileExtensions`), TreeSitterWorker.swift (`readAndChunk`) and LSPIndexWorker+References.swift (`calls`).
    - Fix: one shared helper in Languages.swift: `Languages.normalizedFileExtension(ofPath:)` and `Languages.normalizedFileExtension(of:)` (URL). Each site above now calls it. `CodeContext.lspFileExtension` is deleted. No `pathExtension` stays in Sources outside the helper.
    - Behavior is the same: the three sites that did not lowercase give the extension to `Languages.module(forFileExtension:)`, which lowercases it.
    - TDD: three new tests in LanguageModuleTests (`normalizedFileExtension...`). RED was a compile failure (no member); GREEN passed.
    - Not changed: the repeated `module.fileExtensions.map { $0.lowercased() }` sets (Walker, Watcher, DiagnosticsScope, CodeContext, QueryAST). That is a different cause (the extension set of the modules, not the extension of a path), and the finding does not name it.
  timestamp: 2026-10-01T23:07:23.297454+00:00
- actor: claude-code
  id: 01m3wvj0vrrt14y2vvgstzte09
  text: |-
    ### implement — changed
    - evidence: 10 files — Sources/FoundationModelsCodeContext/Languages/Languages.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift, Sources/FoundationModelsCodeContext/Index/Walker.swift, Sources/FoundationModelsCodeContext/Index/Watcher.swift, Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift, Sources/FoundationModelsCodeContext/Index/LSPIndexWorker+References.swift, Sources/FoundationModelsCodeContext/Ops/GrepCode.swift, Sources/FoundationModelsCodeContext/Projects/ProjectDetection.swift, Tests/FoundationModelsCodeContextTests/LanguageModuleTests.swift. `swift test`: 758 tests in 68 suites passed, 0 failed, 0 skipped. `swift format lint -s -r Sources Tests`: exit 0. The only warning is the known dependency build-system warning "missing creator for mutated node" (mlx-swift_Cmlx.bundle).
    - next: /review
  timestamp: 2026-10-01T23:07:26.968314+00:00
- actor: claude-code
  id: 01m3wvsa5h13jwrhn5sxf7a0ph
  text: |-
    ### test - green
    - evidence: swift test (root) - 758 tests in 68 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 11 tests in 8 suites passed, 0 failed, 0 skipped. swift format lint -s -r Sources Tests - 0 findings.
    - note: one build-system warning ("missing creator for mutated node ... mlx-swift_Cmlx.bundle") comes from the mlx-swift dependency bundle. It is not from this repo's code.
    - next: review
  timestamp: 2026-10-01T23:11:25.873955+00:00
- actor: claude-code
  id: 01m3wvst3ce40f3r3bjhb31jek
  text: |-
    ### commit — changed
    - evidence: refactor(languages): share one file extension helper (local commit, not pushed; sha is in the step block of the commit reply)
    - next: review
  timestamp: 2026-10-01T23:11:42.188951+00:00
- actor: claude-code
  id: 01m3ww3ddhay9b8yef4znx2gdd
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (057912c). 0 findings, 0 confirmed, 0 refuted. 14 pairs attempted, 0 failed. 10 files reviewed. All prior findings are checked.
    - next: The task is in done. No more work is necessary.
  timestamp: 2026-10-01T23:16:56.881098+00:00
- actor: claude-code
  id: 01m3ww3mve0w475m0sjj2v8mtk
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 10 files (shared Languages.normalizedFileExtension helper)
    - test: green — swift test 758 passed; IntegrationTests 11 passed; swift format lint 0 findings
    - commit: 057912c
    - review: clean — 0 findings
  timestamp: 2026-10-01T23:17:04.494340+00:00
position_column: done
position_ordinal: d780
title: isReady stays false for ever when a detected server is .notFound and its files are LSP-dirty
---
## Problem

Found during ^qrz0hg1. `CodeContext.markUncoveredLspFilesDone()` marks a dirty file LSP-indexed only when no detected server spec covers its extension (`coveredLspExtensions`). When a server is detected but its daemon settles at `.notFound` (no binary, auto-install off or failed), the LSP index task of that server never gets a session, thus the files of its language stay `lsp_indexed = 0`. `IndexProgress.isDrained` needs `filesLspIndexed >= filesWalked`, thus `state.isReady` stays `false` for ever, although each server is settled.

Example: a tree with `composer.json` and one `.php` file, with no `intelephense` on `$PATH` and a failed auto-install. `isReady` never becomes `true`.

## Work

- [x] Write a failing unit test: a PHP tree (marker plus one `.php` file) whose intelephense daemon settles at `.notFound`; `state.isReady` must become `true`.
- [x] Decide the rule: for example, treat the files of a server that is settled and not running as not pending for `isReady`, but keep them dirty so that a later `forceRestart` indexes them.
- [x] Implement the rule and keep the existing `isReady` tests green.

## Acceptance criteria

- [x] The test of the work list passes.
- [x] A file of a `.notFound` server is indexed when the server starts later.
#bug #index #lsp

## Review Findings (2026-10-01 17:52)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `Sources/FoundationModelsCodeContext/CodeContext.swift:1013` `duplication/duplication` — The new `lspFileExtension` function duplicates logic already implemented in Diagnose.swift:161 (`documentURI`), DiagnosticsScope.swift:96 (`isDiagnosableExtension`), and Walker.swift:175 (`relativePath`). Multiple implementations of the same URL pathExtension.lowercased() operation will drift out of sync if one is fixed and the others are not. Consolidate file extension lowercasing into a single shared utility. Either extract a public static function (if these modules should share it) or refactor Diagnose.swift, DiagnosticsScope.swift, and Walker.swift to call CodeContext.lspFileExtension instead of duplicating the logic. As written, the counterpart implementations are outside this change; refactoring them is a separate task.
