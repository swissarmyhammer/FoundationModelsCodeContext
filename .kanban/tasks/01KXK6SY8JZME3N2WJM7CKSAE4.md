---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxkap2y0vqvwjexq6gcweypx
  text: |-
    Implemented RootDiscovery in Sources/FoundationModelsCodeContext/Projects/RootDiscovery.swift with discoverRoots(under:) and gitRoot(containing:), plus RootDiscoveryTests.swift (8 tests covering sibling discovery, nested-repo pruning, .git-file worktrees, git-only scope, hidden/symlink skipping, and gitRoot upward resolution).

    Interesting discovery: gitRoot(containing:) initially used a "walk upward until parent == current" loop relying on URL equality to detect the filesystem root. This spun in an infinite loop (100% CPU, never terminating) for the "outside any repo" case — `URL.deletingLastPathComponent()` does not reliably fix at "/" when called repeatedly on a URL built via standardizedFileURL/appendingPathComponent chains; past a certain depth it starts yielding "/../", "/../../", etc. instead of returning "/" again. Verified with a standalone repro script. Fixed by checking `current.pathComponents.count > 1` as the root-termination condition instead of comparing to a freshly computed parent. All 8 RootDiscoveryTests pass after the fix.
  timestamp: 2026-07-15T16:45:13.536861+00:00
- actor: claude-code
  id: 01kxkb73cgcg8mcernsxty68af
  text: |-
    Adversarial double-check verdict: PASS. Reviewer independently re-verified the gitRoot root-termination fix with a standalone repro (filesystem root, parent-is-repo, deeply nonexistent path, trailing-slash path) and confirmed no infinite loop. It also cross-checked the symlink/hidden-entry resource-value idiom against Walker.swift and found it consistent with existing project convention (not a new risk).

    Non-blocking findings acted on: added 3 more tests to close the coverage gap the reviewer flagged — discoverRootsReturnsParentItselfWhenItIsARepo, gitRootOnRepoRootDirectoryReturnsItself, and discoverRootsThrowsForNonexistentParent. RootDiscoveryTests.swift now has 11 tests, all passing. Two other findings (nil-resourceValue defaulting to "not a symlink", and minor traversal-boilerplate duplication with Walker.swift) were left as-is since they match Walker.swift's own existing convention and the doc comment already explains why Walker can't be reused directly.

    Final verification (fresh run): `swift test` -> "Test run with 452 tests in 38 suites passed" (449 pre-existing + 3 new), zero failures. `swift build --build-tests` clean, no new warnings.

    Leaving task in doing, green and ready for /review.
  timestamp: 2026-07-15T16:54:31.056918+00:00
- actor: claude-code
  id: 01kxkbgkwqhdnhkxke3axvbq5m
  text: |-
    ## Review Findings (2026-07-15 11:56)

    - [ ] `Sources/FoundationModelsCodeContext/Projects/RootDiscovery.swift:87` — The resource keys array [.isDirectoryKey, .isSymbolicLinkKey] is repeated and should be extracted as a named constant to reduce duplication and ensure consistency if the keys need to change in the future. Extract [.isDirectoryKey, .isSymbolicLinkKey] as a private static let constant within the RootDiscovery enum, then reference it in both locations.
  timestamp: 2026-07-15T16:59:42.871143+00:00
- actor: claude-code
  id: 01kxkbpxwpn58r9kjx4mf63ye7
  text: |-
    Pulled back from review into doing to address the open review finding. Extracted the duplicated `[.isDirectoryKey, .isSymbolicLinkKey]` resource-key array in RootDiscovery.swift into a private static constant `traversalResourceKeys` (typed `Set<URLResourceKey>`), referenced at both call sites: `Array(traversalResourceKeys)` for `contentsOfDirectory(includingPropertiesForKeys:)` and directly for `resourceValues(forKeys:)`.

    Note: the original duplicated array literals both compiled because Swift's ExpressibleByArrayLiteral implicitly converted the literal to Set at the resourceValues call site. Once named as a constant, that implicit dual-typing broke, so the constant needed an explicit type — chose Set<URLResourceKey> (matching resourceValues' native type) and converted to Array only where contentsOfDirectory required it.

    Verification: `swift build` clean (exit 0). `swift test` -> "Test run with 452 tests in 38 suites passed" (fresh run, all green, including all 11 RootDiscoveryTests). One earlier run showed a flaky failure in WatcherTests.realFSEventsDetectsFileWriteAndMarksItDirty (real-FSEvents timing test, unrelated to this change) — reran WatcherTests alone and the full suite again, both green.

    Spawning double-check for adversarial review of the refactor before leaving in doing for re-review.
  timestamp: 2026-07-15T17:03:09.718981+00:00
