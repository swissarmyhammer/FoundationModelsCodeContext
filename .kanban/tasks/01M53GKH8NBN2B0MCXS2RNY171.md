---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m55z2b5vxv4wj0v8yjgy2n0v
  text: |-
    Research done. Findings:
    - `URL.resolvingSymlinksInPath()` removes the `/private` prefix on macOS: a root of `/var/folders/...` resolves to the same `/var/...` path, but FSEvents sends `/private/var/...`. Measured with a script: `realpath(3)` gives `/private/var/folders/...`. Thus the canonical root uses `realpath(3)`, with `resolvingSymlinksInPath()` as the fallback when `realpath` fails.
    - Two existing tests (`CodeContextE2ETests.startResetsIsStartedOnFailureSoARetryActuallyStarts`, `CodeContextManagerTests.failedStartLeavesManagerUnregisteredAndPropagatesError`) make `start()` fail with an unreadable subdirectory. With this task the walk skips that subdirectory, thus `start()` does not fail. These tests must make the ROOT unreadable for listing (mode 0o300: write and search, no read), so the walk still throws and the store files stay reachable.
    - The LSP wiring of the filter is task ^kn3tjyr. This task makes one shared filter instance (an actor) that `CodeContext` owns and gives to the watcher, so ^kn3tjyr can give the same instance to the LSP worker.
    - Other `RelativePath.of(_:relativeTo:)` callers (LSPIndexWorker callee paths, QueryAST, relativeFilePath(fromURI:)) are out of the scope of this card. I add a new task for them.
  timestamp: 2026-10-17T22:17:39.259891+00:00
- actor: claude-code
  id: 01m5621dvga7hzn8qbcsvxgxv8
  text: |-
    Implementation landed (not committed).

    What changed:
    - New `Index/PathFilter.swift`: `PathFilter` (value) and `SharedPathFilter` (actor). The filter ignores hidden components, the hard-skip directories (`.build`, `target`, `node_modules`, `.git`, `.code-context`, `.sah`) with no rule file, and the rules of `.gitignore` and `.ignore` at each level and of `.git/info/exclude`. `isIgnored(relativeComponents:isDirectory:)` examines each ancestor as a directory, then the path. A path outside the root and the canonical root is ignored. `isRuleFileChange(_:)` finds a change to a rule file before the filter.
    - `Index/RelativePath.swift`: new `WorkspaceRoot` with the root and the canonical root (`realpath(3)`, fallback `resolvingSymlinksInPath()`). `relativeComponents(of:)` / `relativeComponents(ofPathComponents:)` is the one relative-path function: remove the root, then the canonical root. The walker, the watcher (through `PathFilter`) and `DiagnosticsScopeResolver` use it.
    - `Index/Gitignore.swift`: `GitignorePattern` no longer knows its directory; `GitignoreStack` is removed.
    - `Index/Walker.swift`: the walk uses `PathFilter`; it skips, logs and counts an entry that it cannot examine (`unexaminedPaths`); only an unlistable root throws. It lists the canonical root, because `FileManager.contentsOfDirectory` gives ENOTDIR for a root that is a symbolic link. `walk(rootDirectory:)` now returns `HashedWalk { files, unexaminedPaths }`. `hashFile(at:relativePath:)` is shared with the watcher.
    - `Index/Reconciler.swift`: no delete of a row at or below an unexamined path; new `CleanupStats.skipped`.
    - `Index/Watcher.swift`: loads the rules one time in `start()` off the actor (`SharedPathFilter.reload()`, detached task); reloads only when a raw event is a rule-file change (examined before the filter). Load failure gives the hidden-path and hard-skip filter and a warning; the watcher still starts. New internal init that takes the shared instance.
    - `CodeContext.swift`: owns one `SharedPathFilter` and gives it to the watcher. The LSP worker wiring (same instance) is task ^kn3tjyr.
    - `Diagnostics/DiagnosticsScope.swift`: uses `WorkspaceRoot.relativePath(of:)`.

    Test notes:
    - `CodeContextE2ETests.startResetsIsStartedOnFailureSoARetryActuallyStarts` and `CodeContextManagerTests.failedStartLeavesManagerUnregisteredAndPropagatesError` now remove the read permission of the ROOT (mode 0o300) to make `start()` fail, because the walk now skips an unreadable subdirectory.
    - New tests: `PathFilterTests` (7), 10 new watcher tests in `WatcherTests` (FakeFileEventSource + ManualClock), 2 new reconcile tests and 3 new walker tests in `ReconcilerTests.swift`. Shared fixtures in `TestSupport.swift`: `withSymlinkedWorkspace`, `realPath(of:)`, `IgnoreRulesTree`, `unlistableDirectoryPermissions`.

    Discovery: a hash that cannot read a file is now also an unexamined path, so a temporary read error does not delete the row.
    New task ^b5gwqzz: the LSP callee paths, `relativeFilePath(fromURI:)` and `QueryAST` still use `RelativePath.of(_:relativeTo:)` with no canonical root.
  timestamp: 2026-10-17T23:09:34.960080+00:00
