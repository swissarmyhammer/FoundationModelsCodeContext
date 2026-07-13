---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'WatcherTests.realFSEventsDetectsFileWriteAndMarksItDirty fails: FSEvents not delivered in sandbox'
---
Tests/CodeContextKitTests/WatcherTests.swift:359

Expectation failed: dirty == ["a.rs"] -> dirty is [] after 16s. The real-FSEvents OS integration test never receives FSEvents callbacks in this sandboxed environment.

Pre-existing and environmental, NOT caused by task ^44rphyv (RankKit adoption): the implementer stash-verified it fails identically on pristine HEAD, and the tester run on 2026-07-13 confirmed it is the only failure in the 440-test suite (both before and after the Package.swift FoundationModelsRouter path->URL fix). Nothing was attempted as a fix per instructions.

Possible directions: gate on actual FSEvents deliverability probed at runtime (write a canary file and see if any event arrives), or run it only where FSEvents works (e.g. local Xcode, not the sandbox). Do not skip-mark it silently. #test-failure