---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: 'Walker: test the entry whose type the walk cannot read'
---
## Problem
`Walker.TreeWalk.visitChild` records an entry as unexamined when `URL.resourceValues(forKeys:)` fails. The reconcile then keeps the rows at or below that path. No test runs this path.

The tests of ^2rny171 cover the two other unexamined-path causes: a directory that the walk cannot list (mode 0o000), and a file that the walk cannot read for the hash (mode 0o000).

A test cannot make the type read fail with permissions:
- A directory with mode 0o444 (read, no search) does not reach this path. `FileManager.contentsOfDirectory` fails on it, so the walk records the directory as unlistable (measured: `unexaminedPaths == ["blocked"]`).
- The children of a subdirectory come from `contentsOfDirectory(at:includingPropertiesForKeys:)`, which can prefetch the resource values. Thus the type read of these children can succeed from the cache.
- For a child of the root, the type read fails only when the entry is removed between the list and the read. This is a race, and a unit test must not depend on a race.

## Change
- Add a seam in `Walker` for the read of the entry type (for example, a function value that `walkTree` takes, with the `URL.resourceValues` read as the default). Keep the seam internal.
- Add a walker test: the seam fails for one file. Assert that the walk returns the other files and that `unexaminedPaths` holds the path of that file.
- Add a reconcile test in the style of `reconcileKeepsTheRowsUnderAnUnreadableDirectory`: index the file, make the type read fail, reconcile, and assert `stats.removed == 0`, `stats.skipped == 1`, and that the row of the file is still in `indexed_files`.

## Tests
- The walker test and the reconcile test above.

## Acceptance criteria
- [ ] Each unexamined-path cause in `Walker` has a walker test and a reconcile test. #lsp-fix