- actor: claude-code
  id: 01kxkbsrpp7snzm36jc85b94p7
  text: |-
    Adversarial double-check verdict: PASS. Reviewer confirmed the duplicate array is gone (only one `[.isDirectoryKey, .isSymbolicLinkKey]` literal exists, at the new `traversalResourceKeys` declaration), both call sites reference it, no behavior change (order-independent key sets, `Array(Set)` conversion is safe for `URLResourceKey`), and discoverRoots/gitRoot/pruning/hidden-symlink-skip logic is otherwise untouched. Confirmed via git diff that only RootDiscovery.swift changed (plus kanban task bookkeeping files).

    Final verification (fresh run): `swift build` -> "Build complete!" exit 0. `swift test` -> "Test run with 452 tests in 38 suites passed", zero failures, including all 11 RootDiscoveryTests.

    Review finding checked off. Leaving task in doing, green and ready for /review.
  timestamp: 2026-07-15T17:04:42.710207+00:00
position_column: doing
position_ordinal: '80'
title: 'Add RootDiscovery: find git-repo roots under a parent and resolve the repo root containing a path'
---
## What\nCreate `Sources/FoundationModelsCodeContext/Projects/RootDiscovery.swift` with a `public enum RootDiscovery` (stateless namespace, mirroring `ProjectDetection`):\n\n- `public static func discoverRoots(under parent: URL) throws -> [URL]` — its own FileManager traversal (deliberately NOT `Walker.walkEntries`: Walker skips hidden entries so it can never see `.git`). Rules:\n  - A directory containing a `.git` entry is a repo root. `.git` may be a **directory** (normal repo) or a **file** (worktree/submodule) — both count.\n  - Prune traversal below a discovered root (a nested repo inside another repo is NOT returned; the git-repo unit is the outermost `.git` boundary on each branch of the tree).\n  - **Git repos only** — no project-marker fallback. \"Git repo = the project unit\" is the agreed intent; a caller who wants a non-git directory as a workspace opens it explicitly via `CodeContextManager.context(for:)` (or standalone `CodeContext`), which accepts any directory. This also keeps discovery symmetric with lazy routing (`gitRoot(containing:)`) and avoids a marker directory shadowing git repos nested beneath it.\n  - Skip hidden directories and do not follow symlinks (mirror `Walker`'s policy), except the `.git` presence check on each visited directory.\n  - Return roots as standardized file URLs, sorted by path for deterministic output.\n- `public static func gitRoot(containing path: URL) -> URL?` — walk upward from `path` (or its parent if it's a file) to the nearest ancestor containing a `.git` entry; `nil` if none before the filesystem root. Standardize the returned URL.\n\n## Acceptance Criteria\n- [x] `discoverRoots` finds sibling repos under a parent folder and returns them sorted\n- [x] A repo nested inside another repo's working tree is pruned (only the outer root returned)\n- [x] A `.git` *file* (worktree-style) is recognized as a root\n- [x] A directory with project markers but no `.git` is NOT returned (git repos only)\n- [x] Hidden directories and symlinks are not traversed\n- [x] `gitRoot(containing:)` resolves a deep file path to its enclosing repo root and returns nil outside any repo\n\n## Tests\n- [x] `Tests/FoundationModelsCodeContextTests/RootDiscoveryTests.swift` using temp-dir fixtures built with FileManager (create `.git` dirs/files by hand; no real `git` needed): sibling repos, nested repo pruning, `.git`-file recognition, marker-only dir excluded, hidden/symlink skipping, `gitRoot` upward resolution and nil case\n- [x] `swift test --filter RootDiscoveryTests` passes\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.