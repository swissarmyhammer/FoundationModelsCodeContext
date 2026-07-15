---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxke5h8tm5exvjnz1c2kx6x3
  text: |-
    Implemented CodeContextManager actor per spec:
    - Sources/FoundationModelsCodeContext/CodeContextManager.swift (new): public actor CodeContextManager<Connection>, internal init(embedder:clock:eventSource:connectionFactory:), public convenience init(embedder:) where Connection == ProcessLanguageServerConnection. contexts/inFlightOpens dicts keyed by standardized root URL. context(for:) implements exact-match / descendant-returns-ancestor / ancestor-throws-overlappingRoot / create-start-register, with per-root Task dedup mirroring LspSupervisor.inFlightStart. context(containing:openIfNeeded:) does longest-prefix-match against open roots first, else RootDiscovery.gitRoot + optional lazy open. close(root:) and shutdown().
    - Sources/FoundationModelsCodeContext/CodeContextError.swift: added case overlappingRoot(String) + errorDescription.
    - Tests/FoundationModelsCodeContextTests/CodeContextManagerTests.swift (new): 13 tests covering every acceptance criterion (same-root identity, concurrent dedupe, descendant/ancestor overlap rule, sibling-prefix confusion guard, context(containing:) resolution order incl. openIfNeeded=false and outside-any-repo, failed-start non-registration + retry, close/shutdown bookkeeping).

    Verification: `swift build` exit 0. `swift test --filter CodeContextManagerTests` 13/13 passed. Full `swift test` 477/477 passed, 0 failures, exit 0. Adversarial double-check agent dispatched for sign-off.
  timestamp: 2026-07-15T17:46:05.466191+00:00
- actor: claude-code
  id: 01kxkf3fqbzarqktrtaw161jcz
  text: |-
    Adversarial double-check (round 1) found a genuine cross-root race: `context(for:)`'s overlap checks only scanned `contexts` (fully-registered roots), not `inFlightOpens` (roots mid-open, not yet registered). Two concurrent opens of a brand-new parent + a brand-new nested child could both pass the check and each build+start its own CodeContext, producing two live overlapping contexts — a real violation of the "strict non-overlapping-roots invariant" the class documents.

    Fix: added `inFlightOpen(ancestorOf:)` and `inFlightRoots(descendantsOf:)` helpers mirroring the existing `contexts`-based ones, and wired them into `context(for:)`'s exact-match / ancestor / descendant-conflict checks (all still synchronous, no `await` between the checks and staking the `inFlightOpens` claim, so the check-then-claim sequence stays atomic within one actor turn). Added regression test `concurrentOpensOfNestedBrandNewRootsNeverProduceTwoLiveOverlappingContexts` (opens brand-new parent+child concurrently, accepts either "both resolve to the same context" or "one throws overlappingRoot", rejects both-fail or two-distinct-contexts). Ran the regression test 5x back-to-back plus in the full suite — deterministic pass every time (the pre-fix code would have failed this test reliably, not flakily, since the old bug triggers on the first suspension point).

    Adversarial double-check round 2 (bounded, final per really-done): PASS. Traced both possible actor-scheduling orderings by hand, confirmed no deadlock (createStartAndRegister never calls back into context(for:)), confirmed no stale-entry false-negative (contexts is always checked before inFlightOpens, and the descendant-conflict check unions both dictionaries), confirmed the regression test would have deterministically caught the old bug. One noted non-blocking observation: the test's both-failure branch assumes start() can't legitimately fail for unrelated reasons, which holds today since fixtures use deterministic fakes.

    Final verification: `swift build` exit 0. Full `swift test`: 478/478 passed, exit 0 (477 pre-existing + 1 new regression test; the 13 CodeContextManagerTests grew to 14).

    Files:
    - Sources/FoundationModelsCodeContext/CodeContextManager.swift (new)
    - Sources/FoundationModelsCodeContext/CodeContextError.swift (added .overlappingRoot case)
    - Tests/FoundationModelsCodeContextTests/CodeContextManagerTests.swift (new, 14 tests)

    Leaving task in doing, green, ready for /review.
  timestamp: 2026-07-15T18:02:26.923794+00:00
