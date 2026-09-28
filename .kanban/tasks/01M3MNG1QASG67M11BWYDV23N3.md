---
comments:
- actor: claude-code
  id: 01m3ms0pezmxegew15zv01a7n9
  text: |-
    Research done.
    - swift-log 1.15.1 is resolved. It has the `InMemoryLogging` product (`InMemoryLogHandler`, copies share one store). The test target does not depend on it yet; add `Logging` and `InMemoryLogging` to the test target.
    - `LoggingSystem.bootstrap` can run one time for each process. A `static let` logger keeps the handler of the time of its first use, so a test that bootstraps a capture after an other test used the logger sees nothing. Decision: the members of `Log` become computed properties that make a `Logger` at each use. Thus they read the bootstrapped factory late (the same rule as `CodeContextTracing.tracer(explicit:)`). The content test bootstraps one capture for the process, one time.
    - `InMemoryLogHandler.Entry` does not keep the logger label. The test factory writes the label in the handler metadata.
    - Do not use the `error:` parameter of swift-log: a handler can write the description of the error.
    - `LspSession` has a `failureLog: (String) -> Void` seam, and its line holds `error.localizedDescription` (the server error message). That is content (rule 4). Decision: replace the seam with an injected `Logging.Logger` (default `Log.lsp`), and log a fixed message with metadata: server, request name, error type, JSON-RPC error code, file path. The `context` parameter becomes a `filePath` parameter (each caller has a relative path). Update `LspSessionCapabilityTests` to read an `InMemoryLogHandler`.
    - The vocabulary has no key for: the session request name, the JSON-RPC error code, the installer tool, the exit code of the installer, and the embedding counts and dimensions. Add these keys to `CodeContextTracing.MetadataKey` and to the list in `CodeContextTracingTests`.
    - `ProcessLanguageServerConnection` does not know a server name in its background loops; pass the command to the reader and stderr loops.
  timestamp: 2026-09-28T19:49:06.655315+00:00
- actor: claude-code
  id: 01m3msa2jacadz0z0c1jsjy7n8
  text: |-
    Progress. First, the tests were written and failed as expected (RED: the build failed because the `logger:` parameter of `LspSession` did not exist). Changes done so far:
    - `Log.swift`: swift-log `Logger` members (computed, with the labels of the vocabulary), `Log.errorType(of:)` and `Log.serverFailureMetadata(server:error:)`. `Log.subsystem` is gone.
    - `CodeContextTracing.MetadataKey`: new keys `lspRequest`, `lspErrorCode`, `lspInstaller`, `exitCode`, `embeddingDimension`, `embeddingStoredDimension`, `embeddingInputCount`, `embeddingOutputCount`.
    - `LSPDaemon`: `recordFailure(reason:error:)` logs the server, the attempt and the error type. The full reason stays in `.failed(reason:)`.
    - `LspSupervisor` and `ServerInstaller`: fixed messages. The installer output and the arguments are not in the log.
    - Tests: new `LoggingContentTests.swift` (4 marker tests plus a source-scan test), and new `Support/PackagePaths.swift`, which also replaces the path code that was the same in `ConnectionTests` and `ToolsDocumentationTests`. `ScaffoldTests` now checks the logger labels. `LspSessionCapabilityTests` and `LSPIndexWorkerReferencesTests` read an `InMemoryLogHandler`. `CapturedLogLines` is deleted.
    A fork agent converts the remaining call sites.
  timestamp: 2026-09-28T19:54:13.962589+00:00
