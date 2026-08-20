---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
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