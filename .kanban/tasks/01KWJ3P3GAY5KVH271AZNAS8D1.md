---
comments:
- actor: wballard
  id: 01kwj5e71v4acd3xd442dsd8gr
  text: |-
    Implemented via TDD: wrote Tests/CodeContextKitTests/ScaffoldTests.swift referencing Log.subsystem and CodeContextError first (RED — failed with "target 'CodeContextKit' is empty" since Sources/CodeContextKit had no files yet), then added Log.swift and CodeContextError.swift to go GREEN.

    Files created:
    - Package.swift (swift-tools-version 6.1, .macOS("27.0"))
    - Sources/CodeContextKit/Logging/Log.swift — 7 category loggers + subsystem
    - Sources/CodeContextKit/CodeContextError.swift — public enum, Error & Sendable, 7 cases
    - Tests/CodeContextKitTests/ScaffoldTests.swift

    FoundationModelsRouter check: the sibling path `../FoundationModelsRouter` DOES exist on disk (/Users/wballard/github/swissarmyhammer/FoundationModelsRouter) and resolves/builds fine as a path dependency — no need to omit it.

    Dependency resolution notes (empirically verified by building a throwaway test package before touching the real scaffold):
    - ChimeHQ/SwiftTreeSitter pinned `exact: "0.25.0"` (not `from:`) — pre-1.0, so an open range could pull a breaking update (double-check agent flagged this; fixed).
    - alex-pinkus/tree-sitter-swift pinned `exact: "0.7.3-with-generated-files"` — the default branch doesn't commit generated parser.c/scanner.c (SwiftPM can't run tree-sitter codegen), only this tag does.
    - tree-sitter/tree-sitter-python pinned `exact: "0.23.6"` (not `from: "0.24.0"`) — v0.24.0+ manifests gate `src/scanner.c` on `FileManager.default.fileExists(atPath:)`, which resolves against the top-level build's CWD rather than the checkout's own directory, so the external scanner silently drops out and the linker fails with undefined `tree_sitter_python_external_scanner_*` symbols. Caught this via a real link failure in `swift test` (library-only builds don't surface it, only linking a test/executable does).
    - tree-sitter/tree-sitter-rust and groue/GRDB.swift use normal `from:` ranges — no such issues found.
    - tree-sitter/swift-tree-sitter (referenced internally by tree-sitter-python's own Package.swift) turned out to be a same-underlying-repo alias for ChimeHQ/SwiftTreeSitter (identical HEAD commit via `git ls-remote`), so SwiftPM deduplicates it — no product-name collision.

    Verification (fresh, `rm -rf .build Package.resolved` each time): `swift build` — clean, 0 warnings in our own source (one pre-existing deprecation warning lives inside the FoundationModelsRouter dependency itself). `swift test` — both ScaffoldTests pass (logSubsystemIsCorrect, codeContextErrorCasesConstruct).

    Adversarial double-check (double-check agent) ran independently, verdict REVISE with one low-severity finding (SwiftTreeSitter unpinned range) — fixed and re-verified green. No other findings.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-02T19:38:36.475877+00:00
- actor: wballard
  id: 01kwj5t7b6rc646x79my4yhjcn
  text: 'Implemented, tested, checkpointed (acb9fc8), and reviewed clean (0 findings). Moved doing → review → done. Notable: pinned SwiftTreeSitter to exact 0.25.0 (pre-1.0), tree-sitter-swift to 0.7.3-with-generated-files (only tag with committed parser.c/scanner.c), tree-sitter-python to exact 0.23.6 (0.24.0+ has a broken FileManager scanner-existence check that silently drops the external scanner). FoundationModelsRouter sibling dependency exists on disk and resolves fine.'
  timestamp: 2026-07-02T19:45:09.990133+00:00
position_column: done
position_ordinal: '80'
title: 'Package scaffold: Package.swift, deps, logging, errors'
---
## What
Create the SPM package per plan.md "Package shape". `Package.swift` (swift-tools-version 6.1, platform `.macOS("27.0")`) with dependencies: `.package(path: "../FoundationModelsRouter")`, SwiftTreeSitter (ChimeHQ), GRDB, and the first grammar packages (tree-sitter-swift, tree-sitter-rust, tree-sitter-python — more added by the language-module tasks). Create `Sources/CodeContextKit/Logging/Log.swift` (os.Logger constants: subsystem `com.swissarmyhammer.CodeContextKit`, categories lsp, lsp-wire, index, watcher, embedding, search, diagnostics) and `Sources/CodeContextKit/CodeContextError.swift` (error enum: binaryNotFound, spawnFailed, handshakeFailed, timeout, notRunning, storage, embedding cases). Empty `Tests/CodeContextKitTests/` target using Swift Testing.

## Acceptance Criteria
- [x] `swift build` succeeds on macOS 27 with all declared dependencies resolved
- [x] `swift test` runs (a trivial smoke test passes)
- [x] `Log` exposes the seven category loggers; error enum is public and Sendable

## Tests
- [x] `Tests/CodeContextKitTests/ScaffoldTests.swift`: smoke test asserting `CodeContextError` cases construct and `Log.subsystem` constant is correct
- [x] Run `swift test` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.