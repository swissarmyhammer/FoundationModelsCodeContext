---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52bhvn22b3xmwnbtv8ekfn6
  text: |-
    Research done. Facts that the card does not state:
    - `LSPDaemon.shutdown()` sets the state `.notStarted` also for a daemon with no handle (for example a `.notFound` daemon). Thus after `stopLanguageServers()` each server is `.notStarted`.
    - `fakeConnectionFactory` shares one `ProcessState`. A graceful `shutdown()` sets `isAlive = false` through `waitForExit()`. A test that starts the daemon again sets `isAlive` to `true` before the second start, as a new process would be.
    - The daemon constructed hook increments the `Counter` in an unstructured `Task`, thus a test must poll with `waitUntil` before it reads the count.
    - The `CodeContextStartTests` fixtures have no project marker. A test that needs a managed server writes a `Cargo.toml` (the `rust-analyzer` spec). `autoInstall` is off in `makeCodeContext`, thus no real install runs.
  timestamp: 2026-10-16T12:38:52.834174+00:00
- actor: claude-code
  id: 01m52c22c5am3y9v3tck7wpkh0
  text: |-
    Implementation is complete (TDD).
    - RED: `startAfterShutdownStartsTheStoppedDaemonsAgain` failed (no `.running` after the second start, one construction only). `startWhileRunningDoesNotSpawnASecondDaemon` passed before the change, because it guards the dedupe that exists. The two `CodeContextStartTests` tests failed to compile, because `stopLanguageServers` did not exist.
    - GREEN: `spawnAndRegister(specs:)` now also spawns a spec whose entry is stopped (`healthLoopTask == nil`, through the new `isStopped(_:)`), and cancels the old `installTask` before `registerManagedDaemon`. `CodeContext` has `stopLanguageServers()` and `startLanguageServers()`, both `@discardableResult`, and both do nothing when the context is not started.
    - Change to a file that is not in the card list: `Tests/FoundationModelsCodeContextTests/Support/FakeDaemonProcess.swift` gets a `ConstructionLog` helper (a `Mutex` counter). The `Counter` actor needs a `Task` in the synchronous hook, thus a test cannot know when the increment lands. With `ConstructionLog`, the "one construction" assertion is deterministic.
    - Side effect on behavior that already exists: `CodeContext.stop()` followed by `start()`, and a `start()` again after a failed `start()`, now start the stopped servers again. Before this change, those servers stayed `.notStarted`.
    - Note: each build shows the build-system warning `missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS`. It comes from the mlx-swift dependency bundle, not from the files of this card.

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift, Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift, Tests/FoundationModelsCodeContextTests/Support/FakeDaemonProcess.swift; `swift test --filter "LspSupervisorTests|CodeContextStartTests|LiveOpsExtendedTests"` 51 tests in 3 suites passed; `swift test` 861 tests in 78 suites passed, 0 failures
    - next: /review
  timestamp: 2026-10-16T12:47:44.005689+00:00
- actor: claude-code
  id: 01m52c3p6mqxgn58j92pa4y3df
  text: |-
    ### test — green
    - evidence: swift test — 861 tests in 78 suites passed, 0 failed, 0 skipped; 0 warnings from this package (only the mlx-swift dependency warning `missing creator for mutated node`)
    - next: review
  timestamp: 2026-10-16T12:48:37.076237+00:00
- actor: claude-code
  id: 01m52c7y0waxf775fja1zxwj0d
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (4839d45): 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsCodeContext/CodeContext.swift:522 `completeness/inverse-operation-coverage`
    - next: add a CodeContext test that calls start(), stopLanguageServers(), then startLanguageServers(), and asserts that the result and state.servers show rust-analyzer as running. Then review again.
  timestamp: 2026-10-16T12:50:56.156852+00:00
- actor: claude-code
  id: 01m52c8erxev62bfers9p45wmv
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files
    - test: green — swift test, 861 passed
    - commit: 4839d45
    - review: findings — Sources/FoundationModelsCodeContext/CodeContext.swift:522
  timestamp: 2026-10-16T12:51:13.309757+00:00
