---
assignees:
- claude-code
depends_on:
- 01M5A5ACEVQWJ9PC8GXT71WVKM
position_column: todo
position_ordinal: '80'
title: 'ConnectionTests: remove withRetryOnSpawnContention now that the descriptor-reuse cause is fixed'
---
## What
`Tests/FoundationModelsCodeContextTests/ConnectionTests.swift` wraps `requestReceivesItsScriptedTypedResponse()` in `withRetryOnSpawnContention`, a retry on `CodeContextError.timeout` added for the flake of 01KWVSJAR801YR97D051YDWPR5 ("occasionally the response never arrives on this attempt"). The test-integrity rule forbids "retry logic added to hide a flaky test".

^t71wvkm found the cause of "the response never arrives": `ProcessLanguageServerConnection.close()` closed the stdout/stderr read ends while the dedicated read loops still read those descriptors by number, and Darwin reuses a freed number at once, so a stale loop read the stdout pipe of the next connection and swallowed its response. ^t71wvkm makes each read loop own its read end (`ProcessUtilities.runReadLoop(name:readEnd:_:)`).

## Change
- Remove `withRetryOnSpawnContention` and its long comment; call `withConnection` once.
- Prove it under load: run `swift test` (root) concurrently several times with CPU load (e.g. 40 `yes > /dev/null`) and confirm no `.timeout` in the test.

Depends on ^t71wvkm landing. #test-flake