---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fp30y43ech52mqjykank8m
  text: |-
    ### commit — changed
    - evidence: 9cbb76a ci: replace the repo-local unit/integration jobs with one shared swift-ci.yaml call; pushed to main (44a88e9..9cbb76a)
    - CI evidence: run https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/runs/32374223273 — conclusion success
      - Format lint: success (13:25–13:26, repo-local, unchanged)
      - ci / Build & test: success (13:26–13:30) — root swift test 561 tests in 47 suites, all green
      - ci / Integration (opt-in, real dependencies): success (13:30–13:33), needs: test — liveSourceKitSurvivesACrashAndAutoRestarts() passed after 63.237s against a real sourcekit-lsp, not skipped
    - next: none. FoundationModelsCodeContext is now on the shared swift-ci.yaml for both unit and integration.
  timestamp: 2026-08-20T13:34:39.556639+00:00
position_column: done
position_ordinal: b980
title: Convert ci.yml to one shared swift-ci.yaml call when integration-package-path lands
---
Will's unified-CI directive: each sibling package calls the shared workflow.

Today the shared `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml` supports only the selector shape (`test-filter`/`test-skip` + `integration-filter`/`integration-skip`). It cannot run a nested integration package. This repository uses the nested-package shape (`IntegrationTests/`), so `.github/workflows/ci.yml` is repo-local for now. That is correct and green — run 32367866028.

The workflows-06 session adds an `integration-package-path` input now. With it, the shared integration job builds and runs the nested package, the unit job builds the nested package on every run, and `needs: test` stays.

Do these steps when the FoundationModelsMultitool session reports that the input is on workflows origin/main:

1. Read the new input's contract in `swift-ci.yaml` on origin/main.
2. Replace the repo-local `unit` and `integration` jobs in `.github/workflows/ci.yml` with one `uses: swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` call. Pass `integration-package-path: IntegrationTests` and `example-targets: CodeContextExample ManagerExample`. Do not pass `integration-gate-env` — that input is legacy.
3. Keep the repo-local `format` job. The shared workflow does not have a format-lint job.
4. Push, then confirm on the run for the new commit: the unit job builds the integration package, the integration job starts after the unit job, and the live suite truly runs (not skipped).

Multitool's conversion card is ^jjyqe1a on their board, as a model.

Blocked until the workflows change lands. The peer session sends a message when it does.

#org-test-expectations