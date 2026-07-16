---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxp9wcrr6dkh1qbeph47w010
  text: 'Picked up. Verified shipped API against source: LspAutoInstall(isEnabled: Bool = true, timeout: Duration = .seconds(300)) in LSP/ServerInstaller.swift; ServerSpec.InstallSpec(tool/arguments/extraSearchDirectories) in Languages/ServerSpec.swift; autoInstall: LspAutoInstall = LspAutoInstall() param on CodeContext (2 inits), CodeContextManager (2 inits), LspSupervisor. Per-server installers: rust-analyzer/rustup (~/.cargo/bin), gopls/go (~/go/bin), pylsp/pipx (~/.local/bin), typescript-language-server/npm, intelephense/npm, jdtls/brew; hint-only: sourcekit-lsp, clangd, omnisharp. State flow: .notFound -> noteInstalling() -> .installing -> forceRestart() -> .running/.notFound; .installing not settled. Writing README section + plan.md addendum + example header note.'
  timestamp: 2026-07-16T20:28:54.936139+00:00
- actor: claude-code
  id: 01kxpa7dzp83h3z5s3cx8gqr7z
  text: |-
    Implemented. Changes:
    - README.md: added "## Language servers" section (between "Two ways in" and "Install") — default-on auto-install explanation, per-server install table (rust-analyzer/rustup, gopls/go, pylsp/pipx, typescript-language-server+intelephense/npm, jdtls/brew; hint-only sourcekit-lsp/clangd/omnisharp), .installing state note, and opt-out via LspAutoInstall(isEnabled: false) / timeout adjustment with runnable snippets.
    - plan.md: added "### LSP auto-install (design record)" subsection (before Observable state) covering InstallSpec on ServerSpec, ServerInstaller + InstallRunner seam + at-most-once guarantee, .notFound->.installing->forceRestart->.running/.notFound owned-task flow, extraSearchDirectories rationale, on-by-default opt-out policy.
    - Examples/CodeContextExample/main.swift and Examples/ManagerExample/main.swift: one-line header notes on the autoInstall: parameter and opt-out; no code change (defaults suffice).

    Verification: `swift build` exit 0 (both example targets compile); `swift test` 534 tests / 46 suites passed, exit 0. Adversarial double-check: PASS, all documented claims cross-checked accurate against shipped code. Did not touch .github/workflows/ci.yml or the other task's .kanban files. Left in doing for /review.
  timestamp: 2026-07-16T20:34:56.630174+00:00
depends_on:
- 01KXKY5MDHKKE49ZX9BA2H6BDJ
position_column: doing
position_ordinal: '80'
title: 'Document LSP auto-install: README, plan.md, and example opt-out'
---
## What
Record the auto-install behavior where users and future maintainers will look:

- `README.md`: a short "Language servers" section — servers auto-install by default when a project is detected and the binary is missing (native global installers: rustup/npm/go/pipx/brew, each gated on the installer tool being present); the per-server table (server → install command → hint-only ones: sourcekit-lsp, clangd); how to opt out (`LspAutoInstall(isEnabled: false)` on `CodeContext`/`CodeContextManager` init) and adjust the timeout.
- `plan.md`: append the design record matching the existing document's style: `InstallSpec` on `ServerSpec` (nil = hint-only), `ServerInstaller` with the `InstallRunner` seam and at-most-once guarantee, the `.notFound → .installing → forceRestart → .running/.notFound` supervisor flow running as owned non-blocking tasks, `extraSearchDirectories` rationale (`~/go/bin`, `~/.cargo/bin` not on `$PATH`), on-by-default opt-out policy decision.
- `Examples/`: mention the `autoInstall:` parameter in whichever example's header comment fits (one line — the defaults mean no code change is required for the examples to benefit).

## Acceptance Criteria
- [ ] README documents default-on behavior, the per-server install table, and the opt-out — all names matching the shipped API
- [ ] plan.md records the design decisions above
- [ ] No stale claims versus the implemented behavior

## Tests
- [ ] `swift build` and `swift test` still pass (docs-only change)

## Workflow
- Docs task: verify statements against the shipped code rather than TDD.