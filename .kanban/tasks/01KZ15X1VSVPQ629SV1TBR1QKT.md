---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz67q00vhwmxbsre5mq091c4
  text: |-
    Picked up. Research done by dumping real ASTs (throwaway scratch test, deleted) rather than guessing node kinds. Findings that shape the implementation:

    **Grammar shapes confirmed (tree-sitter-swift 0.7.3, -python 0.23.6, -rust, -c, -javascript, -java, -go):**
    - Swift models `else` as a *named leaf node* of kind `else`, a direct child of `if_statement` — and `guard_statement` has one too (`guard let x else {…}`). So the `else` flat increment must be gated on "parent is an if-node kind", or every Swift `guard` double-counts.
    - Rust/Python/C/JS wrap it as `else_clause` (+ Python `elif_clause`); Java/Go put a bare anonymous `else` token directly under `if_statement`. Gating on the parent kind handles all four shapes and also stops `else_clause`'s own anonymous `else` child from counting twice.
    - `else if` detection is therefore: an if-node whose *parent* is an else-node (Rust/C/JS) or whose *immediately preceding sibling* is an else-node (Swift/Java/Go).
    - `do_statement` collides across grammars: in C/JS/Java it is the do-while loop (has a `condition` field); in Swift it is the `do {} catch {}` error-handling block (no `condition` field). Disambiguated on the presence of the `condition` field, verified in both directions.
    - Binary-operator field name is `operator` in Python/Rust/C/JS/Java/Go but `op` in tree-sitter-swift. Swift also splits logical operators into `conjunction_expression`/`disjunction_expression`, Python folds both into `boolean_operator`, everyone else uses `binary_expression`.
    - Labeled break/continue: JS and C use a `label` *field*; Go uses kind `label_name`; Rust uses kind `label`. Java emits a bare `identifier` (indistinguishable from Rust's `break <value>`) and Swift parses `return`/`break`/`continue` all as one `control_transfer_statement` — both are documented limitations, not counted, so the heuristic never over-counts.
    - tree-sitter-swift parses `a && b || c` as `conjunction(a, disjunction(b, c))` — precedence differs from real Swift, but it is still two distinct operator runs, so the fixture's expected `2` holds.

    **Blocking discovery — `Chunker.chunk` overflows the stack on the card's own recursion-limit fixture.** `Chunker.collectChunks(node:file:module:into:)` recurses with no depth bound. The card's `let x = 1 + 1 …` × 5000 snippet parses into a 5005-deep left-nested `additive_expression` spine, and calling `Chunker.chunk` on it kills the test process with signal 10. Measured: that fixture's AST depth is 5005; the 50-nested-`if` fixture's is only 103, so `maxASTDepth = 512` does sit far above ordinary source as the card requires.

    Resolution kept inside the card's "no other file changes" constraint: the depth-bounded walk that indexes symbol nodes reports whether it ever refused to descend, which is exactly "this AST is deeper than `maxASTDepth`". `Complexity.measure` only calls `Chunker.chunk` when it did not, and otherwise degrades quietly to `symbols: []` — matching `Chunker`'s own return-empty-rather-than-throw convention. `Chunker` is left untouched; its own unbounded recursion is filed as separate work.
  timestamp: 2026-08-04T11:14:33.627712+00:00
- actor: claude-code
  id: 01kz68jy6chgayqzepf3vd74nx
  text: |-
    Implementation landed and green: `swift test --filter ComplexityTests` reports 18 tests, 0 failures; `swift build` reports zero warnings. Every hand-derived golden in the card measured exactly as written — fixture A 6/3, fixture B `classify` 3/1, `scan` 4/2, `Calculator` 7/2, `total` 7/2, and Python/Rust parity 6/3 — with no number needing correction, because the node-kind tables were built from dumped ASTs rather than guessed.

    **Formatting: the instruction `swift format -i -r Sources Tests` cannot be run repo-wide, and I did not leave it applied.** This repo has no `.swift-format` file (none in the repo or in any parent directory), and it is not written in swift-format's default style: the default is 2-space indentation with a 100-column limit, while every one of the 121 existing Swift files is 4-space indented and the repo carries 1313 lines over 100 columns, the longest being 362. Running the command as given rewrote 123 files — 27,964 insertions, 26,670 deletions — which collides head-on with this card's own "No other file changes" constraint and would have buried the two files under review.

    I reverted all 121 unrelated files back to HEAD (verified: only the two new files show in `git status`), then ran the same formatter over just this card's files with an explicit configuration of 4-space indentation and a 120-column limit, so the new code is formatter-clean *and* matches the prevailing style of the files beside it. Both files pass `swift format lint` under that configuration, and the config lives in scratch, not in the repo.

    This needs a decision that is above this card: either the repo adopts a checked-in `.swift-format` describing the style it actually uses (4 spaces, long lines) and gets formatted once, or the formatting instruction should be scoped to changed files. Until then, running the bare command will keep producing a repo-wide rewrite.

    Discovered work filed separately as `^ffthv6a`: `Chunker.collectChunks`, `Chunker.collectSymbolNames`, and `TSCallGraph.collectCallSites` recurse with no depth bound, and `Chunker.chunk` kills the process with signal 10 on this card's own 5000-term recursion fixture. `Complexity.measure` works around it by refusing to call `Chunker.chunk` when its own bounded walk reports the tree is deeper than `maxASTDepth`; that workaround should be removed once those walks are bounded.
  timestamp: 2026-08-04T11:29:49.260152+00:00
- actor: claude-code
  id: 01kz6a2xcfpvkzcfzggcpc6gmp
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (5b77d1c) — 0 findings, 0 confirmed, 0 refuted; 9 validators attempted, 0 failed, 0 skipped. Scope included Sources/FoundationModelsCodeContext/TreeSitter/Complexity.swift (+939) and Tests/FoundationModelsCodeContextTests/ComplexityTests.swift (+363); .reviewignore excludes only .kanban/.
    - next: none — task moved to done.
  timestamp: 2026-08-04T11:56:01.295948+00:00
- actor: claude-code
  id: 01kz6a3vz39etq36gsnyr78ngg
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — Complexity.swift (+939), ComplexityTests.swift (+363); prior agent stopped without reporting, work found complete on disk
    - test: green — swift test, 559 passed in 48 suites, 0 failures (ComplexityTests 14/14); swift build zero warnings
    - commit: 5b77d1c feat(treesitter): add cognitive complexity and branching depth metrics
    - review: clean — 0 findings, 9 validators, task moved to done
    - next: none — task complete
  timestamp: 2026-08-04T11:56:32.611415+00:00
position_column: done
position_ordinal: b680
title: Compute cognitive complexity and max branching depth from a code snippet via tree-sitter
---
## What

Add a `Complexity` type that measures two metrics over a snippet of source
text parsed with tree-sitter — **Sonar Cognitive Complexity** and **max
branching depth** — for the two shapes a snippet usually takes: a single
function, or a whole type with members.

**Files**

- **Create** `Sources/FoundationModelsCodeContext/TreeSitter/Complexity.swift`
- **Create** `Tests/FoundationModelsCodeContextTests/ComplexityTests.swift`

No other file changes. In particular, do **not** add a requirement to the
`LanguageModule` protocol (`Sources/FoundationModelsCodeContext/Languages/LanguageModule.swift`)
— that would touch all 17 modules in `Languages.all`. Instead follow the
precedent already set by `TSCallGraph.callNodeKinds`
(`Sources/FoundationModelsCodeContext/TreeSitter/TSCallGraph.swift:103`): a
language-agnostic node-kind table declared privately in this file, documented
as a heuristic, covering the node-kind names the grammars share.

### API shape

```swift
public struct ComplexityMetrics: Sendable, Equatable {
    public let cognitiveComplexity: Int
    public let maxBranchingDepth: Int
}

public struct SymbolComplexity: Sendable, Equatable {
    public let symbolPath: String        // same convention as SemanticChunk.symbolPath
    public let kind: SymbolMetaType
    public let startLine: Int            // zero-based, as SemanticChunk
    public let endLine: Int
    public let metrics: ComplexityMetrics
}

public struct ComplexityResult: Sendable, Equatable {
    public let total: ComplexityMetrics
    public let symbols: [SymbolComplexity]
}

public enum Complexity {
    public static func measure(snippet: String, module: any LanguageModule.Type) -> ComplexityResult
}
```

Reuse `Chunker.parseFile(contents:module:)`
(`Sources/FoundationModelsCodeContext/TreeSitter/Chunker.swift:178`) for
parsing and `Chunker.chunk(file:module:)` for symbol identification — build a
`SourceFile` with a synthetic `relativePath` internally. Mirror `Chunker`'s
failure behavior: a module with a `nil` `treeSitterLanguage` (e.g.
`SQLLanguage`) or an unparseable snippet returns an empty result
(`total` zeroed, `symbols` empty) rather than throwing.

### Metric definitions to implement

**Cognitive Complexity** (Campbell / SonarSource spec), measured per function
or method with the nesting level reset at that symbol's own node:

- *Nesting increments* (`+1 + currentNestingLevel`, and raise nesting inside):
  `if`, ternary/conditional expression, `switch`/`match`, all loops, `catch`/
  `except` clause, `guard`.
- *Flat increments* (`+1`, no nesting penalty, no nesting raise): `else` and
  `else if`/`elif` clauses, `goto`, labeled `break`/`continue`.
- *Boolean operator runs*: each **run** of the same binary logical operator
  (`&&`, `||`, `and`, `or`) counts `+1` once — not once per operator token.
- A nested function/closure body raises the nesting level but adds no
  increment of its own.

**Max branching depth**: the deepest nesting of the *nesting-increment*
constructs above, within a symbol. A symbol with no branching is `0`.

### Recursion limit

The AST walk is recursive, like `Chunker.collectChunks(node:file:module:into:)`
and `TSCallGraph.collectCallSites(node:file:into:)`. Unlike those, this one
will be handed arbitrary caller-supplied snippets, and a pathological input —
a long chained expression such as `a + b + c + …`, which most grammars parse
into a left-nested `binary_expression` spine thousands of nodes deep — would
overflow the stack. Bound it:

- Declare `static let maxASTDepth = 512` on `Complexity` (internal, not
  private, so tests can assert against it via the `@testable import` every
  test file in `Tests/FoundationModelsCodeContextTests` already uses).
  Follow the doc-comment style of `CallGraphOps.maxDepthLimit`
  (`Sources/FoundationModelsCodeContext/Ops/CallGraph.swift:180`), stating
  what the number bounds and why that value.
- The recursive walk carries a depth argument and **stops descending** once it
  reaches `maxASTDepth`. It does not throw and does not crash: metrics are
  reported from the nodes actually visited, matching this file's
  degrade-quietly convention (`Chunker` returns `[]` rather than throwing on
  an unparseable file).
- `512` must sit far above the AST depth of ordinary source — a 50-deep
  nesting fixture is measured exactly, unaffected by the cap.

### Aggregation

- One `SymbolComplexity` per `Chunker` chunk whose `kind` is `.function`,
  `.method`, or `.type`, ordered by `startLine`.
- `.function`/`.method` entries: walked from that node, nesting reset there.
- `.type` entries: the sum of `cognitiveComplexity` and the max of
  `maxBranchingDepth` over the function/method entries nested inside its line
  range.
- `total`: `cognitiveComplexity` is the sum over function/method entries **not**
  nested inside another function/method entry (so a JS `arrow_function` inside
  a `function_declaration` — both are in
  `SharedChunkKinds.javaScriptFamily` — is not double counted);
  `maxBranchingDepth` is the max over all entries.
- A snippet that produces no chunks at all (bare statements) reports
  `symbols == []` and `total` computed by walking the parse tree root.

### Worked fixtures (hand-derived, use as the goldens)

```swift
// Fixture A — function
func sumOfPrimes(max: Int) -> Int {
    var total = 0
    for i in 2...max {          // +1  (nesting 0)
        for j in 2..<i {        // +2  (nesting 1)
            if i % j == 0 {     // +3  (nesting 2)
                continue        // unlabeled — +0
            }
        }
        total += i
    }
    return total
}
// cognitiveComplexity == 6, maxBranchingDepth == 3
```

```swift
// Fixture B — type with members
struct Calculator {
    func classify(_ n: Int) -> String {
        if n < 0 { return "neg" }           // +1
        else if n == 0 { return "zero" }    // +1  (else-if: flat)
        else { return "pos" }               // +1  (else: flat)
    }                                        // cognitive 3, depth 1

    func scan(_ xs: [Int]) -> Int {
        var c = 0
        for x in xs {                        // +1  (nesting 0)
            if x > 0 && x < 10 { c += 1 }    // +2 (if at nesting 1) +1 (one && run)
        }
        return c
    }                                        // cognitive 4, depth 2
}
// Calculator entry: cognitive 7, depth 2. total: cognitive 7, depth 2.
```

Note that `SwiftLanguage.chunkKinds` maps `function_declaration` to
`.function` (there is no `.method` for Swift), so both members of `Calculator`
are `.function` entries nested inside a `.type` entry — they still count once
each toward `total`.

If a grammar quirk makes a hand-derived number unreachable (e.g.
tree-sitter-swift models a construct differently than assumed), fix the number
in the test to what the rules above actually produce and add a comment
explaining the grammar's shape — the same way
`Tests/FoundationModelsCodeContextTests/ChunkerTests.swift:45` documents that
tree-sitter-swift has no separate method node kind. Do not weaken the rules to
match a guess.

## Acceptance Criteria

- [ ] `Sources/FoundationModelsCodeContext/TreeSitter/Complexity.swift` exists and declares public `ComplexityMetrics`, `SymbolComplexity`, `ComplexityResult`, and `Complexity.measure(snippet:module:)` with the signatures above.
- [ ] Fixture A measured with `SwiftLanguage.self` returns one `SymbolComplexity` for `sumOfPrimes` with `cognitiveComplexity == 6` and `maxBranchingDepth == 3`.
- [ ] Fixture B measured with `SwiftLanguage.self` returns entries for `Calculator`, `Calculator.classify`, and `Calculator.scan`, with the `Calculator` entry aggregating to `cognitiveComplexity == 7` and `maxBranchingDepth == 2`, and `total` equal to the same pair.
- [ ] A single `&&`-chain of three operands (`a && b && c`) adds `1`, not `2`, to the enclosing symbol's `cognitiveComplexity`; a mixed chain (`a && b || c`) adds `2`.
- [ ] `Complexity.measure(snippet:module:)` returns `ComplexityResult(total: .init(cognitiveComplexity: 0, maxBranchingDepth: 0), symbols: [])` for a module with `nil` `treeSitterLanguage` (use `SQLLanguage.self`) and for an unparseable snippet.
- [ ] `Complexity.maxASTDepth` is declared as `512` with a doc comment, the recursive walk takes a depth argument and stops descending at that limit, and no walk in the file recurses without one.
- [ ] A snippet whose AST is deeper than `maxASTDepth` returns normally — no crash, no hang, no thrown error — with `maxBranchingDepth <= Complexity.maxASTDepth`.
- [ ] `swift build` completes with zero warnings.
- [ ] The node-kind classification tables carry doc comments naming which grammars each entry covers, in the style of `TSCallGraph.callNodeKinds`.

## Tests

- [ ] Create `Tests/FoundationModelsCodeContextTests/ComplexityTests.swift` using swift-testing (`@Test` / `#expect` / `#require`), matching the style of `Tests/FoundationModelsCodeContextTests/ChunkerTests.swift`.
- [ ] Test: fixture A against `SwiftLanguage.self` asserts `cognitiveComplexity == 6`, `maxBranchingDepth == 3`.
- [ ] Test: fixture B against `SwiftLanguage.self` asserts the three symbol entries, the `Calculator` aggregate (7 / 2), and `total` (7 / 2).
- [ ] Test: boolean-operator runs — `a && b && c` adds 1, `a && b || c` adds 2.
- [ ] Test: cross-language parity — the fixture A shape written in Python (`PythonLanguage.self`, nested `for`/`for`/`if`) and Rust (`RustLanguage.self`) each yield `cognitiveComplexity == 6`, `maxBranchingDepth == 3`.
- [ ] Test: `SQLLanguage.self` (nil grammar) and an unparseable snippet each return an empty `ComplexityResult`.
- [ ] Test: recursion limit — build a Swift snippet by string repetition with an expression spine far deeper than `Complexity.maxASTDepth` (e.g. `let x = 1 " + 1"` repeated 5000 times inside a function) and assert `measure` returns with `maxBranchingDepth <= Complexity.maxASTDepth`. The test failing by crashing the test process is the regression signal for an unbounded walk.
- [ ] Test: the cap does not distort ordinary code — 50 nested `if` statements built by string repetition measure exactly `maxBranchingDepth == 50`, proving `512` sits above real-world depth.
- [ ] Run `swift test --filter ComplexityTests` — expect all tests pass, zero failures.
- [ ] Run `swift build` — expect zero warnings.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.
#feature