- actor: claude-code
  id: 01m3mspsck1146drcvpg1qzgfq
  text: |-
    ### implement — changed
    - evidence: `swift test --parallel`: 706 tests in 65 suites passed, 0 failures. `LoggingContentTests` and `UnifiedLoggingSourceScanTests` passed. The filtered run with the regex `FoundationModelsCodeContextTests\.(LoggingContentTests|…)` ran more than 0 tests. `rg -n 'import os|os\.Logger|OSSignposter|privacy:' Sources` finds nothing. The only warnings come from the environment: SwiftPM "cached manifest: disk I/O error". There are no code warnings.
    - files: Package.swift; Sources: Logging/Log.swift, Tracing/CodeContextTracing.swift, LSP/{LSPDaemon,LspSupervisor,ServerInstaller,LspSession,ProcessLanguageServerConnection}.swift, Index/{LSPIndexWorker,LSPIndexWorker+References,Watcher,TreeSitterWorker}.swift, Ops/SearchCode.swift, CodeContext.swift; Tests: LoggingContentTests.swift (new), Support/PackagePaths.swift (new), Support/LspSessionTestSupport.swift, ScaffoldTests, CodeContextTracingTests, LspSessionCapabilityTests, LSPIndexWorkerReferencesTests, ConnectionTests, ToolsDocumentationTests.
    - notes: The wire logger now writes one `.trace` record for each message: to the server after the write, and from the server in `route`. The record holds the server, the direction, the byte size, and the method and id when they exist. `LspSession.logFailure(of:filePath:error:)` replaces `logFailure(of:context:error:)`, so the symbol and the position are no longer in the record. The public API changes: the type of `Log.*` is now `Logging.Logger`, and `Log.subsystem` is removed.
    - next: /review
  timestamp: 2026-09-28T20:01:10.547860+00:00
- actor: claude-code
  id: 01m3mssvcgrn9q9zr0qfw6k5qx
  text: |-
    ### test — green
    - evidence: swift test --parallel — 706 tests in 65 suites passed, 0 failed, 0 skipped. No compiler warning or error in the output (checked with a search for swift warning and error lines).
    - note: SwiftPM prints "disk I/O error" warnings for its manifest cache in ~/Library/Caches/org.swift.swiftpm. This is an environment issue, not a source warning. No file in the repo causes it.
    - next: review
  timestamp: 2026-09-28T20:02:50.896550+00:00
- actor: claude-code
  id: 01m3mstb5efpp2mxs9ea0ravny
  text: |-
    ### commit — changed
    - evidence: 6990d6f feat(logging)!: replace os.Logger loggers with swift-log and remove LSP payloads and stderr text from log records
    - note: This is a public API break. The Log.* type changed. Log.subsystem is removed. The commit is local. It is not pushed.
    - next: review
  timestamp: 2026-09-28T20:03:07.054615+00:00
- actor: claude-code
  id: 01m3mtk5tk83argavmez4vqvrb
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (commit 54d2681). 1 finding, 1 confirmed, 0 refuted. Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift:122 (`test-integrity/test-partitioning`).
    - next: Move the subprocess test `aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog`, and each other test in the file that starts a real subprocess, to the integration test target at IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LoggingContentTests.swift. Then run review again. The task stays in review.
  timestamp: 2026-09-28T20:16:40.787223+00:00
- actor: claude-code
  id: 01m3mtkfvd49fy7hdnnnwjf07p
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 23 files
    - test: green — swift test --parallel, 706 passed, 0 failed, 0 skipped
    - commit: 54d2681
    - review: findings — Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift:122 (test-integrity/test-partitioning)
  timestamp: 2026-09-28T20:16:51.053784+00:00
- actor: claude-code
  id: 01m3mv0k58957r3qrhy9ez2gtf
  text: |-
    Review finding test-integrity/test-partitioning is fixed.
    - Only one test in the unit LoggingContentTests.swift started a real subprocess: `aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog` (ProcessLanguageServerConnection with `swift <script>`). The other three tests use fakes (FakeLanguageServerConnection, FakeInstallRunner), and the source-scan test reads files only. They stay in the unit target.
    - The subprocess test moved to IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LoggingContentTests.swift. It has a local copy of `CapturedLogRecords` (a test target cannot import the test target of an other package; this is the same pattern as IntegrationSupport.swift). It reads the scripted server from Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift through a path from `#filePath`. It uses the `poll(budget:interval:until:)` helper of IntegrationSupport.swift in place of the removed `waitForStderr`.
    - IntegrationTests/Package.swift now depends directly on swift-log (from 1.15.1, the same floor as the root) for the `Logging` and `InMemoryLogging` products. Package.resolved did not change, because swift-log was already pinned.
    - Unit file: removed the moved test, `waitForStderr`, `pollLimit`, `pollInterval` and `@Suite(.serialized)` (no test in the suite starts a subprocess now). The doc comments tell where the moved test is.
  timestamp: 2026-09-28T20:24:00.424625+00:00
