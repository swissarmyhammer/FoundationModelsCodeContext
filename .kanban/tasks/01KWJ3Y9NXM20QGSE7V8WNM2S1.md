---
comments:
- actor: wballard
  id: 01kwsfzzdza55msc7y6nag91j9
  text: |-
    Implementation complete, TDD followed (RED confirmed via compile failure, then GREEN).

    Created Sources/CodeContextKit/Ops/LiveOpsExtended.swift with the five remaining v1 live ops:
    - codeActions(session:rootDirectory:filePath:startLine:startCharacter:endLine:endCharacter:diagnostics:only:) — live-only cascade (codeAction + resolve-every-action), sourceLayer .liveLSP/.none via LiveOpsCore.cascade with a constant-nil indexed layer (documented why: no persisted equivalent for ephemeral code actions).
    - renameEdits(session:rootDirectory:filePath:line:character:newName:) — prepareRename+rename executed atomically via a new LspSession.prepareRenameAndRename(uri:at:newName:) that holds a private FIFO async lock (acquireRenameLock/releaseRenameLock) across both calls, so two concurrent renameEdits callers never interleave their prepare/rename pairs on the connection. Degrades to canRename:false (never throws) for: no session, server says not-renameable (rename never even called in that case), or any connection failure. No sourceLayer (documented: rename has no "which layer" concept).
    - inboundCalls(store:session:rootDirectory:filePath:line:character:) — cascades live (prepareCallHierarchy+incomingCalls) -> lspIndex (reuses LayeredContext.lspCallersOf/lspSymbolRow, same query LiveOpsCore.references' own lspIndex layer already uses) -> none. No treeSitter layer (documented: would duplicate references' own text-search layer with no new value).
    - workspaceSymbols(supervisor:rootDirectory:query:) — routes via supervisor.anySession() (document-less), live-only, empty (never error) on no session/failure.
    - lspStatus(supervisor:) — thin wrapper over supervisor.status().

    Supporting changes:
    - LiveOpsCore.swift: dropped `private` from `cascade`, `syncLiveDocument`, `pointRange` so LiveOpsExtended can reuse them (documented why in each doc comment) instead of duplicating.
    - LspSession.swift: added incomingCalls/codeActions/resolveCodeAction/workspaceSymbols wrappers (previously missing) + the new prepareRenameAndRename with its rename lock.
    - Wire.swift: added Equatable to TextEdit/WorkspaceEdit/CodeActionCommand/CodeActionItem (needed since LiveOpsExtended's result types embed them directly and require Codable&Sendable&Equatable).
    - LSPDaemon.swift/LspSupervisor.swift: added Codable to LSPDaemonState/ServerStatus (needed for LspStatusResult to be Codable, reusing these types directly rather than duplicating a DTO).
    - FakeLanguageServerConnection.swift: added missing scripting setters (setIncomingCallsResult, setPrepareRenameResult, setRenameResult, setCodeActionsResult, setResolveCodeActionResult, setWorkspaceSymbolsResult) plus a renameCallHook mechanism used specifically to prove the rename lock's atomicity under genuine concurrency (not just sequential calls).

    Verification: manually confirmed the atomicity test is not vacuous — temporarily disabled the lock (commented out acquire/release in prepareRenameAndRename), re-ran the specific test, it failed exactly as expected (interleaved P,P,R,R pattern), then restored the lock and reconfirmed green.

    Test results: `swift test --filter LiveOpsExtendedTests` -> 13/13 pass. Also ran the broader related suite `swift test --filter 'LiveOpsExtendedTests|LayeredOpsTests|LspSessionTests|LspSupervisorTests|WireTests|LSPDaemonTests|LSPIndexWorkerTests'` -> 155/155 pass. Zero build warnings (`swift build` and `swift build --build-tests` both clean).

    One full-suite `swift test` run (900s timeout) did not finish in time — consistent with the separately-tracked unrelated intermittent full-suite hang (^vhcye6y per task instructions); not investigated further per explicit guidance, filtered suites used as the reliable gate instead. Killed lingering swiftpm-testing-helper processes afterward.

    Dispatched the double-check adversarial review agent per really-done; awaiting its verdict before final handoff.
  timestamp: 2026-07-05T15:57:45.279033+00:00
- actor: wballard
  id: 01kwsg6zht9r9k9heq918ar09w
  text: |-
    Adversarial double-check agent verdict: PASS, no findings.

    It independently re-verified the rename-lock atomicity claim by itself temporarily removing the acquire/release calls, rebuilding, and re-running the atomicity test — confirmed it fails with the predicted (P,P,R,R) interleaved pattern, then restored the file (byte-identical diff) and reconfirmed the full suite green. It also verified: the FIFO lock has no TOCTOU race (check-then-append happens synchronously before any suspension) and no missed-wakeup (releaseRenameLock hands off directly without clearing renameLockHeld); degradation paths correctly swallow "no session"/empty/connection-failure into non-error results while genuine Store errors still propagate; the inboundCalls LSP-index cascade (lspSymbolRow + lspCallersOf join direction) is correct; the documented judgment calls (why codeActions/inboundCalls carry sourceLayer but renameEdits/workspaceSymbols/lspStatus don't) are reasoned and match the actual code; and the Equatable/Codable additions to Wire.swift/LSPDaemon.swift/LspSupervisor.swift are compiler-synthesized deep comparisons with no blast-radius risk (module-internal exposure only, no public API change).

    Task is done and green. Leaving in `doing` per /implement process — ready for /review.
  timestamp: 2026-07-05T16:01:34.778675+00:00
depends_on:
- 01KWJ3XESQSZF6MJ2YHES8QV65
position_column: doing
position_ordinal: '80'
title: 'Remaining live ops: codeActions, renameEdits, inboundCalls, workspaceSymbols, lspStatus'
---
## What
Create `Sources/CodeContextKit/Ops/LiveOpsExtended.swift` — the remaining five of the ten v1 live ops on the layered cascade: `codeActions(in:at:)` (codeAction + resolve), `renameEdits(in:at:newName:)` — prepareRename + rename executed **under one connection hold** so no other consumer interleaves (port of `lsp_multi_request_batch` semantics; degrade to `canRename: false` when no live layer), `inboundCalls(of:)` (prepareCallHierarchy + incomingCalls), `workspaceSymbols(query:)` via `anySession()` (document-less), and `lspStatus()` snapshot from the supervisor. All results `Codable & Sendable` with `sourceLayer` where the cascade applies.

## Acceptance Criteria
- [ ] renameEdits issues prepareRename and rename with no interleaved calls on the fake connection (call-order recording proves atomicity)
- [ ] renameEdits with no live session returns `canRename: false` (not an error)
- [ ] workspaceSymbols works with any running session; lspStatus reflects supervisor daemon states

## Tests
- [ ] `Tests/CodeContextKitTests/LiveOpsExtendedTests.swift` with fake session/supervisor: rename atomicity + degradation, codeAction resolve flow, inboundCalls mapping, workspaceSymbols routing, lspStatus snapshot
- [ ] Run `swift test --filter LiveOpsExtendedTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.