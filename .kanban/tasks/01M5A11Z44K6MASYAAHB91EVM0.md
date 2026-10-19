---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'Tree-sitter worker: a file deleted between the watch event and the read is not a warning'
---
## What
SWE-bench run of 2026-10-18, 16:00:02: one warning
`the tree-sitter index worker cannot read the file file.path=check_mcf_fix.py`.
The agent most likely deleted a scratch file between the watcher event and the read.

## Where
`Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift` `readAndChunk(relativePath:rootDirectory:)` (~line 228): `try? Data(contentsOf:)` folds every failure (gone, permission, not UTF-8) into one warning.

## Approach
- Split the cases:
  - File does not exist (ENOENT / `NSFileReadNoSuchFileError`) → debug level, and make sure the caller removes the file's rows (chunks, symbols, embeddings, call edges) from the store instead of only marking it indexed. Check what the caller does with `nil` today and how the reconcile / watcher handles deletes, so the two paths agree.
  - Not UTF-8 → its own message (info or warning).
  - Other read errors (EACCES, EIO) → keep the warning, add the error type name (no content).
- Check `LSPIndexWorker` for the same pattern.

## TDD
1. Failing test: index a file, mark it dirty, delete it, run the tree-sitter pass; assert no warning record is logged (capture `Log.index`) and the file's rows are gone from the store.
2. Test: a file with invalid UTF-8 → the not-UTF-8 message.
3. Test: an unreadable file (chmod 000) → the warning stays.
4. Implement; run the suite. #index #bug