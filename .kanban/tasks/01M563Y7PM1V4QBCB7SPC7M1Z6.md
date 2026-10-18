---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57m5cs6fjm3hamknfa76ysc
  text: 'Research: `SharedPathFilter.reload()` already loads the rules on a detached task, thus a call from the `CodeContext` actor does not block it. `performStart()` calls `startWatcher()`; its `guard let eventSource else { return nil }` branch is the place with no watcher. Plan: call `await pathFilter.reload()` in that branch. Test plan: in `CodeContextStartTests`, a Rust context with `eventSource: nil`, a `.gitignore` with `build-out/`, and a hover on `build-out/lib.rs`. The fake connection goes into the existing `Box` actor through `configureConnection`. The test expects no `didOpen` for the ignored URI, and a `didOpen` for an accepted file as a control.'
  timestamp: 2026-10-18T13:45:33.734900+00:00
- actor: claude-code
  id: 01m57mcm1pb356d78g0hn89n44
  text: |-
    Implementation done.
    - `CodeContext.startWatcher()`: the `eventSource == nil` branch now calls `await pathFilter.reload()` one time before it returns `nil`. `reload()` loads the rules on a detached task, thus the load does not block the actor. The doc comment tells this.
    - Test `CodeContextStartTests.aContextWithNoEventSourceSendsNoDidOpenForAFileThatOnlyAGitignoreRuleIgnores`: it uses a Rust context, `eventSource: nil` and `.gitignore` = `build-out/`. It does a hover on `build-out/generated.rs` and on `lib.rs`. It expects no `didOpen` for the ignored file, a `didOpen` for `lib.rs` (the control), and no watcher. The existing `Box` actor keeps the fake connection. `makeCodeContext` and `makeRustContext` now accept `eventSource: FakeFileEventSource?`.
    - RED: the test failed before the fix because the ignored path got a `didOpen`. GREEN after the fix.
    - A file-path test is necessary. The LSP index worker does not show the bug, because the walk does not mark the ignored file dirty. The live operations use the shared filter only, thus a hover shows the bug.
    - The `didOpen` case match stays at the call site. This agrees with the doc of `FakeLanguageServerConnection.uris(where:)`.
    - Swiftlint `no_magic_numbers` on the two changed files: clean. The full swiftlint run still shows file_length, type_body_length and line_length findings in `CodeContext.swift` and `CodeContextStartTests.swift`. These findings were there before this change. The new lines are under 120 characters.
  timestamp: 2026-10-18T13:49:30.550270+00:00
- actor: claude-code
  id: 01m57mcpcghmv2nsnjpkb746tz
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift. `swift test --filter CodeContextStartTests`: 18/18 pass. `swift test` (full): 1009 tests in 90 suites pass, 0 failures. `swiftlint lint --quiet --only-rule no_magic_numbers <changed files>`: clean.
    - next: review
  timestamp: 2026-10-18T13:49:32.944687+00:00
- actor: claude-code
  id: 01m57mgjpme5zfsz3srpgx7vsv
  text: |-
    ### test — green
    - evidence: swift test: 1009 tests in 90 suites passed, 0 failures, 0 skipped; forced recompile of the 2 changed files (swift build --build-tests): 0 warnings from this package; swift build --package-path IntegrationTests --build-tests: Build complete, 0 warnings from this package. Only warning: SwiftPM "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency, not in this package.
    - next: commit
  timestamp: 2026-10-18T13:51:40.244104+00:00
depends_on:
- 01M53GKT21C40MET23PKN3TJYR
position_column: doing
position_ordinal: '80'
title: Load the ignore rules of the shared path filter also when CodeContext has no watcher
---
## Problem
`CodeContext` owns one `SharedPathFilter`. Only `Watcher.start()` calls `SharedPathFilter.reload()`. When the host gives no event source (`eventSource: nil`), `CodeContext.startWatcher()` makes no watcher. Thus nothing loads the rules of `.gitignore`, `.ignore` and `.git/info/exclude`, and the filter has only the hidden-path and hard-skip rules.

Since ^kn3tjyr, the LSP index worker, the live ops and `DiagnosticsOps` use this filter before `syncOpen`. With no watcher, a path that only a `.gitignore` rule ignores thus goes through to `textDocument/didOpen`.

## Change
- In `CodeContext.start()`, when there is no event source, call `pathFilter.reload()` one time.

## Tests
- A `CodeContext` with `eventSource: nil` and a `.gitignore` rule does not send `didOpen` for the ignored path (use the fake connection).

## Acceptance criteria
- [x] The filter has the rules of the rule files after `start()`, also with no watcher.
- [x] The test above passes.

#lsp-fix