---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m2kr7remds9hgytz6csn9234
  text: |-
    ### finish iteration 1 — review clean
    - implement: added one shared comparator `rankedBefore` to `SymbolOps`, with the typealias `ScoredCandidateRow`. It keeps the highest score first, then compares the qualified path, the file path and the start line. All four score sorts (the suffix, case-insensitive and fuzzy tiers, and `searchSymbol`) now use it. The exact tier gives each match the same score and did not sort at all, so it uses the comparator too. The tool test `defaultsMatchTheDirectEngineCall` now uses the query `greet`, which has a tie. Added `searchSymbolGivesTiedMatchesTheSameOrderOnEveryCall`, which calls `searchSymbol(query: "greet")` 21 times on a `Greeter`/`helper` fixture and expects the order `["Greeter", "Greeter.greet"]` each time.
    - test: green — 588 tests in 52 suites passed. `swift format lint -r --strict` gave no findings.
    - commit: 111ea82
    - review: clean — 0 findings from 7 checks.

    Note for the next agent: `Greeter` and `Greeter.greet` both score 120 for the query `greet`, because `fuzzyScore` gives 10 for the first character, 10 more because it starts the target, and 25 for each of the four characters that follow. `helper` has no `g`, so it does not match. `listSymbols` sorts only by start line, but its candidates are keyed by `(file path, start line)` inside one file, so that order is already total.
  timestamp: 2026-09-16T00:00:33.236980+00:00
position_column: done
position_ordinal: c480
title: 'searchSymbol and getSymbol: matches with the same score have no fixed order'
---
## What
`SymbolOps` sorts the matches of `searchSymbol` and `getSymbol` only by `score` (`Sources/FoundationModelsCodeContext/Ops/SymbolOps.swift`, the `.sorted { $0.score > $1.score }` calls near lines 394, 408, 425 and 508). When two matches have the same score, their order comes from a source that has no fixed order. Two calls with the same arguments can give the matches in a different order, so the JSON of the result is not stable.

Evidence (found in ^6bzj7va): in a fixture with `struct Greeter { func greet() }`, `searchSymbol(query: "greet")` gave `[greet, Greeter]` on one call and `[Greeter, greet]` on the next call. Both matches have score 120. The `code_search` tool test `defaultsMatchTheDirectEngineCall` failed 1 time in 6 runs because of this. That test now uses the query `helper`, which has no tie.

## Fix
Add a tie-break to each sort: after `score`, compare `qualifiedPath`, then `filePath`, then `startLine`. Thus the order is total and the same on each call.

## Acceptance Criteria
- [ ] Each `score` sort in `SymbolOps` has a tie-break that makes the order total.
- [ ] A test calls `searchSymbol(query: "greet")` on the fixture above many times and gets the same order each time.
- [ ] `swift test` exits 0.

#bug