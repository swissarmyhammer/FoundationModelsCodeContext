---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxkc9px5c16ad7fp09dnendp
  text: |-
    Implemented ManagerState in Sources/FoundationModelsCodeContext/ManagerState.swift as a @MainActor @Observable public final class mirroring CodeContextState's conventions: `contexts: [URL: CodeContextState]` keyed by `standardizedFileURL`, computed `roots` (sorted by path) and `isReady` (`contexts.values.allSatisfy(\.isReady)`, vacuously true when empty), and nonisolated async `publishOpened(root:state:)`/`publishClosed(root:)` that hop to the main actor via `MainActor.run`.

    Wrote Tests/FoundationModelsCodeContextTests/ManagerStateTests.swift (TDD, tests written before implementation) covering open/close bookkeeping, standardized-URL keying, sorted roots, SwiftUI observation firing on publish, and isReady aggregation across real CodeContextState children (undrained indexing, unsettled/settled servers, closing the last unsettled root). All 12 tests pass; `swift build` is warning-free.
  timestamp: 2026-07-15T17:13:25.157571+00:00
- actor: claude-code
  id: 01kxkch71yb0basb4amc4t27yh
  text: 'really-done verification: `swift build` clean (0 warnings), full `swift test` suite passed 464/464 tests across 39 suites (0 failures). Adversarial double-check agent returned PASS — confirmed acceptance criteria met, conventions faithfully mirror CodeContextState, no correctness bugs, tests substantive (not tautological). Leaving task in doing, green, ready for /review.'
  timestamp: 2026-07-15T17:17:31.070401+00:00
position_column: doing
position_ordinal: '80'
title: 'Add ManagerState: @Observable aggregate of per-root CodeContextState'
---
## What
Create `Sources/FoundationModelsCodeContext/ManagerState.swift` with a `@MainActor @Observable public final class ManagerState`, mirroring `CodeContextState`'s conventions exactly (all stored properties `private(set)`, mutations only through `nonisolated` async `publish*` methods that hop to the main actor via `MainActor.run` and are awaitable):

- `public private(set) var contexts: [URL: CodeContextState]` — one entry per open root, keyed by standardized root URL.
- `public var roots: [URL]` — computed, sorted by path, for stable SwiftUI iteration.
- `public var isReady: Bool` — computed: `contexts.values.allSatisfy(\.isReady)` (vacuously true when empty; document this the same way `CodeContextState.isReady` documents its vacuous initial state). Because each `CodeContextState` is itself `@Observable`, reading `isReady` inside a SwiftUI view tracks through to every child state.
- `public nonisolated func publishOpened(root: URL, state: CodeContextState) async`
- `public nonisolated func publishClosed(root: URL) async`

## Acceptance Criteria
- [ ] `publishOpened`/`publishClosed` add and remove entries; `roots` stays sorted
- [ ] `isReady` is true when empty, false while any child's indexing/servers are unsettled, true once every child is ready
- [ ] All stored properties are `private(set)`; the only mutation paths are the publish methods

## Tests
- [ ] `Tests/FoundationModelsCodeContextTests/ManagerStateTests.swift`: open/close bookkeeping, sorted `roots`, `isReady` aggregation driven by publishing real `IndexProgress`/`ServerStatus` values into child `CodeContextState` instances (reuse the patterns from the existing `CodeContextState` tests)
- [ ] `swift test --filter ManagerStateTests` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.