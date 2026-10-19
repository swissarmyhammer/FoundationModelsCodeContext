---
assignees:
- claude-code
depends_on:
- 01M5A10VFHNREW31047TBJGYZZ
position_column: todo
position_ordinal: '8180'
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