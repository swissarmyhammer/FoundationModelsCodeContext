---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5nb8n5mtfk3drbwvrxqqj6v
  text: |-
    ### test — green
    - red first: listSymbolsGivesTheFileAndItsSymbolsLikeGetSymbol failed on the old code (the JSON was an array, not an object).
    - evidence: `swift test` 1092 tests in 96 suites passed; IntegrationTests 22 passed.
    - open, in another repo: `syms.filter(...)` on the new object needs `"code_context.listSymbol": "symbols"` in the Multitool `resultShapes` table; told the acp-agent bench session.
  timestamp: 2026-10-23T21:39:25.492550+00:00
position_column: done
position_ordinal: ff8b80
title: listSymbols returns { file, symbols } like getSymbol, not a bare array
---
## What
From the acp-agent bench (bench24-1023b, django__django-13964, seq 4598): the model wrote `syms.symbols.filter(...)` on a listSymbol result, as it does on getSymbol, and got "undefined is not an object (evaluating 'syms.symbols.filter')". listSymbols returns a bare array, while getSymbol returns `{ query, symbols }`.

## Change
- New `ListSymbolsResult { file, symbols }`, returned by `SymbolOps.listSymbols`, `CodeContext.listSymbols`, `CodeContextOperating.listSymbols` and the `list symbol` operation. There are no compatibility shims (ARCHITECTURE.md).
- So that `syms.filter(...)` also keeps working in a snippet, the Multitool forgiving bindings need the entry `"code_context.listSymbol": "symbols"` in `resultShapes` (another repo; the acp-agent bench session is told).

## Test (first, red)
- `SymbolOps.listSymbols` gives `file` and `symbols`.
- The JSON of the `list symbol` operation has a `symbols` array.

#bug