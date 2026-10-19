---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5a7ttz06mf4erg962cv4rfq
  text: |-
    Research (implement):
    - `ServerInstaller` is built in exactly one production place: `LspSupervisor.init` (`ServerInstaller(policy: autoInstall, runner: installRunner)`); `LspAutoInstall` is already plumbed CodeContextManager -> CodeContext -> LspSupervisor -> ServerInstaller. So the record location and backoff go on `LspAutoInstall` (`failureBackoff: Duration`, default 24 h; `failureRecordDirectory: URL?`, default `<user caches>/FoundationModelsCodeContext`, nil = no record). No new plumbing parameters needed at any layer.
    - Hazard: many existing tests build `ServerInstaller(runner:)` / supervisors / CodeContexts with auto-install ON and a FakeInstallRunner (ServerInstallerTests, LoggingContentTests, LspSupervisorTests autoInstall*, MetricsTests, CodeContextE2ETests, CodeContextManagerTests, CodeContextStartTests). With the default directory those would write ~/Library/Caches and (worse) a second test run would skip the runner and fail. Each must get a temp `failureRecordDirectory`. Tests with `isEnabled: false` never reach the record.
    - `ServerInstaller`'s inner install Task is unstructured; the supervisor's cancel of `installTask` does not cancel it, so a recorded exit code is never a cancel signal number.
    - `InstallFailureReason.code(in:)` (^tbjgyzz) gives the npm code; it is stored as the record's `reason`. Exit code nil for a thrown run (timeout/spawn).
    - ~/Library/Caches/FoundationModelsCodeContext does not exist before this work; checked again after the full suite.
  timestamp: 2026-10-19T14:07:48.192782+00:00
