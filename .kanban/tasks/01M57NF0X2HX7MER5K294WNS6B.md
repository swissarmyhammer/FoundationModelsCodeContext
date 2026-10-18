---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
title: 'LspSupervisorTests: replace the 5-second real-time limit of the shutdown-during-install test'
---
## Problem
In `Tests/FoundationModelsCodeContextTests/LspSupervisorTests.swift`, the test that races `shutdown()` against a gated install (`FakeInstallRunner` with a closed gate) asserts `elapsed < .seconds(5)` in real time from the start of `shutdown()` to `shutdownTask.value`. This is the same kind of real-time assertion that ^vqpcb1t removed from `ProcessInstallRunnerTests`. Under full-suite load the scheduler delay can be more than 6 seconds, thus the test can fail when the machine is busy. The test also uses fixed real-time sleeps (20 ms before the gate opens, 100 ms settle window).

Found during ^vqpcb1t.

## Change
- Make the assertion independent of the scheduler. Prove the behavior (shutdown resolves after the gate opens, no state change after the shutdown) with state, not with a tight real-time limit. If a time limit stays, use a named constant far above the scheduler delay.

## Acceptance criteria
- [ ] The test proves the shutdown behavior, not that the scheduler is fast.
- [ ] The full unit suite passes.

#test-flake