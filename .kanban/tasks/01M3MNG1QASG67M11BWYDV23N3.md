---
depends_on:
- 01M3MNFXGGMN1K0Q2A0SA5VZ5M
position_column: todo
position_ordinal: '8180'
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
- [ ] Depends on the vocabulary task of this board (it adds `swift-log` and the `LoggerLabel` and `MetadataKey` names).
- [ ] Change `Log.swift`: `import Logging`; each member becomes `Logging.Logger(label: CodeContextTracing.LoggerLabel.x)`. Remove `subsystem` or keep it as the label prefix; update `ScaffoldTests.swift` to match. Update the doc comment (it now says that `os.Logger` is used on purpose; that is no longer true).
- [ ] Change every call site to swift-log: fixed message text, and names, ids, counts and sizes in `metadata:` with keys from the vocabulary file. Map `fault` to `.critical`, `notice` to `.notice`.
- [ ] Apply proposals 1 to 5 above.
- [ ] Change the `Watcher.swift` dispatch queue label so it does not read `Log.subsystem` if that member goes away.
- [ ] After the change, `rg -n 'import os|os\.Logger|OSSignposter|privacy:' Sources` finds nothing.
- [ ] Doc comments in ASD-STE100 Simplified Technical English.

## Files to change
- `Sources/FoundationModelsCodeContext/Logging/Log.swift`
- All call-site files listed above.
- `Tests/FoundationModelsCodeContextTests/ScaffoldTests.swift`
- New: `Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift`

## Acceptance Criteria
- [ ] No `import os`, no `os.Logger`, no `OSSignposter` in `Sources/`.
- [ ] The `lspWire` logger and the stderr drain never write payload or stderr text to a log record.
- [ ] Every log record that the package writes carries a fixed message, and its metadata holds only names, ids, counts, sizes and error type names.

## Tests
- [ ] New `Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift`: bootstrap a capturing `LogHandler` for the test (or use the capture of Extras task OTel B ^z6jqd9g, 01M3MN8N9P4RPET2V5JZ6JQD9G, when it exists). Drive the scripted LSP server of `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` so that it writes a marker string to stderr and in a response, and drive a handshake failure. Check that no captured log message or metadata value contains the marker.
- [ ] A source-scan test (like the other scan tests in the package, if one exists) that fails when `import os` or `privacy:` is in `Sources/`.
- [ ] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.