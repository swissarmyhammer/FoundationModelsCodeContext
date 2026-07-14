---
comments:
- actor: wballard
  id: 01kwss673excsjkq16hzywe77t
  text: |-
    Implementation landed via TDD. Key research finding: of the 5 grammars, tree-sitter-json, tree-sitter-bash (both tree-sitter org), tree-sitter-yaml and tree-sitter-markdown (both tree-sitter-grammars org) all have working SwiftPM manifests with generated sources committed to git. tree-sitter-sql (DerekStride/tree-sitter-sql, the grammar the Rust sibling uses as crate `tree-sitter-sequel`) does NOT — its bindings/swift/Package.swift references src/parser.c and src/grammar.json that are absent from git at every tag and on main (only src/scanner.c is checked in; the rest is produced by `tree-sitter generate` and bundled only into npm/crates.io release tarballs). Per Languages.swift's stated policy, SQLLanguage.treeSitterLanguage is nil with the gap fully documented (in SQLLanguage.swift, Languages.swift's grammar-availability table, LanguageModule.swift's protocol doc comment, and Package.swift) rather than standing up a wrapper package.

    Also found: tree-sitter-yaml has a scanner.c/FileManager.fileExists gating bug starting at v0.7.1 (same pattern as the existing python/js pins) — pinned exact to 0.7.0, which still lists src/scanner.c unconditionally.

    Implemented all 5 modules (SQL, JSON, YAML, Markdown, Bash) with languageServer: nil, chunkKinds ported from Rust chunk.rs where present (SQL create_* statements, bash function_definition) or newly designed for JSON/YAML/Markdown (which chunk.rs doesn't cover at all — mapped pair/block_mapping_pair/flow_pair/section to .other since there's no function/type analogue in these formats). Registered in Languages.all. Added 4 new SPM grammar dependencies to Package.swift (json, yaml, markdown, bash) plus documentation of why sql was excluded.

    Extended Tests/FoundationModelsCodeContextTests/LanguageModuleTests.swift with 15 new/updated tests. Also had to update two pre-existing "every module" invariant tests (everyModuleHasATreeSitterLanguage, everyModuleDeclaresALanguageServer) since they no longer hold universally now that SQL/format modules exist — renamed and scoped them to exclude the documented exceptions, and added explicit tests for the exceptions.

    swift build: clean, zero warnings. swift test --filter LanguageModuleTests: 50/50 passing.
  timestamp: 2026-07-05T18:38:26.926982+00:00
