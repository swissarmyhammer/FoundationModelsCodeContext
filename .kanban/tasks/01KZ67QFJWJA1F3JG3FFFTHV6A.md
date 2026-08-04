---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz6a9yp61vk1drw2s7vvewwg
  text: |-
    Picked up. Research notes before writing code:

    **The three walks, as they stand**
    - `Chunker.collectChunks(node:file:module:into:)` — pre-order, recurses into every child named and anonymous alike, no bound. Entered from `Chunker.chunk(file:module:)` with the parse root.
    - `Chunker.collectSymbolNames(node:file:module:into:)` — the *upward* walk. It iterates ancestors in a `while` loop and only recurses when it finds a parent that is itself a chunk kind or a container kind, so its recursion depth is the count of nested definitions, not raw AST depth. Still unbounded, so 5000 nested `function`s in generated JS would reach it.
    - `TSCallGraph.collectCallSites(node:file:into:)` — same downward pre-order shape as `collectChunks`, no bound. Entered from `TSCallGraph.writeCallEdges(db:file:module:)`, which `TreeSitterWorker.writeChunks` calls inside the same write transaction as the chunk insert.

    **Where the shared limit goes**
    `Chunker` is already the shared home for the tree-sitter walking primitives the other two files reuse — `Chunker.parseFile` (used by `TSCallGraph.writeCallEdges` and `Complexity.measure`), `Chunker.extractTextAndRange` (used by `QueryAST`, `TSCallGraph`, and `Complexity`), and `Chunker.symbolPathSeparator` (used by `SymbolOps`), each carrying a "Not `private`: …" doc note explaining the sharing. So the bound becomes `Chunker.maxASTDepth`, moved out of `Complexity`, and `Complexity` + `TSCallGraph` + the tests reference that one constant. That satisfies "the limit is shared, not re-declared per walk" without inventing a new type.

    **Counting convention must match exactly**
    `Complexity.indexSymbolNodes` correlates its own bounded walk's nodes back to `Chunker.chunk`'s output by byte span. If the two walks disagreed about where the bound sits, a chunk could exist with no node to measure. Both must therefore keep the same convention: root at `astDepth: 0`, `guard astDepth < maxASTDepth`, children at `astDepth + 1`.

    **Dead code the gate removal leaves behind**
    `SymbolNodeIndex.reachedDepthLimit` exists only to feed the gate in `Complexity.measure`. Once the gate goes, the struct is a one-field wrapper around `[ByteRange: Node]`, so it goes too and `measuredFunctions` takes the dictionary directly.

    **Formatting**
    `Chunker.swift` and `TSCallGraph.swift` are 4-space (repo convention, 123 tracked files). `Complexity.swift` and `ComplexityTests.swift` are untracked and 2-space. Editing each file in its own local style; the repo-wide inconsistency is task ^9g8x9s9, not this one.
  timestamp: 2026-08-04T11:59:52.006899+00:00
