---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: LanguageServerGrandchildTests.forceRestartKillsTheGrandchildOfTheOldServer times out in the handshake under full-suite load
---
## What
In a full `swift test --package-path IntegrationTests` run (2026-10-19, during ^b91evm0 test step) this test failed once:
`LanguageServerGrandchildTests.forceRestartKillsTheGrandchildOfTheOldServer()` → `.handshakeFailed("operation timed out after 30.0 seconds")` at `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/LanguageServerGrandchildTests.swift:52`, while the live SourceKit and scale tests ran in parallel. The suite alone passed (3 tests, 0.8 s); the next full run passed. No code change between runs.

The test was added in 40fde36 (^sgdcvtq). It starts the scripted server via `swift <script>`, and that compile-and-start is slow under parallel load. The same class of flake was fixed before for ConnectionTests (01KWVSJAR801YR97D051YDWPR5) and ProcessInstallRunnerTests (01M56861Y5R6151E7REVQPCB1T); check how those were fixed and follow the same pattern.

## TDD
1. Reproduce: run the full integration suite several times (or with parallel load) and confirm the handshake timeout; note the frequency.
2. Fix the cause, not just the timeout number. For example, use the shared precompiled scripted-server path or the retry-on-spawn-contention helper that ConnectionTests uses, or serialize the process-heavy suites.
3. Check the other new suites from 40fde36 (HardKilledHostTests, LivePylspJediTests) for the same risk.

## Acceptance
- 5 consecutive full `swift test --package-path IntegrationTests` runs pass with this test included. #test-flake