- actor: claude-code
  id: 01m52cq6w0qj3ej8p5ebghenp8
  text: |-
    Finding `completeness/inverse-operation-coverage` (CodeContext.swift `startLanguageServers()`) is fixed (TDD).

    Cause: the CodeContext tests used the real `rust-analyzer` spec. `LSPDaemon.start()` does `BinaryLookup.resolve` before it calls the connection factory, thus on a machine without `rust-analyzer` the server is `.notFound`. No CodeContext test could then see a running server, and the restart path of the wrapper had no test.

    Fix:
    - New internal seam `ServerSpecsForProjects` (`@Sendable ([DetectedProject]) -> [ServerSpec]`, in `Projects/ProjectDetection.swift`). `LspSupervisor.init` and the internal `CodeContext.init` take `serverSpecs:` with the default `ProjectDetection.serverSpecs(for:)`. `LspSupervisor.performStart()` and `CodeContext.start()` both use the same function, thus the supervisor and the LSP index tasks agree on the servers. The public init does not change.
    - `CodeContextStartTests`: the real project detection and the real Rust spec stay in use. The test mapping only sets the extra search directory of the installer to a temp directory with a fake executable `rust-analyzer`. The fake connection factory does not run that file.
    - Cause removed in the whole file: all three LSP tests now use `makeRustContext(root:binaryDirectory:processState:)`. `stopLanguageServersStopsEachServerAndPublishesTheResult` now also asserts that the server is `.running` before the stop, and it asserts the exact `.notStarted` status.
    - New test `startLanguageServersAfterAStopStartsEachServerAgainAndPublishesTheResult`: start(), stopLanguageServers(), `processState.setAlive(true)`, startLanguageServers(); it asserts the result and `state.servers` equal `[rust-analyzer .running(pid: 1)]`.

    Evidence:
    - RED: compile error, `cannot find type 'ServerSpecsForProjects'` and `extra argument 'serverSpecs'`.
    - GREEN: `swift test --filter CodeContextStartTests` 14 tests passed.
    - The new test can fail: with `publishServersStatus()` removed from `startLanguageServers()`, it failed at `servers == [Self.runningRustServer]`. The line is restored.
    - Determinism: with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` (no `rust-analyzer` on PATH), the 14 tests passed.
    - `swift test`: 862 tests in 78 suites passed. The only warning is the known mlx-swift `missing creator for mutated node` from the dependency bundle.

    Change outside the card file list: `Sources/FoundationModelsCodeContext/Projects/ProjectDetection.swift` (the typealias).
  timestamp: 2026-10-16T12:59:16.736268+00:00
- actor: claude-code
  id: 01m52cqa80abg4nc63bh1zt90k
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsCodeContext/Projects/ProjectDetection.swift, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift; `swift test --filter CodeContextStartTests` 14 passed (also with no rust-analyzer on PATH); `swift test` 862 tests in 78 suites passed, 0 failed
    - next: /review

    ```
    step: implement
    outcome: changed
    evidence: 4 files — Sources/FoundationModelsCodeContext/Projects/ProjectDetection.swift, Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift, Sources/FoundationModelsCodeContext/CodeContext.swift, Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift; swift test --filter CodeContextStartTests 14 passed; swift test 862 tests in 78 suites passed, 0 failed
    task: ^q47ajp6
    ```
  timestamp: 2026-10-16T12:59:20.192986+00:00
- actor: claude-code
  id: 01m52cry099m41weja72crtc2p
  text: |-
    ### test — green
    - evidence: swift test — 862 tests in 78 suites passed, 0 failed, 0 skipped; no warnings from this package (only the mlx-swift dependency warning)
    - next: review
  timestamp: 2026-10-16T13:00:13.193804+00:00
- actor: claude-code
  id: 01m52cw6m1brdb5ekhserd336w
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (62c9e8b). 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. 4 files reviewed. All prior findings are checked.
    - next: The task is in done. The dependent task ^q47ajp6 blocks (01M52B64C34G046TK8PJQ27DXP) can start.
  timestamp: 2026-10-16T13:02:00.321913+00:00
- actor: claude-code
  id: 01m52cwh0vvx3v5tm0vxs6grkz
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 4 files
    - test: green — swift test, 862 passed
    - commit: 62c9e8b
    - review: clean — 0 findings, prior 1/1 checked
  timestamp: 2026-10-16T13:02:10.971435+00:00
position_column: done
position_ordinal: e180
title: 'LSP stop and start: stop the language servers and start them again (engine)'
---
## What

A host must be able to stop the language servers of a workspace and then start them again. A stopped server releases its file locks, thus a build cleanup (for example `swift package clean` or `rm -rf .build`) can run. The index, the watcher and the store continue to operate while the servers are stopped. The auto start and the auto install that `CodeContext.start()` does from project detection do not change.

This card adds the engine API. The card for the `code_index` tool operations depends on this card.

### The problem today

- `LspSupervisor.shutdown()` (`Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift`) cancels the health loop task and the install task of each daemon, then shuts down each daemon. It keeps each entry in `managedDaemons` in the state `.notStarted`, with `healthLoopTask == nil`.
- `LspSupervisor.start()` -> `performStart()` -> `spawnAndRegister(specs:)` skips each spec whose command is in `managedDaemons` (`specs.filter { managedDaemons[$0.command] == nil }`). Thus after `shutdown()`, a second `start()` starts no server.
- `CodeContext` (`Sources/FoundationModelsCodeContext/CodeContext.swift`) calls `supervisor.shutdown()` only from `stop()`, which also stops the index loop, the LSP index tasks and the watcher. No public API stops only the servers.

### The approach

- [x] In `LspSupervisor.spawnAndRegister(specs:)`, also spawn a spec whose entry is stopped. A stopped entry is an entry with `healthLoopTask == nil` (only `shutdown()` sets it to `nil`). Replace the stopped entry with the new daemon through `registerManagedDaemon(spec:daemon:)`, and cancel its old `installTask` first, as `insertDaemonForTesting(spec:daemon:)` does. Update the doc comments of `start()` and `shutdown()`: a `start()` after `shutdown()` starts the stopped servers again. The `inFlightStart` coalescing does not change.
- [x] Add `public func stopLanguageServers() async -> [ServerStatus]` to `CodeContext`. It calls `supervisor.shutdown()`, then `publishServersStatus()`, then gives `lspStatus()`. It does not cancel `lspIndexTasks`: `LSPIndexWorker.run` sleeps for `sessionUnavailableSleep` while `sessionProvider()` gives `nil`, and it continues when the servers start again. When the context is not started, the call does nothing and gives `lspStatus()`.
- [x] Add `public func startLanguageServers() async throws -> [ServerStatus]` to `CodeContext`. It calls `supervisor.start()` (a new project detection, thus a new project marker also gets its server, and a missing binary gets the auto install), then `publishServersStatus()`, then gives `lspStatus()`. When the context is not started, the call does nothing and gives `lspStatus()`. It rethrows the project detection errors of `LspSupervisor.start()`.
- [x] Write the doc comments in ASD-STE100 Simplified Technical English, in the style of the file.

Files: `Sources/FoundationModelsCodeContext/LSP/LspSupervisor.swift`, `Sources/FoundationModelsCodeContext/CodeContext.swift`, `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift`, `Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift`.

## Acceptance Criteria

- [x] After `LspSupervisor.shutdown()`, a call to `startForTesting(specs:)` (the same `spawnAndRegister(specs:)` path as `start()`) starts each stopped daemon again: `status()` gives `.running(pid:)` for it, and the daemon constructed hook counts a second construction.
- [x] A second `startForTesting(specs:)` while the daemons run constructs no second daemon for a command (the dedupe by command stays).
- [x] `CodeContext.stopLanguageServers()` after `start()` gives no server in a state other than `.notStarted`, and `state.servers` is equal to the result.
- [x] Before `start()` and after `stop()` of the context, `stopLanguageServers()` and `startLanguageServers()` throw no error and give the same value as `lspStatus()`.
- [x] The existing tests of `LspSupervisorTests`, `CodeContextStartTests` and `LiveOpsExtendedTests` pass.

## Tests

- [x] `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift`: add `startAfterShutdownStartsTheStoppedDaemonsAgain`. Use `startForTesting(specs: [Self.serverSpec(command: "true")])` with `fakeConnectionFactory`, expect `.running`, call `shutdown()`, expect `.notStarted`, call `startForTesting` again, expect `.running` again. Use `setDaemonConstructedHookForTesting` to count two daemon constructions.
- [x] `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift`: add `startWhileRunningDoesNotSpawnASecondDaemon`. Call `startForTesting` two times without `shutdown()`, and expect one daemon construction.
- [x] `Tests/FoundationModelsCodeContextTests/CodeContextStartTests.swift`: add a test that `stopLanguageServers()` and `startLanguageServers()` before `start()` and after `stop()` give `lspStatus()` and throw no error. Add a test that after `start()`, `stopLanguageServers()` gives no server in a state other than `.notStarted`, and that `state.servers` is equal to the result.
- [x] Run `swift test --filter "LspSupervisorTests|CodeContextStartTests|LiveOpsExtendedTests"`. All tests pass.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #lsp #feature

## Review Findings (2026-10-16 07:49)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsCodeContext/CodeContext.swift:522` `completeness/inverse-operation-coverage` — The new public startLanguageServers() restarts servers after stopLanguageServers(), but no CodeContext-level test runs that pair. The start wrapper is never checked while it has a running server. Only the supervisor is tested for a restart, so a bug in this wrapper (for example, a missing publish) would pass the tests. Add one CodeContext test: write the Cargo marker, call start(), call stopLanguageServers(), then call startLanguageServers(). Assert that the returned statuses and context.state.servers show rust-analyzer as running. Then call stop().
