---
comments:
- actor: wballard
  id: 01kwk1xhh36xg89p6ps8bafefq
  text: |-
    Implemented Sources/FoundationModelsCodeContext/LSP/LspSession.swift as `actor LspSession<Connection: LanguageServerConnection>`:
    - `DocState(version, textHash)` open-document set; `syncOpen(uri:text:)` dedupes opens/no-op changes by hash compare (Swift `Hasher`, process-local, mirrors Rust's DefaultHasher use).
    - `DiagnosticUpdate(uri:diagnostics:)` (new type) fed by both push (`consumeServerNotifications()`, a background Task started in `init`, draining `connection.serverNotifications`) and pull (`pullDiagnostics(uri:)`), through one shared `recordDiagnostics` write path into `diagnosticsCache` + fan-out.
    - Multi-subscriber fan-out: Swift `AsyncStream` only supports one iterator per stream, so `diagnosticUpdates()` hands each subscriber its own `AsyncStream` backed by its own continuation, tracked in an actor-isolated `[Int: Continuation]` dictionary keyed by an incrementing id; `onTermination` removes the entry when a subscriber's stream is cancelled/dropped.
    - `isReady` flips false on `WireError.serverError` with code -32802 (ServerCancelled) or -32801 (ContentModified), true again on the next clean pull; a not-ready pull does NOT cache/broadcast (matches Rust "don't let a consumer read still-loading as clean").
    - `resetDocuments()` clears both the doc set and the diagnostics cache (restart correctness).

    Deviation worth flagging: `notificationConsumerTask` is `private nonisolated(unsafe) var`. Swift actor initializers reject writing an actor-isolated stored property once a closure in the same init has captured `self` (even weakly) — "cannot access property here in nonisolated initializer". Since starting the background notification-consumer Task in `init` requires capturing `self`, the task handle has to live in a nonisolated slot. It's safe: written once in `init` before the closure can run, and only ever read/cancelled from `deinit` (which cannot race with any other actor access). Documented inline.

    Path/URI design: chose `DocumentURI` (not a raw path/`URL`) as `syncOpen`'s and `pullDiagnostics`'s parameter type, matching every other `LanguageServerConnection` method's signature — no existing path-to-URI helper existed anywhere in the codebase to reuse, and `pullDiagnostics(uri:)` was spelled out exactly that way in the task description.

    Also added a small additive method `FakeLanguageServerConnection.setPullDiagnosticsResult(_:)` (Tests/FoundationModelsCodeContextTests/Support/FakeLanguageServerConnection.swift) so tests can script the pull outcome across the actor boundary — did not touch any existing method/property on the fake.

    Tests: Tests/FoundationModelsCodeContextTests/LspSessionTests.swift, 15 tests (dedupe, versioning, no-op-change suppression, push cache+multi-subscriber fanout, pull cache, readiness flip on both -32802/-32801, readiness recovery, genuine-error propagation leaving isReady/cache untouched, terminated-subscriber cleanup from the fan-out set, reset semantics for both the doc set and the diagnostics cache). All pass; `swift test` full suite is green at 194/194 (was 192 before this task). `swift build` clean, no new warnings.

    Process note: tests were written before the implementation (compile-failure RED was implicit — LspSession.swift didn't exist yet — rather than an explicitly observed `swift test` RED run before writing code). Ran `mcp__sah__review` (0 findings) and a `double-check` adversarial pass; it flagged two coverage gaps (genuine pull-error propagation, subscriber-cleanup-on-termination) which are now covered by the two tests added above.
  timestamp: 2026-07-03T03:56:18.851272+00:00
- actor: wballard
  id: 01kwk2ztvarbbbf0g1qp1fyjeh
  text: |-
    Resolved the 2026-07-02 23:07 review finding: added `pullDiagnosticsReachesEverySubscriber` to Tests/FoundationModelsCodeContextTests/LspSessionTests.swift (placed right after `pullDiagnosticsFeedsTheSameCacheAsPush`), mirroring `publishDiagnosticsNotificationReachesEverySubscriber`'s pattern. It registers two subscribers via `diagnosticUpdates().makeAsyncIterator()`, scripts `FakeLanguageServerConnection.setPullDiagnosticsResult(.success([...]))`, calls `pullDiagnostics(uri:)`, and asserts both subscriber streams receive the `DiagnosticUpdate` (not just that `diagnostics(for:)`/the return value reflects it) — proving `pullDiagnostics` fans out through the same `recordDiagnostics()` path as push, not just the shared cache.

    Flipped the review checklist item to `- [x]`.

    Verification: `swift test --filter LspSessionTests` → 16/16 pass (was 15). Full `swift test` → 195/195 pass in 13 suites (was 194). `swift build` clean (only a pre-existing, unrelated warning about a third-party mlx-swift bundle). Adversarial double-check agent independently re-ran both the filtered and full suite and returned PASS with no findings.

    Leaving in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-03T04:15:02.506230+00:00
- actor: wballard
  id: 01kwk3f505438dn1077mqq820g
  text: 'Implemented LspSession actor (document dedupe by hash, per-URI diagnostics cache, multi-subscriber AsyncStream fanout via continuation registry, readiness state machine on ServerCancelled/ContentModified), tested against FakeLanguageServerConnection, checkpointed (135efdc). 1 review/fix cycle: added missing pullDiagnostics-fans-out-to-subscribers regression test (135efdc→75c0152). Final review clean (one pre-existing-test naming nit correctly dropped per the never-touch-existing-tests rule), moved doing → review → done.'
  timestamp: 2026-07-03T04:23:24.421553+00:00
depends_on:
- 01KWJ3RB07JNW5QXZNH1ESMH2F
position_column: done
position_ordinal: 8a80
title: 'LspSession actor: document sync, diagnostics cache, readiness'
---
## What\nCreate `Sources/FoundationModelsCodeContext/LSP/LspSession.swift` — port of `crates/swissarmyhammer-lsp/src/session.rs` as an actor over a `LanguageServerConnection`. Open-document set with `DocState(version, textHash)`; `syncOpen(path, text)` opens-or-refreshes, suppresses duplicate opens and no-op changes by hash compare; consumes `serverNotifications` to maintain a per-URI diagnostics cache fanned out via `AsyncStream<DiagnosticUpdate>` (multi-subscriber); `pullDiagnostics(uri:)`; `isReady` flag flipped false on ServerCancelled/ContentModified \"still loading\" replies and true on clean responses; `resetDocuments()` clears the doc set and cache (restart correctness).\n\n## Acceptance Criteria\n- [x] Two `syncOpen` calls with identical text send exactly one didOpen and zero didChange (fake connection records calls)\n- [x] Push diagnostics from the notification stream land in the cache and reach all stream subscribers\n- [x] After `resetDocuments()`, the next `syncOpen` re-sends didOpen (not suppressed)\n\n## Tests\n- [x] `Tests/FoundationModelsCodeContextTests/LspSessionTests.swift` using `FakeLanguageServerConnection`: dedupe, versioning, cache+fanout, readiness flip on ContentModified, reset semantics\n- [x] Run `swift test --filter LspSessionTests` → all pass\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-02 23:07)\n\n- [x] `Tests/FoundationModelsCodeContextTests/LspSessionTests.swift:103` — Pull diagnostics should broadcast to subscribers via `diagnosticUpdates()` just like push diagnostics do (both call `recordDiagnostics()`), but there is no test exercising pull + subscribers together. The test `publishDiagnosticsNotificationReachesEverySubscriber` verifies push reaches all subscribers, but no test verifies pull reaches subscribers, creating an untested inverse operation. Add a test that creates one or more subscribers via `diagnosticUpdates()`, calls `pullDiagnostics()`, and verifies the subscribers receive the DiagnosticUpdate broadcasts, mirroring the push test pattern.\n