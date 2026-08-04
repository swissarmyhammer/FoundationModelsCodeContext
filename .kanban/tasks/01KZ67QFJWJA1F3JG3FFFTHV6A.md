---
assignees:
- claude-code
position_column: todo
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

- [ ] Each of the three recursive walks named above takes a depth argument and stops descending at a documented limit, in the style of `Complexity.maxASTDepth`.
- [ ] The limit is shared, not re-declared per walk.
- [ ] Reaching the limit degrades quietly — chunks/call sites found so far are returned, nothing is thrown — matching `Chunker`'s existing return-empty-rather-than-throw convention for unparseable files.
- [ ] `Complexity.measure(snippet:module:)` drops its `reachedDepthLimit` gate around `Chunker.chunk(file:module:)` and reports symbols for a deep snippet like any other.

## Tests

- [ ] Test: `Chunker.chunk(file:module:)` on a Swift snippet with a 5000-term `+` spine inside a function returns normally and still reports the enclosing function's chunk.
- [ ] Test: `TSCallGraph.writeCallEdges(db:file:module:)` on the same shape returns normally.
- [ ] Test: an ordinary 50-deep nested-`if` fixture is unaffected — every chunk it contains is still reported.
#bug