- actor: claude-code
  id: 01m5621j7ge7t9ygysfpbfdzs6
  text: |-
    ### implement — changed
    - evidence: 13 files. New: Sources/FoundationModelsCodeContext/Index/PathFilter.swift, Tests/FoundationModelsCodeContextTests/PathFilterTests.swift. Changed: Index/RelativePath.swift, Index/Gitignore.swift, Index/Walker.swift, Index/Reconciler.swift, Index/Watcher.swift, CodeContext.swift, Diagnostics/DiagnosticsScope.swift, Tests WatcherTests.swift, ReconcilerTests.swift, TestSupport.swift, CodeContextE2ETests.swift, CodeContextManagerTests.swift. `swift test`: 885 tests in 79 suites passed, no warning from this package. `swift test --package-path IntegrationTests --filter 'RealFSEventsWatcherTests|DetectProjectsScaleTests|GrepCodeScaleTests'`: 4 tests passed.
    - next: /review. LSP worker use of the shared instance is ^kn3tjyr; other relative-path callers are ^b5gwqzz.
  timestamp: 2026-10-17T23:09:39.440723+00:00
- actor: claude-code
  id: 01m562dan8ttz6xa8nyyh4f1q9
  text: |-
    ### test — green
    - evidence: swift test — 885 tests in 79 suites passed, 0 failed, 0 skipped; swift build --package-path IntegrationTests --build-tests — Build complete; no compiler warning from this package (only the SwiftPM build-system note "missing creator for mutated node" for the mlx-swift_Cmlx bundle, from a dependency)
    - next: commit
  timestamp: 2026-10-17T23:16:04.904671+00:00
position_column: doing
position_ordinal: '80'
title: Use one path filter in the walker, the watcher and the reconcile
---
## Problem
The watcher sends files in gitignored directories to `indexed_files`. Then the LSP worker opens them. In the Rust code, this caused a sourcekit-lsp index loop (560% CPU).

- `Watcher.isIgnored` (`Sources/FoundationModelsCodeContext/Index/Watcher.swift:480-489`) calls `stack.isIgnored(url, isDirectory: false)` only for the file. It does not test the parent directories.
- In `Index/Gitignore.swift:104-113`, a rule that ends in `/` does not match a file, and a rule with no slash matches only the last name. Thus `node_modules/`, `target/`, `build/` and `/dist` do not match `target/debug/foo.rs` in the watcher. They match only in the walker (`Index/Walker.swift:163`), because the walker prunes directories.
- The walker (`Walker.swift:137-174`) and the watcher (`Watcher.swift:457-471`) each have their own filter code.
- There are no hard skips for `target/` and `node_modules/`. The code does not read `.git/info/exclude` or `.ignore` files.
- Canonical root: FSEvents can send `/private/var/...` paths when the root is `/var/...`, or the real path when the root is a symlink. The watcher makes the event URL with `URL(fileURLWithPath:)` (`Watcher.swift:716`) and compares it with `RelativePath.of`, which uses `standardizedFileURL` only (`RelativePath.swift:52-54`). This does not resolve symlinks. No code in `Sources/` resolves the root. Thus, with such a root, the watcher drops all events with no log.
- `isIgnored` reads all `.gitignore` files again for each event (`Watcher.swift:476-479`).