- actor: claude-code
  id: 01kz6azp1f5v7g18b4yqhvph7k
  text: |-
    Implementation landed. What happened, including the part that did not go to plan:

    **The bound is 128, not 512, and the reason matters**

    The task's description assumed `Complexity.maxASTDepth`'s existing `512` was already the right number and just needed sharing. It is not. `512` was measured against the *main thread's* 8 MB stack, but `TreeSitterWorker.readAndChunk` calls `Chunker.chunk(file:module:)` from an `async` context, so the walk actually runs on a Swift concurrency cooperative-pool thread with a **512 KB** stack.

    With the bound at `512`, `ChunkerTests` (a synchronous test) passed, but the new `TSCallGraphTests` case — which goes through `TreeSitterWorker.run` and is therefore `async` — still died with signal 10. The crash report (`~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-*.ips`) named the frames outright: `EXC_BAD_ACCESS … Could not determine thread index for stack guard region`, with 500-odd `Chunker.collectChunks` frames under `TreeSitterWorker.readAndChunk`. So a "bounded" walk at 512 would have shipped the exact bug this task exists to fix, just with a narrower trigger.

    Three measurements picked the replacement, all recorded in `Chunker.maxASTDepth`'s doc comment so the next person can re-derive it:

    - **Real source reaches 39.** A throwaway probe parsed all 126 Swift files under `Sources/` and `Tests/` and took the deepest AST level in each; the worst is `LiveOpsExtendedTests.swift` at 39. Definitions — the only nodes these walks record — sit far above a file's deepest node, so nothing real is near the bound.
    - **The 50-deep nested-`if` fixture reaches 103**, and still fits.
    - **The stack dies between 448 and 512 frames** on the cooperative pool in a debug build. Bisected: 256, 320, 384, and 448 all pass; 512 crashes. `128` keeps peak usage near a quarter of the 512 KB budget.

    **Where the limit lives**

    `Chunker.maxASTDepth`, following the precedent `Chunker.symbolPathSeparator` and `Chunker.extractTextAndRange` already set — `Chunker` is where the tree-sitter primitives shared by `TSCallGraph` and `Complexity` live. `Complexity`'s own `maxASTDepth` is gone; its two walks and `TSCallGraph.collectCallSites` all read the one constant, as do the tests.

    **A correctness coupling worth knowing about**

    `Complexity.measuredFunctions` looks up each chunk `Chunker` produced in the node index `Complexity.indexSymbolNodes` built, keyed by byte span. If those two walks ever disagreed about where the bound sits, a chunk would arrive with no node and silently lose its metrics. Both therefore use the identical convention — root at `astDepth: 0`, `guard astDepth < Chunker.maxASTDepth`, children at `astDepth + 1` — and both doc comments say so.

    **Dead code removed with the gate**

    `SymbolNodeIndex` existed only to carry `reachedDepthLimit` alongside its dictionary. With the gate gone the bool is dead, so the struct went too and `measuredFunctions` takes `[ByteRange: Node]` directly.

    **Test fixtures**

    `swiftDeepExpressionSpine(termCount:leadingStatements:)` and `swiftNestedIfs(count:)` now live in `TestSupport.swift` rather than being copied a third time; `ComplexityTests` had private copies and now uses the shared ones. `swiftDeepExpressionSpine` gained a `leadingStatements` parameter so `TSCallGraphTests` can put a shallow `_ = helper()` call inside the same pathological function — that lets the call-graph test assert a real resolved edge (`deepSpine` → `helper`) instead of only "did not crash". `swiftNestedIfs` gained a `func innermost() {}` at the bottom of the nest so the ordinary-code test can assert the *deep* definition is still chunked, not just the outer one.

    **Watched all three fail first**

    - `ChunkerTests.anASTDeeperThanTheLimitStillChunksTheDefinitionsAboveIt` — signal 10.
    - `TSCallGraphTests.anASTDeeperThanTheLimitStillResolvesTheCallSitesAboveIt` — signal 10.
    - `ComplexityTests.anASTDeeperThanTheLimitStillReportsTheSymbolsAboveIt` — `result.symbols.first { $0.symbolPath == "deepSpine" } → nil`, which is the `reachedDepthLimit` gate returning no chunks.
  timestamp: 2026-08-04T12:11:44.047074+00:00
- actor: claude-code
  id: 01kz6bmvdbzch3x7mwzyrptmtq
  text: |-
    `/double-check` returned REVISE with five findings, all in the doc comments that justify the load-bearing constant. All five are fixed; two required new measurements.

    1. **`TestSupport.swiftNestedIfs` doc was inverted.** It read "103 AST levels deep, **far above the bound**" — 103 is *below* 128, and the sentence contradicted both `Chunker.maxASTDepth`'s own doc and the test that observes `deeplyNested.innermost`. Now reads "comfortably under `Chunker.maxASTDepth`".
    2. **The 103 figure was stale.** This task's own diff appends `func innermost() {}` below the innermost `if`, which deepens the fixture. Re-measured: **106**. Corrected in `Chunker.maxASTDepth` and `TestSupport.swiftNestedIfs`.
    3. **The "real source reaches 39" bullet over-generalized from one grammar.** The probe was Swift-only, but the conclusion was stated for every language `Languages.all` indexes — and the file kinds the task names as the motivating risk are exactly the unmeasured ones. Measured them: **60 levels of nested YAML mappings parse 184 AST levels**, about three per indent level, so `128` corresponds to roughly 42 levels of YAML indentation. `MarkdownLanguage`'s `section` nests per heading level (6 headings = 8 levels). The doc now scopes the 39 to Swift, carries the YAML number, and says plainly that this is a deliberate cutoff rather than a level nothing real reaches. The claim "a definition always sits far above a file's deepest node" was removed — the fixture in the very next bullet disproves it.
    4. **`Complexity.accumulate` counts from the measured symbol's node, not the parse root**, so it can touch absolute AST levels past 128 — which made `maxASTDepth`'s opening sentence false for that walk. Both `maxASTDepth` and `accumulate` now say so, and `maxASTDepth` records that the 448–512 frame bisection was measured on `collectChunks` frames, which are smaller than `accumulate`'s seven-argument frame. Output is unaffected: the two axes are independent.
    5. **`collectSymbolNames`'s doc said one level is "one enclosing definition".** It is one enclosing *chunked or container* node, and a container is often not a definition — `YAMLLanguage`'s `block_mapping`, `MarkdownLanguage`'s `section`. Its stated reachability argument was also the weak one; replaced with the true one: the only caller is `makeChunk`, reached from `collectChunks`, which already stops at `maxASTDepth`, and each climb consumes at least one AST level — so this guard is defensive, never reachable from production.

    Confirmed clean by the reviewer, independently: depth-counting parity between `Chunker.collectChunks` and `Complexity.indexSymbolNodes` is exact (no off-by-one, so no chunk can arrive without a node); `rg 'childCount|\.child\(at:|\.parent'` over `Sources/` hits only the three tree-sitter files and every recursive walk in them is now bounded (`QueryAST` goes through query captures, not manual recursion); and adding `innermost` to the shared fixture changes nothing any pre-existing assertion measures, because a `nestedFunctionBody` raises nesting but never `branchDepth`.

    Also verified the two ordinary-code guards are real rather than vacuous: with the bound temporarily at 64, `ChunkerTests.theDepthBoundLeavesAnOrdinaryFiftyDeepNestFullyChunked` and `ComplexityTests.theDepthLimitDoesNotDistortOrdinaryNesting` both fail. Bound restored to 128.
  timestamp: 2026-08-04T12:23:17.675688+00:00
