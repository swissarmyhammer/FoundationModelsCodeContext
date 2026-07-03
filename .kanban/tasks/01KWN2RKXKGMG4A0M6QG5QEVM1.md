---
position_column: todo
position_ordinal: '9e80'
title: 'TreeSitterWorker: same path-traversal risk as LSPIndexWorker for indexed_files.file_path'
---
## What

`Sources/CodeContextKit/Index/TreeSitterWorker.swift`'s `readAndChunk(relativePath:rootDirectory:)` resolves `relativePath` — sourced from `indexed_files.file_path` via `store.drainTsDirty()` / `Store.drainDirty(column:)` — against `rootDirectory` with `appendingPathComponent(_:)` and then reads it with `Data(contentsOf:)`, with no validation that `relativePath` doesn't contain a `..` component or a leading `/`/`~`.

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
