---
comments:
- actor: wballard
  id: 01kwt2eqvy97mgggw9wxst209v
  text: |-
    Implemented via TDD:

    1. Read RelativePath.swift, TreeSitterWorker.swift, LSPIndexWorker.swift, and TreeSitterWorkerTests.swift first. Confirmed `RelativePath.isSafeRelativePath(_:)` already exists as a shared static helper (extracted during an earlier session on ^es8qv65) and is already used by LSPIndexWorker and LiveOpsCore.
    2. Wrote failing test `runRejectsAPathTraversalRelativePathWithoutReadingTheFile` in TreeSitterWorkerTests.swift, mirroring LSPIndexWorkerTests' analogous traversal test: writes a real readable file at "../secret.swift" just outside the temp workspace root, seeds indexed_files dirty via `store.markDirty(filePath: "../secret.swift", ...)`, runs `TreeSitterWorker.run`, asserts processed==1, drainTsDirty() empty, and `ts_chunks` COUNT(*) == 0.
    3. Confirmed RED: test failed with `chunkCount == 0 -> false, chunkCount -> 1` — proving the traversal file actually got read/chunked before the fix.
    4. Implemented fix: added `guard RelativePath.isSafeRelativePath(relativePath) else { ...; return nil }` at the very top of `TreeSitterWorker.readAndChunk(relativePath:rootDirectory:)`, before any URL/disk access. Returning `nil` here routes through `run`'s existing `else` branch (`store.markIndexed(filePath:, layer: .treeSitter)`) — the same "mark indexed, nothing written, don't retry" mechanism already used for an unresolvable language module or unreadable file. No new duplicate helper added.
    5. Confirmed GREEN: `swift test --filter TreeSitterWorkerTests` — 7/7 pass. Also ran `swift test --filter LSPIndexWorkerTests` — 11/11 pass (shared helper unaffected).
    6. `swift build` clean, no new warnings (only a pre-existing unrelated mlx-swift_Cmlx.bundle SwiftPM notice).
    7. Attempted one full-suite `swift test` run (wrapped in a 600s timeout per task guidance) for extra confidence: it surfaced `DiagnosticsTests.scopeResolutionExcludesNonDiagnosableExtensions` failing (`resolved == ["README.md"]` instead of empty). Verified via `git stash` of just my two changed files that this failure is 100% pre-existing/unrelated — it fails identically on main without my diff. Not caused by this change; not chasing further (unrelated to ^g5qevm1, and consistent with the known separate full-suite flakiness tracked by ^vhcye6y).
    8. Spawned the `double-check` adversarial reviewer on the diff; awaiting its verdict before finalizing.
  timestamp: 2026-07-05T21:20:23.422568+00:00
- actor: wballard
  id: 01kwt2hrv7rfxqne3g7d7se2gw
  text: |-
    Adversarial double-check (via `double-check` agent) returned PASS with no findings: confirmed the guard runs before any disk access, `RelativePath.isSafeRelativePath` correctly catches embedded `..` (not just leading), the test is a real discriminator (independently reverted just TreeSitterWorker.swift via git stash and reconfirmed the new test fails with chunkCount==1), correct `.treeSitter` layer used for markIndexed, no duplicate helper introduced, and doc-comment style matches LSPIndexWorker's precedent.

    really-done verification complete:
    - `swift build`: clean, exit 0, no new warnings.
    - `swift test --filter TreeSitterWorkerTests`: 7/7 pass (all wrapped in `timeout 300` + `pkill -9 -f swiftpm-testing-helper` per task guidance).
    - `swift test --filter LSPIndexWorkerTests`: 11/11 pass (shared `RelativePath.isSafeRelativePath` helper unaffected).
    - One full-suite `swift test` attempted under a 600s timeout: surfaced a pre-existing, unrelated failure (`DiagnosticsTests.scopeResolutionExcludesNonDiagnosableExtensions`), confirmed via git-stash isolation to fail identically without this diff — not caused by this change, not pursued further per task instructions (separate known flakiness tracked by ^vhcye6y).

    Leaving task in `doing` per /implement process — ready for /review.
  timestamp: 2026-07-05T21:22:02.727718+00:00
