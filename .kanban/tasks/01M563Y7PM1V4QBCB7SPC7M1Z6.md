---
assignees:
- claude-code
depends_on:
- 01M53GKT21C40MET23PKN3TJYR
position_column: todo
position_ordinal: 8d80
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
- [ ] The filter has the rules of the rule files after `start()`, also with no watcher.
- [ ] The test above passes.

#lsp-fix