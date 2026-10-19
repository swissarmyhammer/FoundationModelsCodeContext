---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5axrachrr8g4z0p1669ytc9
  text: 'Research: (1) SharedServerSpecs.typeScriptFamily holds the unpinned installer args and installHint; InstallSpecTests.typeScriptFamilyInstallerUsesNpmInstallGlobal asserts the old args; ServerSpec.InstallSpec.arguments doc comment quotes the old args as an example; docs/language-servers.md has the unpinned npm command (README and plan.md do not). (2) Log.errorDetail(of:) names only CodeContextError; WireError (LSP/Wire.swift) has no caseName. LSPDaemon.recordFailure sets only error.type; Log.serverFailureMetadata sets only error.type (ScaffoldTests asserts its exact map, so that test needs error.case added). MetadataKey.lspRequest ("lsp.request") and lspErrorCode ("lsp.error_code") already exist; LspSession.logFailure extracts the WireError code by hand with .string("\(code)") — that block will route through Log.errorDetail so the extraction lives in one place. (3) Log capture idiom: CapturedLogRecords + MarkedError + FakeLanguageServerConnection.setInitializeResult in Tests/.../LoggingContentTests.swift.'
  timestamp: 2026-10-19T20:30:54.353586+00:00
- actor: claude-code
  id: 01m5ay02dncqbwma2v7071pxmb
  text: |-
    Implementation landed (test first). RED: 6 failures, each for the missing feature (old npm args; WireError had no error.case/lsp.error_code; the handshake failure record had no lsp.request). GREEN: targeted run of InstallSpecTests|ScaffoldTests|LoggingContentTests|LSPDaemon|LspSession|LspSupervisor|Wire = 201 tests, 1 failure, then fixed and re-run (below).

    Notes for the next agent:
    - Item 1: SharedServerSpecs.typeScriptFamily now installs `typescript@6`, the installHint names the same command, and a doc comment says why (TS 7 ships no lib/tsserver.js). New test typeScriptFamilyInstallHintNamesTheSameCommandAsTheInstaller ties the hint to the installer args. ServerSpec.InstallSpec.arguments doc example updated too.
    - Item 2: WireError.caseName added (Wire.swift). Log.errorDetail(of:) now switches on CodeContextError / WireError via two private caseDetail(of:) helpers; serverFailureMetadata = serverMetadata merged with errorDetail. LSPDaemon.recordFailure gained `request: String? = nil` and merges errorDetail; the handshake catch passes Self.handshakeRequest ("initialize", a computed static because LSPDaemon is generic). Never the message.
    - Beyond the three items, on purpose: LspSession.logFailure extracted the WireError code by hand with the same `if case .serverError` block. It now merges Log.errorDetail(of:) so the extraction lives in one place; its record gains error.case. The existing exact-map test LspSessionCapabilityTests.aFailureLogRecordNames... failed on that and was updated (renamed ...TheCase...). If review wants that reverted, it is the LspSession.swift hunk plus that test.
    - docs/language-servers.md: row pinned to typescript@6, a paragraph on why plus the one-time `npm install -g typescript@6` for machines that already have TS 7, and the "Server capabilities" paragraph corrected: it said the log shows the server's error message, which it never did (content-safe rule). README.md and plan.md have no npm command for TypeScript.
    - Nothing installed or changed in the global npm prefix.
    - swift build: clean except the allowed mlx-swift_Cmlx warning. swift format lint --strict on the 10 changed Swift files: exit 0. Full suite, IntegrationTests and the repo-wide lint are the later test step.
  timestamp: 2026-10-19T20:35:08.341216+00:00
- actor: claude-code
  id: 01m5ay062grbys5nk8mwp5c1ve
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsCodeContext/Languages/SharedServerSpecs.swift, Sources/FoundationModelsCodeContext/Languages/ServerSpec.swift, Sources/FoundationModelsCodeContext/LSP/Wire.swift, Sources/FoundationModelsCodeContext/Logging/Log.swift, Sources/FoundationModelsCodeContext/LSP/LSPDaemon.swift, Sources/FoundationModelsCodeContext/LSP/LspSession.swift, docs/language-servers.md, Tests/FoundationModelsCodeContextTests/InstallSpecTests.swift (+1 test, 1 updated), Tests/FoundationModelsCodeContextTests/ScaffoldTests.swift (+3 tests, 1 updated), Tests/FoundationModelsCodeContextTests/LoggingContentTests.swift (+1 test, shared daemon helper), Tests/FoundationModelsCodeContextTests/LspSessionCapabilityTests.swift (1 updated). swift build clean (allowed mlx warning only); targeted tests green; swift format lint --strict on changed files exit 0.
    - next: /test (full suite, IntegrationTests, repo-wide format lint), then /review.
  timestamp: 2026-10-19T20:35:12.080911+00:00
