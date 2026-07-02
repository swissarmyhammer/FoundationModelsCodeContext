---
comments:
- actor: wballard
  id: 01kwjcvmw7haqcdqsexx4vphza
  text: |-
    Implemented the pure Search primitives per the task's scope (Tokenizer.swift, Trigram.swift, BM25.swift, RRF.swift, Hit.swift under Sources/CodeContextKit/Search/), TDD'd against Tests/CodeContextKitTests/RankerTests.swift (30 tests, all ported/adapted from crates/swissarmyhammer-search's tokenize.rs and score.rs golden test cases in the sibling monorepo at /Users/wballard/github/swissarmyhammer/swissarmyhammer/crates/swissarmyhammer-search/).

    Confirmed RED first (types missing -> compile error), then implemented all 5 source files and reached GREEN: swift test --filter RankerTests -> 30/30 pass. Full suite: swift test -> 59/59 pass across 5 suites, swift build -> exit 0, no warnings from new code.

    Design notes / deviations from the literal Rust API (documented as intentional Swift idioms, not gaps):
    - Used Double instead of f32 throughout (idiomatic Swift default float type); ordering/formula equivalence is what's tested, not bit-exact f32 parity.
    - Trigrams represented as 3-character Strings (Set<String>) rather than Rust's [char;3] arrays — simpler/idiomatic, same semantics.
    - BM25Corpus/RRF operate on precomputed weighted-term-frequency dictionaries (mirroring Rust's score.rs functions), not on Doc/Field/Query types — those live in the Rust lib.rs's search() orchestration, which is explicitly out of scope here (belongs to the separate later task 01KWJ3VER6934379BZKH1ZXGJN, SearchCorpus + searchCode + Accelerate cosine wiring, which depends on this task).
    - Added BM25.symbolPathFieldWeight (5.0) / BM25.bodyFieldWeight (1.0) as named public constants so tests (and future SearchCorpus callers) never hardcode the field-weight literals — avoids the literal-duplication churn flagged on a prior sibling task.
    - RRF.swift includes both fuse(...) and normalize(...) per the task's own bullet list ("RRF fusion... [0,1] normalization"), mirroring the top-level search()'s max-achievable-score normalization from lib.rs.

    Acceptance criteria covered directly by named tests: bm25SymbolPathMatchOutranksBodyOnlyMatchForSameTerm, rrfTwoListsBeatOne, rrfMissingDocContributesNothing, fusedBm25AndTrigramSignalsRankSymbolPathMatchFirst (multi-signal golden ordering).

    Spawned the double-check adversarial reviewer per really-done; will report its verdict and act on findings before final handoff.
  timestamp: 2026-07-02T21:48:16.647940+00:00
- actor: wballard
  id: 01kwjda1sa9awab2nans925ztr
  text: |-
    Adversarial double-check (per really-done) returned REVISE with two concrete findings; both fixed:

    1. Tokenizer.swift didn't reproduce Rust's unicode_words() MidNumLet gluing for `.`/`'` flanked by letters/digits (e.g. Rust glues "foo.bar" and "don't" into single words before case-splitting; the Swift port was dropping the punctuation and splitting into separate tokens). Fixed by adding isGluedSeparator(...) so a `.`/`'` with a letter/digit on both sides glues into the run (leading/trailing/punctuation-adjacent `.`/`'` still breaks, unchanged). Added 3 new tests (periodBetweenLettersGluesRunLikeUnicodeWordsMidNumLet, apostropheBetweenLettersGluesContraction, leadingAndTrailingPeriodsAreStrippedNotGlued) and verified true TDD RED (temporarily reverted the fix, confirmed the two positive-case tests failed for the right reason with a clear diff, then restored the fix and confirmed GREEN).

    2. fusedBm25AndTrigramSignalsRankSymbolPathMatchFirst built its expected RRF ranking arrays from the runtime-computed scores (`strongBm25 >= mediocreBm25 ? ...`) rather than asserting the claim directly, making it an indirect/harder-to-audit golden test. Fixed by adding direct `#expect(strongBm25 > mediocreBm25)` / `#expect(strongTrigram > mediocreTrigram)` assertions before building the (now-hardcoded) ranking arrays.

    3. Acceptance-criteria/test checkboxes in this task's description were still unchecked despite being satisfied — checked them off.

    Final verification: swift build -> exit 0, no warnings from new code; swift test (full suite) -> 62/62 pass across 5 suites (33 in RankerTests). Leaving task in doing for /review per the implement workflow.
  timestamp: 2026-07-02T21:56:08.618129+00:00
- actor: wballard
  id: 01kwje2egw7ancgqvzax5mt58t
  text: |-
    Resolved the 2026-07-02 16:58 review findings, pulled back from `review` into `doing`:

    1. BM25.swift: replaced the force-unwrap `frequency[term]! += 1` (inside `for term in presentTerms where frequency[term] != nil`) with `frequency[term, default: 0] += 1` — same guard, same behavior, no `!`.
    2. Tokenizer.swift: renamed `charTrigrams(_ s: String)` -> `charTrigrams(_ text: String)`, updating its doc comment and internal use.

    Per the task's instruction to be exhaustive (sibling ^z3gn09m took 4 review rounds from non-exhaustive fixes), grepped the whole Sources/CodeContextKit/Search/ directory for other force-unwraps and single-letter params before stopping:
    - Force unwraps: none remaining anywhere in the directory (only match pre-fix was the one above).
    - Single-letter params: found a second, identical instance — Trigram.swift's `canonicalTrigramSet(_ s: String)` — renamed to `canonicalTrigramSet(_ text: String)` with doc comment and internal use updated too.
    - RRF.swift's `k: Double` (in `fuse`/`normalize`) is the documented RRF-paper constant name mirroring the public `RRF.k` property, not an ambiguous abbreviation — left as-is, consistent with `BM25.k1`/`BM25.b` naming already established in this codebase.
    - Hit.swift: no short/unclear parameter names.

    Verification: `swift build` -> exit 0, no warnings. `swift test` -> 62/62 pass across 5 suites (33/33 in RankerTests). Adversarial double-check (per really-done) returned PASS with no findings, independently re-running build/test and re-grepping the directory itself.

    Checked both review-finding checkboxes to `- [x]`. Leaving task in `doing` for `/review` per the implement workflow.
  timestamp: 2026-07-02T22:09:28.092248+00:00
depends_on:
- 01KWJ3P3GAY5KVH271AZNAS8D1
position_column: doing
position_ordinal: '80'
title: 'Search ranker primitives: BM25, trigram Dice, RRF fusion'
---
## What\nPure-Swift port of `crates/swissarmyhammer-search` primitives into `Sources/CodeContextKit/Search/`: `Tokenizer.swift` (identifier-aware tokenization matching Rust `tokenize.rs`), `BM25.swift` (corpus with two weighted fields: symbol_path ×5, body ×1), `Trigram.swift` (character-trigram Dice coefficient), `RRF.swift` (Reciprocal Rank Fusion, K=60, per-signal weights, absent-signal tolerance, [0,1] normalization), `Hit.swift` (`Hit` with `Signals { bm25, trigram, cosine }`). No DB or embedder dependency — operates on in-memory documents.\n\n## Acceptance Criteria\n- [x] RRF: a doc ranked in two signals outranks a doc ranked in one; docs absent from a signal contribute nothing for it\n- [x] BM25 field weighting: symbol_path match outranks body-only match for the same term\n- [x] Golden tests ported from the Rust crate's cases produce the same orderings\n\n## Tests\n- [x] `Tests/CodeContextKitTests/RankerTests.swift`: golden ordering cases from `crates/swissarmyhammer-search/src/lib.rs` tests; RRF formula unit tests; trigram Dice known-value tests\n- [x] Run `swift test --filter RankerTests` → all pass\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-02 16:58)\n\n- [x] `Sources/CodeContextKit/Search/BM25.swift:59` — Force unwrap `frequency[term]! += 1` violates the rule against force unwrapping in non-test code. Although the `where frequency[term] != nil` guard makes it safe, the rule forbids force unwraps without exception. Use a guard-let pattern or restructure to avoid force unwrapping: `for term in presentTerms { if frequency[term] != nil { frequency[term] = (frequency[term] ?? 0) + 1 } }` or use `guard` to early-exit for the false case.\n- [x] `Sources/CodeContextKit/Search/Tokenizer.swift:49` — Parameter `s` is a single-letter abbreviation. Should be `text` to match the pattern used in the `tokenize(_:)` function and to follow the clarity-over-brevity principle. Rename parameter `s` to `text` (or `string`) to be consistent with other functions and maximize clarity.\n