---
assignees:
- claude-code
depends_on:
- 01M53GKH8NBN2B0MCXS2RNY171
position_column: todo
position_ordinal: 8b80
title: Use WorkspaceRoot.relativePath for the LSP and query paths too
---
## Problem
Task ^2rny171 added `WorkspaceRoot` (`Sources/FoundationModelsCodeContext/Index/RelativePath.swift`): the one relative-path function that removes the root, then the canonical root (`realpath(3)`). The walker, the watcher, the reconcile and `DiagnosticsScopeResolver` use it. Other callers still use `RelativePath.of(_:relativeTo:)`, which removes only the standardized root and does not resolve symbolic links:

- `LSPIndexWorker` (callee path of a call edge) and `LSPIndexWorker+References`.
- `RelativePath.relativeFilePath(fromURI:rootDirectory:)` (live ops and diagnostics).
- `QueryAST` (relative path of a matched file).

A language server such as sourcekit-lsp can send the real path (`/private/var/...`, or the target of a symbolic-link root). Then these callers drop the edge, or give an absolute path in place of the row key.

## Change
- Use `WorkspaceRoot.relativePath(of:)` (or `PathFilter.root`) in each caller above.
- Keep the fallback behavior of `relativeFilePath(fromURI:)` for a path outside both roots.

## Tests
- With a root that is a symbolic link, a URI with the real path gives the relative key in `relativeFilePath(fromURI:)`.
- A call edge whose callee URI has the real path is stored with the relative key.

#lsp-fix