- actor: claude-code
  id: 01m5ay4wz05de3kyz9dgmxtshj
  text: |-
    ### test — green
    - evidence: swift test — 1067 tests in 94 suites passed, 0 failures, 0 skipped; swift test --package-path IntegrationTests — 22 tests in 16 suites passed, 0 failures, 0 skipped; swift format lint --strict --recursive Sources Tests IntegrationTests/Tests — exit 0, no diagnostics. Only warning in build output is the allowed mlx-swift_Cmlx "missing creator for mutated node".
    - next: review/commit
  timestamp: 2026-10-19T20:37:46.592765+00:00
position_column: doing
position_ordinal: '80'
title: 'typescript-language-server daemon fails the handshake: npm installs TypeScript 7, which has no tsserver.js; and the WireError failure record has no content-safe reason'
---
## Problem

Reported by the peer session (SWE-bench run agents-probe, 2026-10-19 15:25, Code Context 0f77bc5, Django checkout with JS under django/contrib/admin/static):

- The installer ran `npm install -g typescript-language-server typescript`. That gave typescript-language-server 6.0.2 and **typescript 7.0.2** (the npm `latest` tag is now 7.0.2).
- Then "the language server daemon failed", `error.type=FoundationModelsCodeContext.WireError`, attempts 1 and 2. The record has no reason.

## Cause (reproduced on this machine)

I sent our exact `initialize` params to `/opt/homebrew/bin/typescript-language-server --stdio` (node v26.12.0). The reply:

```
{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Request initialize failed with message: Could not find a valid TypeScript installation. ..."}}
```

TypeScript 7 is the native rewrite. Its npm package ships `lib/tsc.js`, `lib/getExePath.js` and `lib/version.cjs`, but no `lib/tsserver.js`. typescript-language-server 6.0.2 resolves its bundled `typescript` (the global sibling) and needs `lib/tsserver.js`, so it throws on `initialize`. The client gets `WireError.serverError(code: -32603, …)`.

With `npm install -g --prefix <scratch> typescript-language-server typescript@6`, typescript 6.0.3 installs and the same `initialize` returns its capabilities ("Using Typescript version (bundled) 6.0.3").

## Work (test first)

1. `SharedServerSpecs.typeScriptFamily`: the installer arguments install `typescript@6`, not the unpinned `typescript`. The `installHint` says the same. A doc comment says why (TypeScript 7 has no tsserver.js). Test: the install arguments of the spec pin TypeScript to major 6.
2. Content-safe reason for a failure record. `Log.errorDetail(of:)` names a `WireError` too: `error.case` = the case name (`serverError`, `idMismatch`, `missingResult`), and for `serverError` also `lsp.error_code` = the JSON-RPC code. It never holds the server message. `LSPDaemon.recordFailure` and `Log.serverFailureMetadata` use it. The handshake failure record also says which phase failed (`lsp.request` = `initialize`).
   Test: a daemon handshake that fails with `WireError.serverError(code: -32603, message: <marker text>)` writes a "the language server daemon failed" record with `error.case=serverError`, `lsp.error_code=-32603` and `lsp.request=initialize`, and the marker text appears in no log record.
3. Search the docs and README for the unpinned `npm install -g typescript-language-server typescript` and pin them the same way.

## Not in scope

- The global install on the peer's machine already has typescript 7.0.2. The installer does not run again, because the binary is on the PATH. The peer must run `npm install -g typescript@6` once. This is told to the peer, not done here.

## Acceptance

- `swift test`, `swift test --package-path IntegrationTests` and `swift format lint --strict --recursive Sources Tests IntegrationTests/Tests` are green. The allowed mlx-swift warning is the only warning.