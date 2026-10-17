---
assignees:
- claude-code
depends_on:
- 01M53GKH8NBN2B0MCXS2RNY171
position_column: todo
position_ordinal: '8180'
title: Do not send ignored paths or paths outside the root to the LSP
---
## Problem
No code checks the ignore rules before it sends `textDocument/didOpen` to a language server.

- `LspSession.syncOpen` (`Sources/FoundationModelsCodeContext/LSP/LspSession.swift:268-281`) opens any URI.
- `LSPIndexWorker.dirtyFiles` (`Index/LSPIndexWorker.swift:251-271`) selects rows by `lsp_indexed = 0` and the extension only.
- The path check `RelativePath.isSafeRelativePath` (`Index/RelativePath.swift:70-75`) is a text check only. It does not resolve symlinks.
- `Diagnose.syncAndPull` (`Diagnostics/Diagnose.swift:146-149`) calls `pullDiagnostics` also when that path check fails.

## Change
- Use the shared path filter from the dependency task at the one point before `syncOpen`: in `LSPIndexWorker.processFile`, `LiveOpsCore.syncLiveDocument` and `Diagnose.syncAndPull`.
- Resolve symlinks and make sure that the path is in the workspace root.
- For an ignored path, the worker deletes the row or marks it LSP-indexed. It must not keep the row dirty, because then it reads the row again.
- In `Diagnose.syncAndPull`, do not pull diagnostics when the path check fails.
- A skipped path is not an error.

## Tests
- A dirty row for an ignored path does not cause `didOpen` (use the fake connection), and the worker does not select that row again.
- A symlink that points out of the root is not opened.
- `Diagnose` does not pull diagnostics for a path that fails the check.

## Acceptance criteria
- [ ] No `didOpen` for ignored paths or for paths outside the root.
- [ ] The tests above pass.

#lsp-fix