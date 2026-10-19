---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a76e85nh7f76z1ar3mdb75
  text: |-
    Picked up. Research:
    - `ServerInstaller.performInstall` (Sources/.../LSP/ServerInstaller.swift) logs the nonzero exit with `lsp.server`, `lsp.installer`, `process.exit_code` only. `InstallRunResult.output` is the joined chunks of `BoundedTailBuffer` (last 40 chunks of stdout+stderr) from the rewritten `ProcessInstallRunner` (^5xpk4fa); unchanged by this card.
    - Log capture in unit tests: `CapturedLogRecords` (Tests/.../LoggingContentTests.swift) bootstraps swift-log to an `InMemoryLogHandler`; `entries(matching:)` / `entries(holding:)`. `LoggingContentTests.aFailedInstallWritesNoInstallerOutputToTheLog` is the existing content-safety guard for installer output (marker in output must not appear in any record).
    - `CodeContextTracingTests.metadataKeys` lists every MetadataKey; the new key must be added there.
    - No markdown doc lists the metadata keys, so no doc update is needed beyond the doc comments.
    Plan: new `CodeContextTracing.MetadataKey.installFailureReason = "lsp.install.reason"`; a pure static extractor that takes the token after `npm error code ` / `npm ERR! code ` at the start of a line, only when the whole token is [A-Z0-9_]{1,64}; merge it into the failure record only when found.
  timestamp: 2026-10-19T13:56:39.813383+00:00
- actor: claude-code
  id: 01m5a7b3pwkhnea7b9m8rdjba7
  text: |-
    Implementation landed (TDD: RED was a compile failure on the missing `MetadataKey.installFailureReason` / `InstallFailureReason`, then GREEN).
    - `InstallFailureReason.code(in:)` (ServerInstaller.swift): pure static extractor. Splits the output on newlines (a `\r\n` is one Character, so CRLF works), takes the first line that STARTS with `npm error code ` or `npm ERR! code `, and gives the rest of the line only when all of it is 1...64 chars of `[A-Z0-9_]` (`maximumCodeLength`, `codeCharacters` named). Anything else → nil, so brew/go/pipx/cargo output gives no key.
    - `ServerInstaller.failureMetadata(of:)` builds the failure record metadata: `process.exit_code` always, `lsp.install.reason` only when a code is found. No other output text reaches any record.
    - New `CodeContextTracing.MetadataKey.installFailureReason = "lsp.install.reason"`, added to `CodeContextTracingTests.metadataKeys`.
    - Doc comments of `performInstall` and `InstallRunResult.output` updated to state the one exception to "no installer output in a log record".
    - Tests: `ServerInstallerTests.aFailedNpmInstallLogsTheNpmErrorCodeAndNoOtherOutput` (record carries `lsp.install.reason=UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, no record holds the secret-path marker or the registry URL), `aFailedInstallWithNoErrorCodeLogsNoReason`, and `InstallFailureReasonTests` (new form, old `ERR!` form, CRLF + preceding lines, 64-char boundary, 9 nil cases: no code, empty, 65 chars, lowercase, trailing path, `../` path, prefix not at line start).
    - OTel E `TelemetryContentSafetyTests` and `LoggingContentTests` pass unchanged.
    - The only build warning is the known upstream `missing creator for mutated node ... mlx-swift_Cmlx.bundle` (recorded cause on ^kw00hcn); it printed before this change compiled too.
  timestamp: 2026-10-19T13:59:12.860854+00:00
- actor: claude-code
  id: 01m5a7b6jayt8bddb8f5gkd8bk
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift, Sources/FoundationModelsCodeContext/Tracing/CodeContextTracing.swift, Tests/FoundationModelsCodeContextTests/ServerInstallerTests.swift, Tests/FoundationModelsCodeContextTests/CodeContextTracingTests.swift. Tests added: 2 ServerInstallerTests + InstallFailureReasonTests (4 tests + 1 parameterized over 9 inputs). `swift test`: 1034 tests in 91 suites passed, 0 failures, 0 skipped; 1 known upstream SwiftPM warning (Cmlx bundle, ^kw00hcn). TelemetryContentSafetyTests (OTel E) green.
    - next: /review
  timestamp: 2026-10-19T13:59:15.786425+00:00
- actor: claude-code
  id: 01m5a7f2886jw25vvm4bn9khyf
  text: |-
    ### test — green
    - evidence: swift test — 1034 tests in 91 suites passed, 0 failed, 0 skipped; swift test --package-path IntegrationTests — 22 tests in 16 suites passed, 0 failed, 0 skipped. Only warning: pre-existing mlx-swift_Cmlx "missing creator for mutated node" (not chased). LanguageServerGrandchildTests flake (^t71wvkm) did not appear.
    - next: review/commit
  timestamp: 2026-10-19T14:01:22.440130+00:00
position_column: doing
position_ordinal: '80'
title: Log the reason of a failed language server install (npm error code), not only exit_code
---
## What
SWE-bench run of 2026-10-18 (peer report, FoundationModelsACPAgent bench/run.code-context.log): 16 times
`error ... lsp.installer=npm lsp.server=typescript-language-server process.exit_code=1 the installer of the language server failed`.
The real cause, `npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, was only in the npm log. Our log line kept just `exit_code=1`.

## Where
- `Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift` `ServerInstaller.performInstall` (~line 459): the failure branch logs only `exitCode`.
- `InstallRunResult.output` (~line 145) already holds a bounded tail of stdout+stderr (from `ProcessInstallRunner`'s `BoundedTailBuffer`), but it is never logged.
- The doc comment of `performInstall` says on purpose: a log record never holds installer output, because output can hold content. Keep that rule.

## Approach
Pull a short, safe reason out of the output tail, not the raw tail:
- npm: the token after `npm error code ` / `npm ERR! code ` (e.g. `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`, `E404`, `EACCES`). Restrict to `[A-Z0-9_]{1,64}`.
- Other installers (brew, go, pipx, cargo...): no structured code → no reason key (or a fixed "unknown"). Do not log free text.
- Add a metadata key, e.g. `CodeContextTracing.MetadataKey.installFailureReason` (`lsp.install.reason`), next to `exitCode`.
- Make the extractor a pure static function so it is unit-testable.

## TDD
1. Failing test in `ServerInstallerTests`: a `FakeInstallRunner` returns exit 1 with output containing `npm error code UNABLE_TO_GET_ISSUER_CERT_LOCALLY\nnpm error ...secret path...`; capture the log record and assert it has `lsp.install.reason=UNABLE_TO_GET_ISSUER_CERT_LOCALLY` and does NOT contain the rest of the output.
2. Unit tests for the extractor: old `npm ERR! code` form, new `npm error code` form, no code → nil, overlong/odd chars → nil.
3. Implement; run the suite.

## Acceptance
- The failure log line names the npm error code.
- No raw installer output in any log record. #lsp #bug