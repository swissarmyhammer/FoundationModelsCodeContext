---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: isReady stays false for ever when a detected server is .notFound and its files are LSP-dirty
---
## Problem

Found during ^qrz0hg1. `CodeContext.markUncoveredLspFilesDone()` marks a dirty file LSP-indexed only when no detected server spec covers its extension (`coveredLspExtensions`). When a server is detected but its daemon settles at `.notFound` (no binary, auto-install off or failed), the LSP index task of that server never gets a session, thus the files of its language stay `lsp_indexed = 0`. `IndexProgress.isDrained` needs `filesLspIndexed >= filesWalked`, thus `state.isReady` stays `false` for ever, although each server is settled.

Example: a tree with `composer.json` and one `.php` file, with no `intelephense` on `$PATH` and a failed auto-install. `isReady` never becomes `true`.

## Work

- [ ] Write a failing unit test: a PHP tree (marker plus one `.php` file) whose intelephense daemon settles at `.notFound`; `state.isReady` must become `true`.
- [ ] Decide the rule: for example, treat the files of a server that is settled and not running as not pending for `isReady`, but keep them dirty so that a later `forceRestart` indexes them.
- [ ] Implement the rule and keep the existing `isReady` tests green.

## Acceptance criteria

- [ ] The test of the work list passes.
- [ ] A file of a `.notFound` server is indexed when the server starts later.
#bug #index #lsp