- actor: wballard
  id: 01kwt3e8k8y9qn8k88za9j834j
  text: 'Round 1 review of HEAD~1..HEAD (cd29126): clean, 0 findings. TreeSitterWorker now guards with the shared RelativePath.isSafeRelativePath(_:) helper before disk access, matches LSPIndexWorker''s mark-indexed-nothing-written pattern on rejection, and ships a genuinely discriminating regression test. Moved to done.'
  timestamp: 2026-07-05T21:37:36.360331+00:00
position_column: done
position_ordinal: 9f80
title: 'TreeSitterWorker: same path-traversal risk as LSPIndexWorker for indexed_files.file_path'
---
## What

`Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift`'s `readAndChunk(relativePath:rootDirectory:)` resolves `relativePath` — sourced from `indexed_files.file_path` via `store.drainTsDirty()` / `Store.drainDirty(column:)` — against `rootDirectory` with `appendingPathComponent(_:)` and then reads it with `Data(contentsOf:)`, with no validation that `relativePath` doesn't contain a `..` component or a leading `/`/`~`.

This is the identical defense-in-depth concern already fixed in `LSPIndexWorker.swift`'s `processFile` (task `01KWJ3WNDEXN2N4BSACPC5H3J4`, "LSP indexer worker: documentSymbol + call hierarchy into the store"), via a new private helper `isSafeRelativePath(_:)`:

```swift
private static func isSafeRelativePath(_ relativePath: String) -> Bool {
    guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
        return false
    }
    return !relativePath.split(separator: "/").contains("..")
}
```

Discovered by the `double-check` adversarial reviewer while verifying that LSPIndexWorker fix — it explicitly flagged that the same store-sourced-path threat model applies to `TreeSitterWorker`'s drain path and was left unfixed there, since fixing it was out of scope for the LSP-worker task.

Note: `Watcher.swift`'s `appendingPathComponent` call was checked and is *not* affected — its relative path comes from `RelativePath.of(url, relativeTo:)` off a real FSEvents URL under the watched root, a different (safe) provenance, not from `indexed_files.file_path`.

## Acceptance Criteria

- [ ] `TreeSitterWorker.readAndChunk(relativePath:rootDirectory:)` rejects a `relativePath` containing a `..` path component, or with a leading `/` or `~`, before resolving it against `rootDirectory` — either by reusing/sharing `LSPIndexWorker`'s `isSafeRelativePath(_:)` (consider hoisting it to a shared internal helper both workers can call, to avoid duplicating the logic) or by an equivalent guard following this worker's own established resilience pattern for a permanently-bad file (mirror however `TreeSitterWorker` already handles an unreadable file — mark indexed with nothing written, not left dirty for retry).
- [ ] A test proves the guard: seed `indexed_files` dirty with a `file_path` containing `..` that resolves to a real, readable file just outside the workspace root (not merely a missing path — a missing-path test wouldn't discriminate between "guard rejected it" and "just failed to read like any other unreadable file"), and assert the file's content is never read/chunked/embedded.

## Workflow

Use `/tdd` — write the failing test first, then implement to make it pass.

## Review Findings (2026-07-05 16:33)

No findings. The engine ran 15 checks across the `HEAD~1..HEAD` diff (commit cd29126) with 0 confirmed and 0 refuted.

Manually cross-checked against `git diff HEAD~1..HEAD`:
- `readAndChunk` now guards with `RelativePath.isSafeRelativePath(relativePath)` before any `URL`/disk access, rejecting `..` components and leading `/`/`~` — reuses the pre-existing shared helper in `RelativePath.swift` (hoisted there in commit `d7685da`, prior to this task), not a duplicate of `LSPIndexWorker`'s guard.
- On rejection the file is marked tree-sitter-indexed with nothing written (returns `nil`, same code path as an unresolvable language module or unreadable file), matching `LSPIndexWorker`'s established "don't retry forever" pattern for permanently-bad inputs.
- New regression test `runRejectsAPathTraversalRelativePathWithoutReadingTheFile` in `Tests/FoundationModelsCodeContextTests/TreeSitterWorkerTests.swift` seeds a real, readable file just outside the workspace root via a `..`-containing `file_path`, and asserts zero rows in `ts_chunks` — a genuine discriminating test, not a missing-path stand-in.
- Diff is scoped exactly to the task: `TreeSitterWorker.swift`, its test file, and the two kanban bookkeeping files. No unrelated changes.