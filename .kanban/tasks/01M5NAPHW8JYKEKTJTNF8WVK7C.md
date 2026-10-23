---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5nb8jvcxew22yqqrzt205wd
  text: |-
    ### test — green
    - red first: listSymbolsGivesOneRowPerSymbolAfterTheLinesOfItsFileMove failed on the old code (helper not one row at line 4; inbound graph lost `caller` from views.py), with the edge present before the move.
    - an existing test (TSCallGraphTests.lspSourcedEdgesForTheSameFileAreNotDeletedByReindex) showed that the shape of a row (columns 0, no detail) cannot tell a synthetic row from an LSP row, thus a `source` column with migration v4 (MigrationsTests covers the backfill).
    - evidence: `swift test` 1092 tests in 96 suites passed; IntegrationTests 22 passed; only the allowed mlx warning.
  timestamp: 2026-10-23T21:39:23.116371+00:00
position_column: done
position_ordinal: ff8a80
title: 'listSymbols gives a symbol two times after its file changes: TSCallGraph leaves its synthetic lsp_symbols rows at the old lines'
---
## What
From the acp-agent bench (bench24-1023b, django__django-13964, seq 4606): listSymbol("django/db/models/base.py") gave each method twice, the second 4 lines lower (save 671–726 and 675–730, save_base 729–776 and 733–780, ...).

## Cause (found in the index database of that run)
- `ts_chunks` has one `Model.save` at 671. `lsp_symbols` has two `save` rows: id 5771 at 675 and id 47746 at 671. Both have kind `function`, columns 0 and no detail, so both are synthetic `TSCallGraph` rows, not pylsp rows (`lsp_indexed = 0`).
- The index is kept by clone path, so each Django instance reuses the index of the instance before it, at another commit. `base.py` changed, and tree-sitter chunked it again. But `TSCallGraph.ensureSymbolID` finds or creates a row only by `(file, start_line)`, and nothing removes or moves a synthetic row whose symbol moved. The old row stays; the new pass adds one at the new line. `SymbolOps` merges by `(file, start_line)`, so the old row shows as a second, LSP-only symbol.
- The same thing happens in one session when the model edits a file and its lines move.

## Change
In `TreeSitterWorker.writeChunks`, after the new chunks of a file are written and before `TSCallGraph.writeCallEdges`, bring the synthetic rows of that file in line with the new chunks (new `TSCallGraph` step):
- A row at the line of a chunk with the same leaf name stays.
- A row whose symbol moved goes to the line of the nearest free chunk with the same leaf name, so the edges from other files that point at it stay valid.
- A row with no such chunk is deleted (its edges cascade).
- A synthetic row is one with start and end column 0 and no detail. A real LSP row taken for one is harmless: its file changed, so its LSP pass writes it again.

## Test (first, red)
Python fixture: `lib.py` with `helper` and `user()` calling it; `app.py` calling `helper`. Index, add 4 comment lines at the top of `lib.py`, index again: listSymbols(lib.py) has one `helper`, at line 4, and the inbound call graph of `helper` still has `caller` from app.py.

#bug