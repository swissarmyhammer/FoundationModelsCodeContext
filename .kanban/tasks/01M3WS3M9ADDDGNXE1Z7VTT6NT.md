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
position_column: doing
position_ordinal: '80'
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