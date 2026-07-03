---
comments:
- actor: wballard
  id: 01kwk87p2a73sv6eecwhgabppy
  text: |-
    Implemented Sources/CodeContextKit/Ops/QueryAST.swift per plan: compiles a user-supplied tree-sitter S-expression query at runtime for a language resolved from Languages.all (case-insensitive match), enumerates files via the existing Walker.enumerateFiles(rootDirectory:extensions:) (gitignore-aware, no reimplemented gitignore logic), parses/queries each file, and returns QueryASTResult{matches:[ASTMatch(file,captures:[ASTCapture])], filesScanned, truncated} capped by QueryASTOptions.maxResults (default 50).

    Key design notes:
    - Added CodeContextError.query(String) case for malformed-query and unknown-language failures (both throw, never crash).
    - Widened Chunker.extractTextAndRange(of:in:) from private to internal and changed its return shape from (text, range) to (text, startByte, endByte) so QueryAST.makeCapture reuses the exact same UTF-16-NSRange -> UTF-8-byte-offset conversion Chunker already used, instead of duplicating the byte math. This matters because SwiftTreeSitter's Parser parses via UTF-16LE internally, so raw node.byteRange is NOT UTF-8 bytes -- must go through Range(node.range, in: source) + utf8.distance(from:to:).
    - Files are sorted by path before scanning for deterministic match ordering (Walker's own enumeration order is unspecified).
    - Renamed local Language values to `grammar` (not `language`) inside QueryAST.run to avoid shadowing the `language: String` parameter.

    Followed TDD: wrote Tests/CodeContextKitTests/QueryASTTests.swift first (11 tests), watched it fail to compile (QueryAST didn't exist), then implemented to green.

    Went through 3 review cycles via mcp__sah__review (code-context review engine):
    1. Doc comment formatting, initial extractTextAndRange visibility.
    2. tsLanguage naming (renamed to grammar), duplicate UTF-8 byte-offset math between Chunker.makeChunk and QueryAST.makeCapture (fixed by sharing extractTextAndRange), added case-insensitivity test.
    3. A "data-driven switch" suggestion for the QueryError->message mapping was tried, but it introduced MORE duplication (case-label strings in two places) than the original plain switch; reverted to the direct switch, which is the idiomatic/duplication-free way to destructure a fixed enum's associated values in Swift. Final review pass: 0 findings.
    4. Extracted the inner match-collection loop in QueryAST.scan into a separate collectMatches(...) helper per a nesting/complexity finding.

    Final state: swift test -> 214 tests, 15 suites, all green, zero warnings. mcp__sah__review op review working -> 0 findings. Adversarial double-check dispatched as part of really-done.
  timestamp: 2026-07-03T05:46:42.634087+00:00
- actor: wballard
  id: 01kwk8db10t0p56x3877dkatnj
  text: |-
    really-done verification complete:
    - Fresh `swift test` run: 214 tests, 15 suites, all passing, zero warnings.
    - Adversarial double-check agent verdict: PASS. It independently re-ran `swift test --filter QueryASTTests` (11/11) and `swift test --filter ChunkerTests` (7/7), traced the UTF-8 byte-offset math end-to-end (confirmed QueryAST.makeCapture has zero independent offset arithmetic of its own -- it fully delegates to the already-tested Chunker.extractTextAndRange, so the existing chunkByteOffsetsAreUTF8BytesNotUTF16CodeUnits coverage transfers), verified determinism (path-sort is safe since all files share rootDirectory prefix), confirmed no gitignore logic exists outside Walker, confirmed no force-unwraps and descriptive error messages, traced the maxResultsStopsScanningFurtherFilesOnceReached truncation edge case instruction-by-instruction, and spot-checked doc-comment formatting. No blast-radius issues: nothing else in the tree references QueryAST/ASTMatch/ASTCapture yet (MCP wiring is a separate downstream task this one blocks).

    Task is done and green. Leaving in `doing` for /review per the implement workflow.
  timestamp: 2026-07-03T05:49:47.936316+00:00
depends_on:
- 01KWJ3PSVZTXYZDX1ASZ3GN09M
- 01KWJ3QTH53M16194BCTX6MKVP
position_column: doing
position_ordinal: '80'
title: 'queryAST op: runtime S-expression queries'
---
## What
Create `Sources/CodeContextKit/Ops/QueryAST.swift` — port of `crates/swissarmyhammer-code-context/src/ops/query_ast.rs`. Compile a user-supplied tree-sitter S-expression query at runtime for a named language (via `Languages.all`), run it against files on disk under the root — **enumerated via the shared `Walker` (gitignore-aware), filtered to that language's extensions; do not re-implement gitignore semantics** — and return `QueryASTResult { matches: [ASTMatch(file, captures)], filesScanned }` with a max-results cap. Invalid query text → thrown typed error with the tree-sitter message, not a crash.

## Acceptance Criteria
- [ ] A `(function_item name: (identifier) @name)` query over a rust fixture returns the expected capture names and ranges
- [ ] Malformed query throws a descriptive error; unknown language throws
- [ ] `maxResults` truncates and reports `filesScanned` accurately; gitignored files are never scanned

## Tests
- [ ] `Tests/CodeContextKitTests/QueryASTTests.swift`: capture correctness on fixtures, error paths, cap behavior, gitignore exclusion
- [ ] Run `swift test --filter QueryASTTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.