- actor: claude-code
  id: 01m5a8c6zrm7qv33vqagjwpvnp
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsCodeContext/LSP/InstallFailureRecord.swift`: `InstallFailureRecord` (JSON array of entries `{key: {command, tool, arguments}, failedAt (ISO 8601), exitCode?, reason?}` in `<dir>/install-failures.json`, atomic `Data.write(.atomic)`, read/decode/write errors logged at warning with error type only, missing file silent) and `InstallFailureBackoff` (window + injectable `now`).
    - `LspAutoInstall` gains `failureBackoff` (default `defaultFailureBackoff` = 24 h) and `failureRecordDirectory: URL?` (default `defaultFailureRecordDirectory` = `<user caches>/FoundationModelsCodeContext`; nil = no record). No new plumbing at CodeContext/Manager/Supervisor: the policy already flows there.
    - `ServerInstaller.init(policy:runner:now:)`; the attempt task checks the record before the runner, logs info "the installer of the language server failed before; it is not tried again until the retry time" with exit code, `lsp.install.reason` and new `lsp.install.retry_time` (ISO 8601), returns false. Failure (nonzero exit or throw) stores the entry; success removes it.
    - Test hygiene: new test helper `LspAutoInstall.withoutFailureRecord`; every existing test that runs with auto-install ON (ServerInstallerTests, LoggingContentTests, LspSupervisorTests autoInstall*, MetricsTests, CodeContextE2ETests, CodeContextManagerTests, CodeContextStartTests) now passes it. Verified ~/Library/Caches/FoundationModelsCodeContext still does not exist after the full suite.
    - Gotcha: the `files` tool `replace_all: true` replaced only the first match per call here; I re-ran edits and checked with rg.
    - Docs: docs/language-servers.md new section "A failed installation is not tried again for 24 hours" (path, behavior, `rm` to clear, config example); README sentence.
  timestamp: 2026-10-19T14:17:17.560647+00:00
- actor: claude-code
  id: 01m5a8cbgskqwbenymeqecy0at
  text: |-
    ### implement — changed
    - evidence: 16 files. New: Sources/FoundationModelsCodeContext/LSP/InstallFailureRecord.swift, Tests/FoundationModelsCodeContextTests/InstallFailureRecordTests.swift (14 tests), Tests/FoundationModelsCodeContextTests/Support/LspAutoInstall+Testing.swift. Modified: Sources/.../LSP/ServerInstaller.swift, Sources/.../Tracing/CodeContextTracing.swift, Tests: CodeContextE2ETests, CodeContextManagerTests, CodeContextStartTests, CodeContextTracingTests, LoggingContentTests, LspSupervisorTests, MetricsTests, ServerInstallerTests; README.md, docs/language-servers.md. RED: `swift test --filter InstallFailureRecordTests` failed to compile (no failureRecordDirectory/failureBackoff/InstallFailureRecord). GREEN: same filter 12/12 passed. Full `swift test`: 1048 tests in 92 suites passed, 0 failed, 0 skipped; only output warning is the pre-existing SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle" (not from this change). Real ~/Library/Caches/FoundationModelsCodeContext absent after the run.
    - next: /review
  timestamp: 2026-10-19T14:17:22.201267+00:00
- actor: claude-code
  id: 01m5a8h98kc7qd4yah89c8pzr1
  text: |-
    ### test — green
    - evidence: swift test: 1048 tests in 92 suites passed, 0 failures, 0 skipped. swift test --package-path IntegrationTests: 22 tests in 16 suites passed. Only warning is the pre-existing mlx-swift_Cmlx "missing creator for mutated node" (reported, not chased). LanguageServerGrandchildTests flake (^t71wvkm) did not appear. ~/Library/Caches/FoundationModelsCodeContext absent before and after both runs (no install-failure record written).
    - next: review/commit
  timestamp: 2026-10-19T14:20:03.731005+00:00
- actor: claude-code
  id: 01m5a8nqw17evkdwyt85hagq0p
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (071cf12) — 3 findings — Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:123, Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:169, Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:554
    - next: implement the 3 open items in the 2026-10-19 09:20 Review Findings section; task stays in review
  timestamp: 2026-10-19T14:22:29.761811+00:00
- actor: claude-code
  id: 01m5a8p41chya2kdcx71m47njs
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 16 files (InstallFailureRecord.swift new, ServerInstaller, CodeContextTracing, tests +14, README, docs)
    - test: green — swift test 1048 passed, IntegrationTests 22 passed, 0 skipped; real caches dir untouched
    - commit: 071cf12
    - review: findings — ServerInstaller.swift:123 (magic-numbers), ServerInstaller.swift:169 (magic-numbers), ServerInstaller.swift:554 (idioms UseLetInEveryBoundCaseVariable)
  timestamp: 2026-10-19T14:22:42.220150+00:00
- actor: claude-code
  id: 01m5a8w3ajcsqvs7r4f9mvxpq7
  text: |-
    Review findings (2026-10-19 09:20) addressed, task pulled back to doing:
    - magic-numbers-swift :123: `24 * 60 * 60` replaced by `defaultFailureBackoffHours * secondsPerHour` (two new private static lets: `secondsPerHour = 3_600`, `defaultFailureBackoffHours = 24`). Under swiftlint `no_magic_numbers`, the operands of an arithmetic expression count as magic numbers even in a `static let`. A plain literal `static let` does not.
    - magic-numbers-swift :169: the default parameter `.seconds(300)` was flagged because the literal is a call argument. New public `LspAutoInstall.defaultTimeoutSeconds: Int64 = 300` and `LspAutoInstall.defaultTimeout: Duration`, following the same pattern as `defaultFailureBackoff`. `init(timeout:)` now defaults to `defaultTimeout`. Doc comments now name it.
    - idioms-swift :554: `case let .failed(exitCode, reason)` changed to `case .failed(let exitCode, let reason)`. That was the only `case let` in ServerInstaller.swift and InstallFailureRecord.swift (checked with rg).
    - Swept the whole file and InstallFailureRecord.swift. swiftlint 0.65 with the validator's config (`only_rules: [no_magic_numbers]`, `allowed_numbers: [0, 1, -1, 100]`) reports 4 violations on the HEAD version of ServerInstaller.swift (123 x3, 169) and 0 on either file now. InstallFailureRecord's `attosecondsPerSecond = 1e18` is a plain `static let`, which the rule accepts.
    - TDD: new test `InstallFailureRecordTests.theDefaultTimeoutIsFiveMinutes`. RED: compile error "type 'LspAutoInstall' has no member 'defaultTimeout'". GREEN after the change.
  timestamp: 2026-10-19T14:25:58.098190+00:00
- actor: claude-code
  id: 01m5a8w6rc17c3vf2kpc7b1h1j
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift (LspAutoInstall constants secondsPerHour, defaultFailureBackoffHours, defaultTimeoutSeconds, defaultTimeout; init default `timeout: Duration = defaultTimeout`; `case .failed(let exitCode, let reason)` in performAttempt), Tests/FoundationModelsCodeContextTests/InstallFailureRecordTests.swift (defaultTimeoutSeconds + theDefaultTimeoutIsFiveMinutes). `swift test --filter 'ServerInstallerTests|InstallFailureRecordTests|ProcessInstallRunnerTests|InstallFailureReasonTests'`: 47 tests in 5 suites passed, 0 failed. The only warning is the mlx-swift_Cmlx "missing creator for mutated node" warning, already recorded on this card by earlier runs. swiftlint no_magic_numbers: 0 on both source files. All 3 findings flipped to [x].
    - next: /review
  timestamp: 2026-10-19T14:26:01.612847+00:00
- actor: claude-code
  id: 01m5a9106rht5v8dgzzgvrqa3j
  text: |-
    ### test — green
    - evidence: `swift test` — 1049 tests in 92 suites passed, 0 failed, 0 skipped; `swift test --package-path IntegrationTests` — 22 tests in 16 suites passed, 0 failed, 0 skipped. No compiler warnings. Only warning: pre-existing mlx-swift_Cmlx "missing creator for mutated node" (reported, not chased). LanguageServerGrandchildTests did not flake (^t71wvkm). ~/Library/Caches/FoundationModelsCodeContext absent before and after both runs.
    - next: review/commit
  timestamp: 2026-10-19T14:28:38.744852+00:00
- actor: claude-code
  id: 01m5a9558z1037vea4pwfqqtmn
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (6c37419): 0 findings (0 confirmed, 0 refuted; 7 attempted, 0 failed). Prior items ServerInstaller.swift:123, :169 (magic-numbers-swift) and :554 (idioms-swift) all checked and fixed in the diff: the backoff and timeout values are now named constants (secondsPerHour, defaultFailureBackoffHours, defaultTimeoutSeconds, defaultTimeout), and the match is now `case .failed(let exitCode, let reason)`.
    - next: none; task moved to done.
  timestamp: 2026-10-19T14:30:55.007965+00:00
- actor: claude-code
  id: 01m5a95f9p3yn1fd77ker5ych4
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — ServerInstaller.swift named constants + case pattern; +1 test
    - test: green — swift test 1049 passed, IntegrationTests 22 passed, 0 skipped; caches dir untouched
    - commit: 6c37419
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-19T14:31:05.270129+00:00
depends_on:
- 01M5A10VFHNREW31047TBJGYZZ
position_column: done
position_ordinal: fe80
title: Remember a failed language server install across sessions and do not run it again in each new session
---
## What
SWE-bench run of 2026-10-18: each of the 16 sessions ran `npm install -g typescript-language-server` again, and each one failed the same way (UNABLE_TO_GET_ISSUER_CERT_LOCALLY), about 2 min 22 s each (15:18:21 → 15:20:43 for instance 1). That is ~38 min of npm per run, for a fault on the machine.

## Where
- `Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift` `ServerInstaller.attempts` (~line 392): an in-memory `[String: Task<Bool, Never>]`. It stops a retry only inside one `ServerInstaller` instance, i.e. one `LspSupervisor` / one session. A new session starts with an empty dictionary.
- `.code-context/` is per workspace (`Store.swift` ~line 114), so it does NOT help here: every SWE-bench instance is a new clone. The record must be per user, e.g. `~/Library/Caches/FoundationModelsCodeContext/install-failures.json` (or `FileManager.cachesDirectory`), injectable for tests.

## Approach
- A small `InstallFailureRecord` store keyed by server command + installer tool + installer arguments (and the package/binary version if the spec has it, so a changed install spec tries again).
- Entry: failure time, exit code, reason (from the sibling task that extracts the npm error code).
- `install(spec:)`: before running the runner, if a record for this key is younger than a backoff window (e.g. 24 h; make it part of `LspAutoInstall`, e.g. `failureBackoff: Duration`), return `false` and log at info "the installer of the language server failed before; not tried again until <time>" with the reason.
- On success, remove the record.
- Read/write errors of the record file must never fail the install path (log + continue).
- Concurrent sessions: write atomically (write temp + rename); a lost update is acceptable.

## TDD
1. Failing test: two separate `ServerInstaller` instances share one record directory (temp dir) and one `FakeInstallRunner` that returns exit 1. After the first `install(spec:)`, the second instance's `install(spec:)` returns `false` and the runner call count stays 1.
2. Test: with an injected clock/now past the backoff window, the second instance runs the runner again.
3. Test: a success clears the record.
4. Test: a corrupt record file → the installer still runs (no throw).
5. Implement; run the suite.

## Acceptance
- A failed install is tried at most once per backoff window per machine, across sessions and workspaces.
- Docs (README auto-install section) mention the record and how to clear it. #lsp #performance

## Review Findings (2026-10-19 09:20)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 13 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `docs/language-servers.md` — no validator matches this file

- [x] `Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:123` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:169` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsCodeContext/LSP/ServerInstaller.swift:554` `code-hygiene/idioms-swift` — UseLetInEveryBoundCaseVariable: move this 'let' keyword inside the 'case' pattern, before each of the bound variables.