- actor: claude-code
  id: 01m3mv0p1bm6vce5nvb71myshh
  text: |-
    ### implement — changed
    - evidence: 3 files — IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LoggingContentTests.swift (new), Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift. Root `swift test --parallel`: 705 tests in 65 suites passed (706 before, minus the moved test). `swift test` in IntegrationTests: 3 tests in 3 suites passed, with LoggingContentTests.aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog passed. No Swift source warning or error in either output; only the SwiftPM manifest cache "disk I/O error" warnings of the environment.
    - next: /review
  timestamp: 2026-09-28T20:24:03.371695+00:00
- actor: claude-code
  id: 01m3mv6yhxtyjfdyzg6rtg4j3p
  text: |-
    ### test — green
    - evidence: root `swift test --parallel`: 705 tests in 65 suites passed, 0 failed, 0 skipped. Nested `swift test` in IntegrationTests: 3 tests in 3 suites passed (LoggingContentTests, LivePylspTests, LiveSourceKitTests), 0 failed, 0 skipped.
    - evidence: after touching both LoggingContentTests.swift files, `swift build --build-tests` in both packages: Build complete, 0 compiler warnings.
    - note: the only warnings are SwiftPM "disk I/O error" messages for the manifest cache. They come from the environment, not from source.
    - next: review.
  timestamp: 2026-09-28T20:27:28.701143+00:00
- actor: claude-code
  id: 01m3mv7crcarxef4gm68r911we
  text: |-
    ### commit — changed
    - evidence: local commit "fix(tests): move the subprocess logging content test to IntegrationTests". Not pushed.
    - next: review
  timestamp: 2026-09-28T20:27:43.244085+00:00
- actor: claude-code
  id: 01m3mvcr678jaqc4scb3yht3mx
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 9c8363c). Counts: findings 0, confirmed 0, refuted 0, attempted 7, failed 0. 3 files reviewed. 2 `.kanban/` files not reviewed (.reviewignore). All prior review findings are checked.
    - next: The task moved to done. No work remains on this task.
  timestamp: 2026-09-28T20:30:38.791638+00:00
- actor: claude-code
  id: 01m3mvczy5acr3xwqn9nyezx4a
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 3 files (IntegrationTests/Package.swift, IntegrationTests/.../LoggingContentTests.swift new, Tests/.../LoggingContentTests.swift), 1/1 findings checked
    - test: green — root swift test --parallel 705 passed; IntegrationTests swift test 3 passed; 0 failed, 0 skipped, 0 compiler warnings
    - commit: 9c8363c
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-09-28T20:30:46.725981+00:00
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
position_column: done
position_ordinal: d080
title: 'OTel B: replace the os.Logger loggers with swift-log and remove LSP payloads and stderr text from log records'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rules 2 and 4. Remove all `os.Logger` use and use `Logging.Logger` (swift-log). Do not keep unified-logging output. No log message and no log metadata value can carry content.

Research:
- `Sources/FoundationModelsCodeContext/Logging/Log.swift` is `public enum Log` with `subsystem` and seven `os.Logger` values: `lsp`, `lspWire`, `index`, `watcher`, `embedding`, `search`, `diagnostics`. It is public API. `Tests/FoundationModelsCodeContextTests/ScaffoldTests.swift:11` reads `Log.subsystem`.
- Call sites (use `privacy: .public` interpolation, which swift-log does not have):
  - `LSP/LSPDaemon.swift` (lines near 256 `fault`, 286, 339, 411, 416, 506 `recordFailure`)
  - `LSP/LspSupervisor.swift` (near 274, 328)
  - `LSP/ServerInstaller.swift` (near 405, 411, 416, 419)
  - `LSP/LspSession.swift` (near 219, the default `failureLog` closure)
  - `LSP/ProcessLanguageServerConnection.swift` (near 680 `Log.lspWire.error`, near 735 the stderr drain `Log.lsp.debug("\(text)")`)
  - `Index/LSPIndexWorker.swift` (near 282, 289, 339, 428), `Index/LSPIndexWorker+References.swift` (near 366)
  - `Index/Watcher.swift` (near 230, 243, 249, 415, and 419 `DispatchQueue(label: "\(Log.subsystem).watcher")`)
  - `Index/TreeSitterWorker.swift` (near 131, 139, 145, 255, 301, 307)
  - `Ops/SearchCode.swift` (near 380), `CodeContext.swift` (near 690)

