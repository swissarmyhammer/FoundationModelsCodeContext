---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: The hang step of scripted-lsp-server must stop the script when stdin closes
---
## Problem
When the test binary crashes, `withConnection` does not call `close()`, and no code kills the process group of the scripted server. The `hang` step of `Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift` sleeps for ever and does not read stdin. Thus the script stays alive with parent pid 1. ^0d568qc found one such orphan: the RED run of ^s4fmb5k crashed the test binary ("Range requires lowerBound <= upperBound").

The exit of the test binary closes the write end of the stdin pipe of the script. A real language server stops at the end of stdin.

## Change
- Make the `hang` step wait for the end of stdin, and stop the script at the end of stdin. The step must still never answer a request and must keep stdout open while stdin is open.

## Acceptance criteria
- [ ] A test in the IntegrationTests package or in ConnectionTests proves that a script at a `hang` step stops when its stdin closes, with `processExists(pid)`.
- [ ] The existing ConnectionTests that use `hang` pass. #bug