- actor: wballard
  id: 01kwst8nr5bqf8fex7d3ks75ws
  text: |-
    Adversarial double-check (via really-done) caught a real bug before handoff: SQLLanguage.chunkKinds used node-kind keys "create_function_statement"/"create_table_statement"/"create_view_statement" copied verbatim from the Rust chunk.rs EMBEDDABLE_NODE_KINDS constant. I verified directly against DerekStride/tree-sitter-sql's actual grammar source (grammar/statements/create.js, create-function.js, create-procedure.js at v0.3.11, the exact version the Rust sibling pins in Cargo.lock) — the real rule names are create_function, create_table, create_view (no "_statement" suffix); only create_procedure matched as-is. This means the Rust reference's own chunk.rs has a latent bug: its SQL section doesn't actually match the grammar version it's pinned to. Fixed by using the verified-correct node names instead of blindly porting the buggy Rust mapping, and documented the discrepancy in SQLLanguage's doc comment so a future reader isn't confused by the mismatch with chunk.rs. Also corrected two secondary doc-comment inaccuracies the reviewer found (Package.swift is at the tree-sitter-sql repo root, not under bindings/swift/; the manifest doesn't reference grammar.json, only parser.c and scanner.c).

    Re-ran TDD cycle for this fix: updated test expectations first (RED — 3 failures), then fixed SQL.swift (GREEN — 50/50 passing). Re-verified swift build clean and swift test --filter LanguageModuleTests 50/50 green after the fix.
  timestamp: 2026-07-05T18:57:16.037041+00:00
- actor: wballard
  id: 01kwstm0wv16s44vcmyaq9sk86
  text: |-
    Second-round double-check (re-check of the first fix, per really-done's "at most once" re-spawn bound) caught one more real error: SQLLanguage.chunkKinds still had "create_procedure": .function, but at DerekStride/tree-sitter-sql v0.3.11 (the exact pinned version) the grammar has no create_procedure rule at all — I verified this myself directly (not just trusting the agent) by downloading the actual v0.3.11 grammar.js and grepping it: only create_table/create_view/create_function rule definitions exist, plus a bare `keyword_procedure` token used elsewhere and a `// TODO: procedure` comment confirming CREATE PROCEDURE isn't implemented in this version. My earlier verification of create_procedure had mistakenly checked the `main` branch (which has since been refactored into a grammar/statements/*.js directory structure with a real create_procedure rule) rather than the v0.3.11 tag the doc comment claimed to cite.

    Fixed: removed the create_procedure entry from SQLLanguage.chunkKinds, corrected SQL.swift's doc comment to explain the omission and to stop citing the nonexistent grammar/statements/*.js file layout (v0.3.11's grammar lives in one root-level grammar.js), and added a dedicated regression test (sqlChunkKindsHasNoCreateProcedureEntry) locking in that this key is deliberately absent. Also cleaned up two remaining stale "grammar.json" references in Package.swift's SQL comment, Languages.swift's table, and this test file's comment — the manifest only ever referenced parser.c/scanner.c, never grammar.json.

    Used my one really-done re-spawn allowance on the create_table/create_view/create_function key-name fix (that one passed re-check except for this create_procedure finding). Since the bound is "at most once," I did not spawn a third double-check for this final fix — instead verified it myself first-hand against the pinned grammar source before claiming done, per the Iron Law.

    Final state: swift build clean (zero warnings), swift test --filter LanguageModuleTests 51/51 passing (fresh run). Task remains in doing for /review.
  timestamp: 2026-07-05T19:03:27.899534+00:00
- actor: wballard
  id: 01kwsvf4c8ksnqg18g4h4ky64e
  text: 'Round 1 review (scope: HEAD~1..HEAD, commit ebbdb0b) — clean. Engine attempted 15 checks against the new tree-sitter-only format modules (SQL, JSON, YAML, Markdown, Bash) plus the touched lines in Languages.swift, LanguageModule.swift, LanguageModuleTests.swift, Package.swift, and Package.resolved. Zero findings, zero confirmed, zero refuted. Moved doing → review → done.'
  timestamp: 2026-07-05T19:18:16.200472+00:00
depends_on:
- 01KWJ3PSVZTXYZDX1ASZ3GN09M
position_column: done
position_ordinal: 9c80
title: Tree-sitter-only format modules (sql, json, yaml, markdown, bash)
---
## What
Add the tree-sitter-only format modules, one file each under `Sources/FoundationModelsCodeContext/Languages/`: SQL, JSON, YAML, Markdown, Bash — all with `languageServer: nil`. Register in `Languages.all`; add their grammar SPM dependencies to `Package.swift` (note any needing wrapper packages in doc comments, same convention as the LSP-backed module task). Chunk-kind tables from Rust `chunk.rs` (e.g. SQL `create_*` statements → .type/.function analogues per the Rust mapping, markdown sections, bash function definitions).

## Acceptance Criteria
- [ ] Extension lookup resolves .sql/.json/.yaml/.yml/.md/.sh
- [ ] Every format module has `languageServer == nil` and non-empty `chunkKinds`
- [ ] Each grammar parses a fixture snippet with a non-error root node

## Tests
- [ ] Extend `Tests/FoundationModelsCodeContextTests/LanguageModuleTests.swift`: chunkKinds spot checks per format (e.g. bash `function_definition` → .function), nil-server assertions, parse smoke tests
- [ ] Run `swift test --filter LanguageModuleTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.