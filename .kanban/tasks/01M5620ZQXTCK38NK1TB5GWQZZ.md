---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57jyvw12x99w74es1wdaqcm
  text: |-
    Research:
    - SharedPathFilter holds a PathFilter, and PathFilter has `root: WorkspaceRoot` (the init already calls realpath one time). Plan: give SharedPathFilter a `nonisolated let root: WorkspaceRoot` from that same filter, thus no new realpath call.
    - Callers of `RelativePath.of` with the cause: LSPIndexWorker.collectEdges (callee of a call edge), LSPIndexWorker+References.relativePath(of:rootDirectory:) (callers and call-site targets), RelativePath.relativeFilePath(fromURI:rootDirectory:) (LiveOpsCore definition/references/implementations, LiveOpsExtended inboundCalls/reference inbound calls/workspaceSymbols, DiagnosticsOps.buildReport), QueryAST.scan.
    - In the LSP worker, the per-file PathFilter value (`pathFilter.root`) is in scope; collectCallSiteTargets and collectEdges take `rootDirectory` only to relativize, so they can take the WorkspaceRoot.
    - QueryAST: Walker.walkEntries already gives Entry.relativePath from WorkspaceRoot; use it in place of RelativePath.of.
    - workspaceSymbols has no path filter parameter; CodeContext can give `pathFilter.root`.
    - Note: /tmp is a symbolic link to /private/tmp, thus each test workspace under /tmp already has a real path that differs from the given path.
  timestamp: 2026-10-18T13:24:31.233216+00:00
- actor: claude-code
  id: 01m57kbsbptwrq9d67b2drvywp
  text: |-
    Implementation landed:
    - WorkspaceRoot (RelativePath.swift) has two new functions: `relativePath(ofURI:)` (nil for a path outside both roots) and `relativeFilePath(fromURI:)` (keeps the old fallback: absolute file path for a path outside both roots, raw URI value when the URI is not a URL). `RelativePath.of(_:relativeTo:)` and `RelativePath.relativeFilePath(fromURI:rootDirectory:)` had no caller after the change, thus they are removed.
    - SharedPathFilter has `nonisolated let root: WorkspaceRoot`, taken from its first PathFilter, thus no new realpath call. The live ops (LiveOpsCore definition/references/implementations, LiveOpsExtended inbound calls and workspace symbols) and DiagnosticsOps.buildReport use it. `workspaceSymbols`, `buildReport`, `referenceInboundCalls` and `inboundCalls(fromReferences:)` now take `root: WorkspaceRoot`; CodeContext gives `pathFilter.root`.
    - LSPIndexWorker.collectEdges and collectCallSiteTargets take `root: WorkspaceRoot` (from the per-file PathFilter); the references fallback uses `pathFilter.root.relativePath(ofURI:)`.
    - QueryAST: `Walker.enumerateFiles` now gives `[Walker.Entry]`; QueryAST uses `Entry.relativePath` (from the walk, thus from WorkspaceRoot) in place of RelativePath.of and the lastPathComponent fallback.
    - Tests: PathFilterTests (real path URI below a symlinked root gives the key; URI outside both roots gives the file path), LSPIndexWorkerTests (callee URI with the real path is stored with the relative key). RED was seen for the two new behavior tests before the change.
    - Note: the build prints "warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle". This comes from the build system and the mlx dependency, not from the source; it was there before this change.
  timestamp: 2026-10-18T13:31:34.646529+00:00
- actor: claude-code
  id: 01m57kbwa957nn59k6mkc1wq4z
  text: |-
    ### implement — changed
    - evidence: 15 Swift files (10 Sources, 5 Tests). `swift test` full run: 1007 tests in 90 suites passed. `swiftlint lint --quiet --only-rule no_magic_numbers <changed files>`: no findings. `swift format lint --strict <changed files>`: no findings.
    - next: /review
  timestamp: 2026-10-18T13:31:37.673067+00:00
- actor: claude-code
  id: 01m57kf2hstfgqc8dzpzjqy9p3
  text: |-
    ### test — green
    - evidence: swift test — 1007 tests in 90 suites passed, 0 failed, 0 skipped; forced full rebuild of Sources and Tests (touch) gave 0 warnings from this package; swift build --package-path IntegrationTests --build-tests — Build complete, no source changes needed. Only warning: SwiftPM "missing creator for mutated node" for the mlx-swift_Cmlx.bundle dependency, not from this package.
    - next: commit
  timestamp: 2026-10-18T13:33:22.361584+00:00
depends_on:
- 01M53GKH8NBN2B0MCXS2RNY171
position_column: doing
position_ordinal: '80'
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