---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: References-fallback call edges do not show a new caller until the callee file is indexed again
---
Source: ^0ykcm6j (the references fallback for a server without call hierarchy, for example `pylsp`).

## What happens

Without call hierarchy, `LSPIndexWorker` writes the edges INTO the callable symbols of the file that it indexes (see `Index/LSPIndexWorker+References.swift`). The indexed (callee) file owns these edges. When a caller file changes and gets a NEW call to a symbol of another file, only the caller file is indexed again. The callee file stays clean, so the index does not get the new edge until the callee file changes.

A deleted caller is correct already: `reverseEdgeFiles(db:symbolIDs:excludingFile:)` marks the owner file dirty. The live `inbound_calls` layer is correct too: it asks `references` directly. Only `get callgraph` and `get blastradius` (index only) can miss a new caller.

## Proposed change

When a file of a server without call hierarchy is indexed again, find the symbols that its new or changed call sites refer to (for example with `textDocument/definition` at each tree-sitter call site, or with the tree-sitter call-edge heuristic), and mark the files of those symbols `lsp_indexed = 0`. Do not mark all the callee files of the file: that makes a loop of index passes between two files that call each other.

## Acceptance

- [ ] A new call in file B to a function of file A shows in `get callgraph` (inbound, from A) after B is indexed again, with no change to A.
- [ ] Two files that call each other do not index each other again without end.
- [ ] A unit test with the fake `LanguageServerConnection` (a server without call hierarchy).