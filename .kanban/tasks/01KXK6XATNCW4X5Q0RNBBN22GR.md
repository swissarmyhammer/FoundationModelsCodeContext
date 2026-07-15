---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxks1xhrw8ak1fnk5q61hy1j
  text: |-
    Implemented both docs deliverables:

    - README.md: added a "Two ways in" section between the intro snippet and Install. First paragraph links Examples/CodeContextExample for the existing standalone entry point (unchanged). Second paragraph introduces CodeContextManager with a short snippet mirroring Examples/ManagerExample/main.swift's flow (discover roots -> open each via context(for:) -> lazy context(containing:) -> fan-out searchCode(query:) with Rooted results and FanOutFailure -> shutdown()), linking Examples/ManagerExample. Verified the snippet's API shapes (CodeContextManager(embedder:), RootDiscovery.discoverRoots(under:) throws (not async), context(for:), context(containing:) returns optional, searchCode(query:) -> (results:,failures:), Rooted{root,value}, SearchCodeMatch.filePath/.hit.score) directly against the source files.
    - plan.md: appended a new "## Manager (multi-root workspaces)" section at the end recording the agreed design: git repo = the project unit (RootDiscovery, no marker fallback), three entry points (discovery+explicit open, direct context(for:), lazy context(containing:)) over one open-or-get core (createStartAndRegister gated by the overlap check + inFlightOpens dedupe), the overlap rule (descendant -> ancestor's context; ancestor of open/still-opening roots -> CodeContextError.overlappingRoot), keep-all-started lifecycle (close/shutdown are the only ways down), fan-out + merge with partial failure (TaskGroup, Rooted<Value>, FanOutFailure, rank-major interleave merge rule and why score isn't comparable across roots), and ManagerState aggregation with vacuous-ready isReady semantics.

    Verification: `swift build` exit 0 (only the pre-existing unrelated mlx-swift_Cmlx bundle-plugin warning, nothing attributable to this change). `swift test` 485/485 passing. This is a docs-only change (README.md, plan.md) with no source diff, so the really-done adversarial double-check gate was skipped per its own "skip if there is no diff" rule.

    Leaving task in doing for /review.
  timestamp: 2026-07-15T20:56:21.304926+00:00
- actor: claude-code
  id: 01kxks9fy593nyappj5rvzhxvw
  text: |-
    ## Review Findings (2026-07-15 16:00)

    Scope: `HEAD~1..HEAD` (ae24c52 "docs: document two entry points in README and plan.md")

    Nothing in scope to review.

    - [x] No findings — docs-only diff (README.md "Two ways in" section, plan.md "Manager (multi-root workspaces)" design section); no source changed.

    Verdict: clean.
  timestamp: 2026-07-15T21:00:29.509323+00:00
depends_on:
- 01KXK6VNT8YNZYEJB0KMM19ANQ
- 01KXK6W5F2XDBQ3SKG8FTZTRPW
- 01KXK6WVQ6584D77AK33NFTMJZ
position_column: done
position_ordinal: ac80
title: 'Document the two entry points: README section and plan.md design addendum'
---
## What
Document that the package now has two first-class ways in, and record the manager's design rationale where the codebase keeps its design record.

- `README.md`: add a "Two ways in" (or similarly named) section: standalone `CodeContext` for one repo (existing example stays) and `CodeContextManager` for multiple repos — a short manager usage snippet (discover → open → fan-out search with `Rooted` results) kept consistent with `Examples/ManagerExample/main.swift` so the shipped example is the compile-verified twin of the README snippet. Link both `Examples/` programs.
- `plan.md`: append a manager design section matching the style of the existing document, recording the agreed decisions the doc comments will reference: git repo = the project unit; three entry points over one open-or-get core; overlap rule (descendant → ancestor's context, ancestor of open roots → `overlappingRoot` error); keep-all-started lifecycle; fan-out + merge with partial failure; `ManagerState` aggregation with vacuous-ready semantics.

## Acceptance Criteria
- [x] README shows both entry points with working snippets that match the example programs' code
- [x] plan.md records the manager design decisions listed above
- [x] No stale claims: README/plan.md statements match the shipped API names and behavior

## Tests
- [x] `swift build` and `swift test` still pass (docs-only change; the example targets are what keep the snippets honest)

## Workflow
- Docs task: verify snippets against the built examples rather than TDD.