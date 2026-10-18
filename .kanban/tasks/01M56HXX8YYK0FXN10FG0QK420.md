---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Tests that write ../secret.swift must remove the file
---
## Problem
LayeredOpsTests, TreeSitterWorkerTests and LSPIndexWorkerTests write `../secret.swift` into the parent directory of the workspace, to test a path outside the root. No test removes this file. The tests run in parallel, thus three tests write the same file at the same time.

Before ^w29j74j, the parent was `$TMPDIR` itself, thus each run left a file directly in `$TMPDIR`. Now the parent is `TemporaryItem.root` (`/tmp/FoundationModelsCodeContextTests-<uid>`), and the file stays there after each run.

## Change
- Give each of these tests its own outside directory (for example a second `withTemporaryWorkspace`, or a nested root below the workspace so that `..` stays in the workspace), and remove the file after the test.
- Make sure that no test writes into `TemporaryItem.root` directly.

## Tests
- After a run of the three suites, `TemporaryItem.root` holds no `secret.swift`. #test-hygiene