Content risks found (rule 4):
1. `lspWire`: the category is "raw LSP request/response wire traffic". Now it has only one call site with a fixed string, but the category exists to log payloads. Proposal: keep the logger, but it logs only the method name, the request id, the direction and the byte size, as metadata with the keys of the vocabulary file. It never logs a payload, not even at `.trace`. Document this on the logger.
2. The stderr drain in `ProcessLanguageServerConnection.swift` (near 735) logs each stderr line of the language server. A server can write source code or file content to stderr. Proposal: log only the server name and the byte count of the chunk at `.debug`; keep the text only in the in-memory `BoundedTailBuffer` for failure state.
3. `LSPDaemon.handshakeFailureReason` appends the stderr tail to the reason, and `recordFailure` logs the reason. Proposal: the log record carries the server name, the attempt count and the error type only; the full reason stays in `LSPDaemonState.failed(reason:)` for the caller (it does not go to a log).
4. `String(describing: error)` and `error.localizedDescription` in `SearchCode.swift` near 380, `CodeContext.swift` near 690, `LspSupervisor.swift`, `ServerInstaller.swift`: an error description can carry query text or a payload (for example a `DecodingError`). Proposal: log `String(reflecting: type(of: error))` under the `error.type` metadata key and a fixed message.
5. A relative file path is a name and is safe. Put it in metadata under `file.path`, not in the message.

Do this:
- [x] Depends on the vocabulary task of this board (it adds `swift-log` and the `LoggerLabel` and `MetadataKey` names).
- [x] Change `Log.swift`: `import Logging`; each member becomes `Logging.Logger(label: CodeContextTracing.LoggerLabel.x)`. Remove `subsystem` or keep it as the label prefix; update `ScaffoldTests.swift` to match. Update the doc comment (it now says that `os.Logger` is used on purpose; that is no longer true).
- [x] Change every call site to swift-log: fixed message text, and names, ids, counts and sizes in `metadata:` with keys from the vocabulary file. Map `fault` to `.critical`, `notice` to `.notice`.
- [x] Apply proposals 1 to 5 above.
- [x] Change the `Watcher.swift` dispatch queue label so it does not read `Log.subsystem` if that member goes away.
- [x] After the change, `rg -n 'import os|os\.Logger|OSSignposter|privacy:' Sources` finds nothing.
- [x] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Sources/FoundationModelsCodeContext/Logging/Log.swift`
- All call-site files listed above.
- `Tests/FoundationModelsCodeContextTests/ScaffoldTests.swift`
- New: `Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift`

## Acceptance Criteria
- [x] No `import os`, no `os.Logger`, no `OSSignposter` in `Sources/`.
- [x] The `lspWire` logger and the stderr drain never write payload or stderr text to a log record.
- [x] Every log record that the package writes carries a fixed message, and its metadata holds only names, ids, counts, sizes and error type names.

## Tests
- [x] New `Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift`: bootstrap a capturing `LogHandler` for the test (or use the capture of Extras task OTel B ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G, when it exists). Drive the scripted LSP server of `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` so that it writes a marker string to stderr and in a response, and drive a handshake failure. Check that no captured log message or metadata value contains the marker.
- [x] A source-scan test (like the other scan tests in the package, if one exists) that fails when `import os` or `privacy:` is in `Sources/`.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

## Review Findings (2026-09-28 15:03)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 23 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift:122` `test-integrity/test-partitioning` — Integration test that spawns a real subprocess should be in a separate integration test target, not in the unit test target. Line 133 explicitly creates a ProcessLanguageServerConnection with a real subprocess (swift interpreter), making this an integration test that uses a real external system. Move the test `aLanguageServerWritesNoStandardErrorTextAndNoPayloadToTheLog` (and similar subprocess-spawning tests) to the integration test target at IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LoggingContentTests.swift instead of including them in the unit test target.