## Change
- Make one shared path filter type. `Walker`, `Watcher`, `Reconciler` and the LSP worker must use it.
- The filter must skip: hidden path segments, the hard skip names (`.build`, `target`, `node_modules`, `.git`, `.code-context`, `.sah`) also when there is no `.gitignore`, and the rules from `.gitignore` and `.ignore` at all levels.
- The ignore check must test each ancestor directory with `isDirectory: true`, then the file. This is the same result as the walker prune.
- Read `.git/info/exclude` as an additional rule source.
- The filter must keep the root and the canonical root (`resolvingSymlinksInPath`). It must remove the root from the path. If this fails, it must remove the canonical root. A path that is outside the two roots is ignored.
- Use one relative-path function (remove the root, then the canonical root) for the walker, the watcher, the reconcile and `DiagnosticsScope`. The row key must always be the relative path, never an absolute path. If the walker and the watcher make different keys for one file, the file gets two rows, and the reconcile and the watcher delete and add the second row again and again. The Rust code has this bug (Rust task ^wtbecq0).
- Load the rules one time at watcher start, off the actor. Do not load them for each event. Load them again only when a batch has a change to a `.gitignore`, `.ignore` or `.git/info/exclude` file. Examine the batch for these files BEFORE the filter: `.git` is hidden and a hard skip, so the filter drops the `.git/info/exclude` event. If this is not done, write the limit in a comment: the watcher does not see a rule change until it starts again, and the reconcile walk reads the current rules. (Rust task ^x1hj626.)

- Rule load failure: `GitignoreStack.appending(gitignoreAt:)` (`Index/Gitignore.swift:191-192`) uses `try?` and continues with no rules when a read fails. Do not use an empty rule set as the fallback. Use a filter with only the hidden-path and hard-skip rules, log a warning, and always start the watcher. With no rules, events for `.build/`, `target/` and `node_modules/` go through again.
- `Watcher.isIgnored` returns `false` when it cannot find the directories to the path (`Watcher.swift:481-482`). A path that the filter cannot examine must be ignored, not accepted.
- The LSP path filter (task ^kn3tjyr) must use the same filter instance as the watcher. If it keeps its own copy, it can send `didOpen` for a path that the new rules ignore.
- The walker stops the full walk when one subdirectory cannot be read, or when a file is deleted between the list and the type check (`Walker.swift:143`, `:156`). Skip that entry, log it, count it, and continue. The reconcile must NOT delete rows under a directory that the walk could not read. If it does, a temporary permission error deletes valid index rows. (Rust task ^7ps6xar has the same bug and the same rule.)

## Notes from the Rust fix (`swissarmyhammer-code-context/src/ignore_filter.rs`, commit 752f71c38)
- After the fix, one index.db went from 102,219 rows to 253 rows, with 0 rows under `.build/`. The reconcile cleanup works when the walk and the database use the same filter.
- Real FSEvents can come 1.8 s to 20 s after a write on a loaded Mac. Our watcher tests use `FakeFileEventSource` and `ManualClock`. Keep it so. If a test uses real FSEvents, wait up to 30 s and return when the event arrives.

## Tests
- A watcher event for `node_modules/x/a.ts` with `node_modules/` in `.gitignore` does not make a row.
- A watcher event for `build-out/a/b.swift` with `build-out/` in `.gitignore` does not make a row.
- A watcher event for `target/debug/a.rs` with no `.gitignore` does not make a row.
- With a root that is a symlink to a temporary directory, an event that has the real path makes a row. An event for a path outside the two roots makes no row.
- With a symlinked root, the walk and a watcher event for the same file make one row with the same relative key.
- A change to `.gitignore` or `.git/info/exclude` in a batch loads the rules again, and the next event uses the new rules.
- A row for a file that is on disk but now ignored is deleted by reconcile.
- With one subdirectory that cannot be read, the walk returns the other files, and the reconcile keeps the rows under that subdirectory.
- The walker and the watcher give the same result for the same set of paths.

## Acceptance criteria
- [ ] One filter type, used by the walker, the watcher and the reconcile.
- [ ] Directory rules in `.gitignore` apply to watcher events.
- [ ] Watcher events with the canonical path of a symlinked root are accepted.
- [ ] The tests above pass. #lsp-fix