---
comments:
- actor: wballard
  id: 01kwj8hv5t3zttjdm8dz2pa056
  text: |-
    Implemented via TDD. Created Sources/CodeContextKit/Languages/ with one file per concern (matching the Index/ dir's split-by-concern convention): LanguageModule.swift (protocol), SymbolMetaType.swift, ProjectMarker.swift, ServerSpec.swift, Languages.swift (registry + module(forFileExtension:) lookup), and Swift.swift/Rust.swift/Python.swift (the three v1 modules).

    Source material found in the sibling monorepo at /Users/wballard/github/swissarmyhammer/swissarmyhammer:
    - crates/swissarmyhammer-treesitter/src/chunk.rs — EMBEDDABLE_NODE_KINDS/CONTAINER_KINDS constants. Note: these are flat, language-agnostic lists with NO meta-type concept — the chunkKinds:[String:SymbolMetaType] mapping is new design (plan.md calls this out as "one addition over the Rust schema"), not a literal port. Classified each node kind by hand: function-like -> .function, type-decl-like -> .type, everything else embeddable (impl_item, mod_item, macro_definition, const_item, static_item, decorated_definition) -> .other.
    - crates/swissarmyhammer-project-detection/src/types.rs — PROJECT_TYPE_SPECS table for exact marker files.
    - builtin/lsp/{sourcekit-lsp,rust-analyzer,pylsp}.yaml — confirmed all three use startup_timeout_secs: 30, health_check_interval_secs: 60, matching ServerSpec's defaults.
    - Grammar entry points (tree_sitter_swift/rust/python()) and SwiftTreeSitter's Language(_:OpaquePointer) initializer verified against the actual checked-out packages in .build/checkouts/.

    Deviations (documented in doc comments):
    1. Swift containerNodeKinds extends past Rust's single "class_declaration" CONTAINER_KINDS entry to include struct/enum/protocol/extension_declaration, since Swift methods commonly live in all of them, not just classes.
    2. Python projectMarkers = [pyproject.toml, setup.py] only, NOT requirements.txt despite plan.md's prose mentioning it — the actual Rust PROJECT_TYPE_SPECS table for ProjectType::Python doesn't include requirements.txt.
    3. None of the three v1 modules use SymbolMetaType.method (Swift/Rust/Python grammars all use one node kind for both free functions and methods) — .method stays available for later languages with distinct method node kinds (e.g. Java).

    Found and fixed one real bug during a Swift compiler crash investigation: `Languages.all.map(\.name)` (keypath on existential metatype) crashes swift-frontend (SILGen) — rewrote as `.map { $0.name }` in the test file.

    Ran an adversarial double-check (Task tool, double-check agent) against the diff: verdict REVISE with one minor finding — Languages.module(forFileExtension:) normalized the input to lowercase but not each module's declared fileExtensions, so the "case-insensitive" doc-comment claim wasn't fully enforced (harmless today since all extensions are declared lowercase, but not guaranteed by the code). Fixed by lowercasing both sides of the comparison and added a regression test (moduleForFileExtensionMatchesCaseInsensitively).

    Verification: `swift build` succeeds; full `swift test` (not just --filter) is green: 29/29 tests across 4 suites (ScaffoldTests, StoreTests, EmbeddingCodecTests, LanguageModuleTests), 0 failures, 0 warnings. Leaving task in doing for review per /implement workflow.
  timestamp: 2026-07-02T20:33:01.114892+00:00
- actor: wballard
  id: 01kwj9b0dezncjpfdzx4dw9bhx
  text: 'Fixed review finding: renamed ServerSpec''s `languageIds` parameter/property to `languageIDs` (acronym casing) across the whole codebase — ServerSpec.swift (property decl, doc comment, init param, init body), Swift.swift, Rust.swift, Python.swift (call sites), LanguageModuleTests.swift (test call site), and plan.md prose (kept the doc in sync per the task''s "zero remaining occurrences" instruction). Verified `grep -r languageIds` now returns no matches anywhere in the repo.\n\nRan `swift build` (exit 0, no code warnings — only a pre-existing unrelated SwiftPM bundle-provisioning warning about mlx-swift_Cmlx.bundle) and full `swift test` (not filtered): 29/29 tests pass across 4 suites (ScaffoldTests, StoreTests, EmbeddingCodecTests, LanguageModuleTests), 0 failures.\n\nLeaving task in doing for review.'
  timestamp: 2026-07-02T20:46:45.678392+00:00
- actor: wballard
  id: 01kwj9evj0rnb98jdcs4vvwrj2
  text: 'Adversarial double-check (Task tool, double-check agent) ran against the diff: verdict REVISE, one finding — the kanban task''s own `.kanban/tasks/01KWJ3PSVZTXYZDX1ASZ3GN09M.{md,jsonl}` files still contain the old `languageIds` spelling (the original task description text and the append-only event-log history), so my earlier comment''s claim of "no matches anywhere in the repo" was imprecise. Justification for not touching those: `.kanban/*.md` is a live snapshot of task fields (already updated above to `languageIDs` in the Review Findings checklist item text) and `.kanban/*.jsonl` is an append-only audit log of past task states — rewriting historical log entries to match a later rename would corrupt the audit trail''s integrity, not improve it. The rename''s actual scope — Swift source, tests, and plan.md prose — is fully clean per grep. Proceeding without further action on the kanban log files; build and full test suite (29/29) remain green.'
  timestamp: 2026-07-02T20:48:51.776316+00:00
depends_on:
- 01KWJ3P3GAY5KVH271AZNAS8D1
position_column: doing
position_ordinal: '80'
title: LanguageModule protocol, core types, and first modules (swift/rust/python)
---
## What\nCreate `Sources/CodeContextKit/Languages/LanguageModule.swift`: the strategy protocol per plan.md — `name`, `fileExtensions`, `treeSitterLanguage: Language?`, `chunkKinds: [String: SymbolMetaType]`, `containerNodeKinds: Set<String>`, `projectMarkers: [ProjectMarker]`, `languageServer: ServerSpec?`. Supporting value types in the same directory: `SymbolMetaType` (function|method|type|other), `ProjectMarker` (fileName or glob), `ServerSpec` (command, args, languageIds, startupTimeout 30s default, healthCheckInterval 60s default, installHint). `Languages.all` registry enum. First three modules as separate files — `Swift.swift`, `Rust.swift`, `Python.swift` — with chunk-kind tables ported from the Rust `EMBEDDABLE_NODE_KINDS`/`CONTAINER_KINDS` in `crates/swissarmyhammer-treesitter/src/chunk.rs`, markers from `swissarmyhammer-project-detection`, server specs from `builtin/lsp/{sourcekit-lsp,rust-analyzer,pylsp}.yaml`.\n\n## Acceptance Criteria\n- [x] `Languages.all` contains the three modules; extension→module lookup helper resolves `.swift`, `.rs`, `.py`\n- [x] Each module's `chunkKinds` maps at least function-like and type-like node kinds to correct meta-types\n- [x] `ServerSpec` defaults match plan (30s startup, 60s health)\n\n## Tests\n- [x] `Tests/CodeContextKitTests/LanguageModuleTests.swift`: registry lookup by extension; chunkKinds meta-type spot checks per module (e.g. rust `function_item` → .function, `struct_item` → .type); ServerSpec defaults\n- [x] Run `swift test --filter LanguageModuleTests` → all pass\n\n## Workflow\n- Use `/tdd` — write failing tests first, then implement to make them pass.\n\n## Review Findings (2026-07-02 15:36)\n\n- [x] `Sources/CodeContextKit/Languages/ServerSpec.swift:46` — Parameter `languageIds` mixes-case the acronym ID (should be `languageIDs`). Acronyms must not be mixed-case. Rename parameter to `languageIDs`.\n