---
comments:
- actor: wballard
  id: 01kwsvvnvs10fyf9qnnfg709rn
  text: |-
    Research complete before writing LiveSourceKitTests.swift:
    - `CodeContext.definition(filePath:line:character:includeSource:)` returns `DefinitionResult{ locations, sourceLayer }` (both `internal`, visible via @testable). `sourceLayer == .liveLSP` only when the routed `LspSession` is non-nil AND the live LSP request returns non-empty locations (see `LiveOpsCore.liveDefinition`); any live-layer error/empty falls through to the indexed layers, never throws.
    - `state.servers` is `[ServerStatus]` (`command`, `state: LSPDaemonState`); `LSPDaemonState.running(pid:)`/`.failed(reason:attempts:)` carry exactly the evidence needed - no log scraping required. `context.lspStatus()` is the public accessor.
    - `SwiftLanguage.languageServer` (sourcekit-lsp) uses the default `healthCheckInterval` of 60s (no override) - so after `kill -9`, the supervisor's health loop won't notice until its next 60s-cadence check, then sleeps `backoffDuration(attempt:0)` (1s) before restarting. Budgeted the restart-evidence poll at up to 150s real time to comfortably cover a worst-case ~60s detection window + spawn/handshake, matching the task's "generous timeouts" / "several minutes" allowance.
    - No existing precedent for env-gated tests in this codebase (grepped for `.enabled(if:)`/`.disabled(if:)` - none). Confirmed via websearch that Swift Testing's `ConditionTrait.enabled(if:_:)` accepts a runtime-evaluated autoclosure plus an optional `Comment`, and can be applied at `@Suite` level - this reports a real "skipped" status (not just a vacuous pass), which is a better fit for the acceptance criteria ("suite reports skipped, exit 0") than the "return early from the test body" fallback idiom. Using `.enabled(if:)` at the suite level for `CCK_LIVE_LSP`, and again at the `@Test` level for the synchronous `which sourcekit-lsp`-equivalent PATH check (so a gated-in machine with no Xcode still reports skipped, not failed).
    - Reusing `withTemporaryWorkspace`/`write` (TestSupport.swift) and `FakeEmbedder` (Support/FakeEmbedder.swift). Building a real `Package.swift` + `Sources/Fixture/Greeter.swift` fixture (unlike `CodeContextE2ETests`' marker-less fixture) so `ProjectDetection` actually spawns a `sourcekit-lsp` daemon.
    - Mirroring `ConnectionTests.swift`'s `withConnection` guaranteed-cleanup pattern with a `withLiveContext` helper that calls `context.stop()` on every exit path (success or throw), to avoid re-introducing the leaked-process/thread class of bug fixed earlier this session.
    - Using the internal `CodeContext<ProcessLanguageServerConnection>` initializer with a custom `connectionFactory` (mirroring `LSPDaemon.processConnectionFactory` but with a longer per-request timeout than the 30s production default) since the very first live `textDocument/definition` request can race sourcekit-lsp's background package-graph resolution on a cold start.
    Proceeding to write the test now.
  timestamp: 2026-07-05T19:25:07.321150+00:00
- actor: wballard
  id: 01kwswkz6hz79arsvzn0g8t1vy
  text: |-
    Implemented Tests/FoundationModelsCodeContextTests/LiveSourceKitTests.swift. Verification results:
    1. `swift build --build-tests` and plain `swift build`: clean, zero warnings/errors introduced by this file (only the pre-existing unrelated `mlx-swift_Cmlx.bundle` "missing creator for mutated node" build-system warning, present before this task too).
    2. Ungated: `swift test --filter LiveSourceKitTests` -> `Suite LiveSourceKitTests skipped: "gated behind CCK_LIVE_LSP=1"`, exit 0, 0.001s. Meets "without CCK_LIVE_LSP=1, suite reports skipped, exit 0."
    3. Gated: `CCK_LIVE_LSP=1 timeout 300 swift test --filter LiveSourceKitTests` -> **passed for real** in 63.4s: real sourcekit-lsp spawned against a temp SwiftPM fixture, settled to `state.isReady`, live `definition()` returned `.liveLSP`, `kill -9` on the daemon's real pid, supervisor's health loop (60s cadence, no override on `SwiftLanguage.languageServer`) detected the dead process, transitioned through `.failed(attempts: 1)` (asserted from `state.servers`, not logs), backed off 1s, and successfully respawned+re-handshook under a fresh pid, then a second live `definition()` call again returned `.liveLSP`. All within one run, one `@Test`.
    4. Verified zero leaked processes after both the gated run and after a full ungated `swift test` (see below) via `ps aux | grep -Ei "sourcekit-lsp|swiftpm-testing-helper"` - empty both times.
    5. Attempted one full, ungated `swift test` wrapped in `timeout 600` per instructions: it hit the pre-existing, separately-tracked intermittent full-suite hang (^vhcye6y, filed before this task, unrelated to this change - LiveSourceKitTests wasn't even part of that run since CCK_LIVE_LSP wasn't set). Did not chase/root-cause it further per the task's explicit guidance; confirmed no leaked processes remained afterward regardless.

    Design decisions worth recording:
    - Used Swift Testing's `.enabled(if:_:)` trait (suite-level for the `CCK_LIVE_LSP` gate, test-level for the `sourcekit-lsp`-on-`$PATH` check) rather than an in-body early return, since it reports a genuine "skipped" status instead of a vacuous pass - a better fit for the literal acceptance criteria wording.
    - Used the internal `CodeContext<ProcessLanguageServerConnection>` initializer with a custom connection factory (90s per-request timeout vs. the 30s production default) since the very first live request can race sourcekit-lsp's cold-start package-graph resolution; this did not end up being needed in practice (the observed run answered well under that), but keeps headroom for a slower/loaded machine.
    - `withLiveContext` guarantees `context.stop()` on every exit path (mirrors `ConnectionTests.swift`'s `withConnection`), and this was verified empirically: no leaked `sourcekit-lsp`/`swiftpm-testing-helper` processes after either run.

    Task remains in `doing` for review per the implement skill's contract (not moving to review/done myself).
  timestamp: 2026-07-05T19:38:23.313209+00:00
- actor: wballard
  id: 01kwswxrbxevyvf0ym3xv2wqd6
  text: |-
    Adversarial double-check verdict: PASS. Verified independently: fixture line/character math (line 2, "helper" spans columns 15-20, `fixtureCallCharacter=17` lands mid-token), the early-return `guard`/`Issue.record` branch inside `withLiveContext`'s body still lets `context.stop()` run (the `return` only exits the inner closure, not `withLiveContext` itself), the 150s restart-evidence budget comfortably covers the worst-case ~60s health-check cadence + backoff + handshake, and all type/signature usages (`CodeContext` internal init, `ProcessLanguageServerConnection.init`, `lspStatus()`, `LSPDaemonState` cases, `SourceLayer.liveLSP`) match production code exactly. Two minor non-blocking notes: (1) `LSPDaemon.processConnectionFactory(clock:)` could optionally take a `requestTimeout` param to let this test reuse it directly instead of a parallel factory - small DRY opportunity, not required; (2) the ungated full-suite `swift test` run wasn't cleanly demonstrated green this session because it hit the pre-existing, separately-tracked ^vhcye6y intermittent hang (unrelated to this file - confirmed no processes leaked regardless). Proceeding with the PASS as-is; not fixing either non-blocking note in this task's scope.

    Task complete and left in `doing` for /review, per the implement skill's contract.
  timestamp: 2026-07-05T19:43:43.997520+00:00
- actor: wballard
  id: 01kwsxrhp51exgdx0hkpa3qpdf
  text: 'Round 1 review (scope: HEAD~1..HEAD, commit a09fbf4) — clean. Engine attempted 15 checks across design/reuse/correctness/tests/security/clarity/performance/swift validators, 0 findings. Scope is entirely new: Tests/FoundationModelsCodeContextTests/LiveSourceKitTests.swift. Moved doing -> review -> done.'
  timestamp: 2026-07-05T19:58:21.893229+00:00
depends_on:
- 01KWJ3YW2ZK0J862WBYDY8WF8X
position_column: done
position_ordinal: 9d80
title: Gated live sourcekit-lsp integration smoke (crash/restart)
---
## What
Create `Tests/FoundationModelsCodeContextTests/LiveSourceKitTests.swift` — the real-server end-to-end smoke from plan.md testing strategy, gated on env `CCK_LIVE_LSP=1` (suite skips otherwise, so CI without the gate stays green). Against a temp swift fixture package using the real `sourcekit-lsp` from the active toolchain: `CodeContext.start()` → await `state.isReady` server-settled → `definition` on a known symbol returns `.liveLSP` → read the daemon pid from `state.servers` and `kill -9` it → assert the supervisor auto-restarts (state transitions failed → running, restart counter incremented) → a post-restart `definition` succeeds again. Generous timeouts; skip (not fail) with a clear message if `sourcekit-lsp` is not on PATH even when gated in.

## Acceptance Criteria
- [ ] Without `CCK_LIVE_LSP=1`, the suite reports skipped, exit 0
- [ ] With the gate on a machine with Xcode: spawn → index → live definition → kill -9 → auto-restart → live definition all pass in one run
- [ ] Restart evidence asserted from `state.servers` (attempts incremented, state running), not from log scraping

## Tests
- [ ] `swift test --filter LiveSourceKitTests` → skipped by default; `CCK_LIVE_LSP=1 swift test --filter LiveSourceKitTests` → passes on a dev machine
- [ ] Run `swift test` (ungated) → whole suite green with the live tests skipped

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.