depends_on:
- 01KXK6SY8JZME3N2WJM7CKSAE4
- 01KXK6T61DT9BJR17ZF798KKE4
position_column: doing
position_ordinal: '80'
title: 'Add CodeContextManager actor: open-or-get lifecycle, routing, overlap rule'
---
## What
Create `Sources/FoundationModelsCodeContext/CodeContextManager.swift`: `public actor CodeContextManager<Connection: LanguageServerConnection>`, mirroring `CodeContext`'s visibility pattern — an internal general initializer `init(embedder:clock:eventSource:connectionFactory:)` (stores the factory/clock/eventSource used for every context it creates, so tests inject `FakeLanguageServerConnection`/`FakeFileEventSource`/`ManualClock`), plus the only public initializer in an `extension CodeContextManager where Connection == ProcessLanguageServerConnection { public init(embedder: TextEmbedding) }`.

**CodeContext stays public and unchanged** — the manager builds on it, never wraps or hides it; every accessor below hands back the real `CodeContext` instance.

State: `private var contexts: [URL: CodeContext<Connection>]` keyed by standardized root URL; `private var inFlightOpens: [URL: Task<CodeContext<Connection>, Error>]` so concurrent opens of the same root dedupe to one create+start (same pattern as `LspSupervisor.inFlightStart`); `public nonisolated let state: ManagerState`.

API (keep-all-started lifecycle — every successful open has already run `start()`):
- `public func context(for root: URL) async throws -> CodeContext<Connection>` — standardize the URL, then apply the overlap rule: exact match → return existing; `root` is a **descendant** of an open root → return that ancestor's context (its walker already covers the subtree); `root` is an **ancestor** of one or more open roots → throw the new `CodeContextError.overlappingRoot(String)` naming the conflicting children (caller must close them first). Otherwise create a `CodeContext` via the stored internal pieces, `try await start()` it (on failure: do not register; rethrow), register in `contexts`, and `await state.publishOpened(root:state:)` with the context's `state`. Accepts any directory, git repo or not — non-git workspaces are an explicit-open feature.
- `public func context(containing path: URL, openIfNeeded: Bool = true) async throws -> CodeContext<Connection>?` — longest-prefix match against open roots first (never throws on that path); else `RootDiscovery.gitRoot(containing: path)` and, if found and `openIfNeeded`, route through the throwing `context(for:)`; else nil.
- `public func close(root: URL) async` — `stop()` the context, remove it, `publishClosed`. No-op for unknown roots.
- `public func shutdown() async` — close every open context.

Descendant/ancestor checks compare standardized paths with a trailing-separator prefix test (so `/a/foo-bar` is not treated as inside `/a/foo`).

Add `case overlappingRoot(String)` to `CodeContextError` (`Sources/FoundationModelsCodeContext/CodeContextError.swift`) with an `errorDescription` entry, following the existing String-payload convention.

## Acceptance Criteria
- [ ] `context(for:)` on the same root twice returns the identical instance (`===`) and starts it once
- [ ] Concurrent `context(for:)` calls for one root create exactly one context
- [ ] Opening a descendant of an open root returns the ancestor's context; opening an ancestor of open roots throws `.overlappingRoot`
- [ ] Path-prefix check does not confuse sibling dirs sharing a name prefix
- [ ] `context(containing:)` resolves via open roots first, lazily opens via `gitRoot` when `openIfNeeded`, returns nil otherwise / outside any repo
- [ ] A failed `start()` leaves the manager unregistered for that root and the error propagates
- [ ] `close`/`shutdown` stop contexts and update `state`; `state.contexts` mirrors open roots throughout

## Tests
- [ ] `Tests/FoundationModelsCodeContextTests/CodeContextManagerTests.swift` driving the internal initializer with the existing Support fakes (`FakeLanguageServerConnection` factory, `FakeFileEventSource`, `FakeEmbedder`) over temp-dir repo fixtures, covering every acceptance criterion including the concurrent-open dedupe
- [ ] `swift test --filter CodeContextManagerTests` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.