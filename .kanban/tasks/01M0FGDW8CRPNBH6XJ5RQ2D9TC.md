---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0fgr10wm9d0n0tetf9yae29
  text: |-
    Progress:
    - Made `IntegrationTests/Package.swift`. The package depends on the root package by path.
    - Moved `LiveSourceKitTests.swift` to `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/`. Removed the `CCK_LIVE_LSP` suite trait. Kept the `sourcekit-lsp` `$PATH` capability trait.
    - Made `IntegrationSupport.swift` with local copies of `withTemporaryWorkspace`, `write`, and `FakeEmbedder`.
    - Rewrote `.github/workflows/ci.yml` as a repo-local workflow: unit job, then integration job with `needs: unit`, plus the unchanged format job.
    - Updated two stale comment references in the unit target.
    - `swift format lint --strict` on all Swift sources: green.
    - The integration package build runs now. Root `swift test` and the live integration run come next.
  timestamp: 2026-08-20T12:01:16.316028+00:00
- actor: claude-code
  id: 01m0fhhe6rh4xf3aq43rvgyd7f
  text: |-
    ### commit — changed
    - evidence: 44a88e9 refactor(tests): remove the env-var gate and split the live suite into its own package; pushed to main (b2b0977..44a88e9)
    - test evidence: root `swift test` 561 tests in 47 suites, all green; `swift test --package-path IntegrationTests` 1 test green against a real sourcekit-lsp (63 s); `swift format lint --strict` green
    - note: `swift package update` was necessary at the root. The old resolution pinned `mlx-swift-lm` to a `foundationmodels-fixes` revision that does not compile with the current SDK. The new resolution uses `stable (ba8ff43)`. `Package.resolved` is not tracked in this repository.
    - next: none. The work is complete.
  timestamp: 2026-08-20T12:15:09.016070+00:00
position_column: done
position_ordinal: b880
title: Move the live LSP suite to a nested IntegrationTests package and remove the CCK_LIVE_LSP gate
---
Comply with the org test expectations for all sibling packages.

The problem: `Tests/FoundationModelsCodeContextTests/LiveSourceKitTests.swift:24` gates a full suite on the environment variable `CCK_LIVE_LSP`. The suite is in the unit target. A green `swift test` does not show that the suite ran. The org expectations do not permit environment variables as the test selection mechanism.

Do these steps (the nested-package shape, as FoundationModelsMultitool commits 32d82b2 and 0ceda07 show):

1. Make a nested package `IntegrationTests/Package.swift`. The package depends on the root package by path. Match the platform floor macOS 27.
2. Move `LiveSourceKitTests.swift` to `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/`. Remove the `CCK_LIVE_LSP` suite trait. Keep the capability trait that examines `$PATH` for `sourcekit-lsp` — that trait reads machine capability, not a selection variable.
3. Copy the small helpers the suite uses (`withTemporaryWorkspace`, `FakeEmbedder`) into the integration package. The root unit target keeps its own copies.
4. Change `.github/workflows/ci.yml` to a repo-local workflow: a unit job that runs `swift test` and also builds the integration package with `swift build --package-path IntegrationTests --build-tests` on every run, then an integration job with `needs: unit` that runs `swift test --package-path IntegrationTests`. Keep the format lint job.
5. Update comments and documents that point to `CCK_LIVE_LSP`.

Acceptance:
- Root `swift test` runs every unit test and only unit tests. No suite in the root target reads an environment variable for selection.
- `swift test --package-path IntegrationTests` names and runs the live suite.
- CI orders unit before integration and builds the integration package on every run.
- The format lint gate stays green.

#org-test-expectations