- actor: claude-code
  id: 01kz6bn22f9zjt7msqxm66xsgm
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/TreeSitter/Chunker.swift, Sources/FoundationModelsCodeContext/TreeSitter/TSCallGraph.swift, Sources/FoundationModelsCodeContext/TreeSitter/Complexity.swift, Tests/FoundationModelsCodeContextTests/TestSupport.swift, Tests/FoundationModelsCodeContextTests/ChunkerTests.swift, Tests/FoundationModelsCodeContextTests/TSCallGraphTests.swift, Tests/FoundationModelsCodeContextTests/ComplexityTests.swift. `swift build` clean, no warnings; `swift test` → 562 tests in 48 suites passed, 0 failures. All 4 acceptance criteria and all 3 required tests satisfied; 5 double-check findings fixed.
    - next: /review
  timestamp: 2026-08-04T12:23:24.495928+00:00
position_column: doing
position_ordinal: '80'
title: Bound the recursive AST walks in Chunker and TSCallGraph so a deep parse tree cannot overflow the stack
---
## What

`Chunker.collectChunks(node:file:module:into:)`
(`Sources/FoundationModelsCodeContext/TreeSitter/Chunker.swift`),
`Chunker.collectSymbolNames(node:file:module:into:)`, and
`TSCallGraph.collectCallSites(node:file:into:)`
(`Sources/FoundationModelsCodeContext/TreeSitter/TSCallGraph.swift`) all recurse
over the parse tree with no depth bound. A parse tree deeper than the thread's
stack kills the process — there is no error to catch.

Measured while implementing `Complexity` (task `^tbr1qkt`): a Swift snippet of
`let x = 1` followed by `" + 1"` repeated 5000 times parses into a left-nested
`additive_expression` spine 5005 nodes deep, and `Chunker.chunk(file:module:)`
on it terminates the test process with signal 10. Ordinary source is nowhere
near this — a 50-deep nested-`if` fixture measures only 103 — but the input is
not always ordinary: minified or generated JavaScript, a machine-generated
literal array, or a long chained expression all reach it, and
`TreeSitterWorker` hands `Chunker` whatever is on disk.

`Complexity.measure(snippet:module:)` already carries the bound this file needs
(`Complexity.maxASTDepth`, and a walk that takes a depth argument and stops
descending at it), and today it works around the gap by refusing to call
`Chunker.chunk` at all when its own bounded walk reports the tree is deeper
than the limit. That workaround should go away once the walks below are bounded
themselves.

## Acceptance Criteria

- [x] Each of the three recursive walks named above takes a depth argument and stops descending at a documented limit, in the style of `Complexity.maxASTDepth`.
- [x] The limit is shared, not re-declared per walk.
- [x] Reaching the limit degrades quietly — chunks/call sites found so far are returned, nothing is thrown — matching `Chunker`'s existing return-empty-rather-than-throw convention for unparseable files.
- [x] `Complexity.measure(snippet:module:)` drops its `reachedDepthLimit` gate around `Chunker.chunk(file:module:)` and reports symbols for a deep snippet like any other.

## Tests

- [x] Test: `Chunker.chunk(file:module:)` on a Swift snippet with a 5000-term `+` spine inside a function returns normally and still reports the enclosing function's chunk.
- [x] Test: `TSCallGraph.writeCallEdges(db:file:module:)` on the same shape returns normally.
- [x] Test: an ordinary 50-deep nested-`if` fixture is unaffected — every chunk it contains is still reported.

## Note on the limit's value

The bound shipped as `Chunker.maxASTDepth = 128`, not the `512` this description
assumed could be reused from `Complexity`. `512` was safe only on the main
thread's 8 MB stack; `TreeSitterWorker` calls `Chunker.chunk(file:module:)` from
an `async` context, so the walk actually runs on a cooperative-pool thread with a
512 KB stack, where the stack dies between 448 and 512 frames. See
`Chunker.maxASTDepth`'s doc comment for the four measurements behind `128`.

#bug