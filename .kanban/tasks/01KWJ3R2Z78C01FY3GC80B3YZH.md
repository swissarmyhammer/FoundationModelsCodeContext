---
comments:
- actor: wballard
  id: 01kwjqrgdd4natj8vtv9hfz385
  text: |-
    Implemented all 9 LSP-backed v1 language modules: TypeScript, TSX, JavaScript, Go, C, CPP, Java, CSharp, PHP under Sources/FoundationModelsCodeContext/Languages/, following the Swift/Rust/Python pattern exactly. Registered in Languages.all (now 12 modules total).

    Scope note applied per explicit instruction: did NOT create any wrapper GitHub repos. Instead researched grammar availability directly — turns out all 9 needed grammars already have working upstream SwiftPM support (all under github.com/tree-sitter/*), so every new module got a real non-nil treeSitterLanguage. No nil grammars ended up being needed; grammar availability table is effectively "9/9 resolved from upstream SPM". Added deps to Package.swift: tree-sitter-typescript (bundles both TypeScript and TSX as two targets under one "TreeSitterTypeScript" product — no separate TSX product exists upstream), tree-sitter-javascript, tree-sitter-go, tree-sitter-c, tree-sitter-cpp, tree-sitter-java, tree-sitter-c-sharp, tree-sitter-php.

    Found and fixed one real build breakage: tree-sitter-javascript's `from:` pin floated to v0.25.0, which (like the already-documented tree-sitter-python issue in Package.swift) gates `src/scanner.c` behind a `FileManager.default.fileExists` check that resolves against the wrong working directory in a top-level SwiftPM build, dropping the external scanner and causing an undefined-symbol link error. Pinned `exact: "0.23.1"` instead, matching the same pattern/comment style as the existing Python pin.

    Shared-instance de-duplication: SharedServerSpecs.swift (typeScriptFamily used by ts/tsx/js, clangd used by c/cpp), SharedChunkKinds.swift (identical js/ts/tsx chunk-kind + container tables), SharedProjectMarkers.swift (package.json marker for ts/tsx/js; CMakeLists.txt+Makefile markers for c/cpp) — added the latter two after the local review tool caught the duplication on first pass (two review/fix cycles).

    Extended Tests/FoundationModelsCodeContextTests/LanguageModuleTests.swift: extension resolution for all 8 new extensions (ts/tsx/js/go/c/cpp/java/cs/php), chunk-kind spot checks per module, shared-ServerSpec equality + dedupe-by-command assertions for both shared-spec families, and a parse-smoke test per new grammar (Parser().setLanguage + parse + assert !rootNode.hasError). 38 tests in LanguageModuleTests, 153/153 across the full suite pass, clean `swift build` from a fully wiped `.build`+`Package.resolved` with zero warnings in our own code (one pre-existing deprecation warning lives inside the sibling FoundationModelsRouter dependency).

    Local review tool ran twice; two real duplication findings addressed (see SharedProjectMarkers above), two casing-nitpick findings refuted against established codebase precedent (LspSymbols/LspCallEdges/drainLspDirty already use "Lsp" not "lsp"; the original pre-existing test was already named registryContainsAllThreeV1Modules with capital V1), one false-positive "Set == Array literal doesn't compile" finding refuted by the fact it compiles and passes (Set's ExpressibleByArrayLiteral). Adversarial double-check agent dispatched for independent verification before handoff.
  timestamp: 2026-07-03T00:58:48.109185+00:00
- actor: wballard
  id: 01kwjqyge7eaz6sg1n6jddhxth
  text: 'Adversarial double-check agent returned REVISE: no findings on correctness/build/tests/duplication/naming/force-unwraps, but caught that the literal AC line "Grammar availability table documented" wasn''t satisfied — the grammar-sourcing rationale was only scattered prose per-module, not an actual table. Fixed: added a markdown grammar-availability table (language, upstream repo, SwiftPM support) to Languages.swift''s doc comment covering all 12 v1 modules (all show "yes" since none needed a nil/wrapper fallback), plus a closing note on how a future gap would be documented instead of worked around. Rebuilt and reran full suite after the doc-only change: swift build clean, 153/153 tests pass. Task is green and ready for /review.'
  timestamp: 2026-07-03T01:02:04.743193+00:00
- actor: wballard
  id: 01kwjrfzhawd9b586dtqmd5jgk
  text: 'Implemented 9 LSP-backed language modules (TypeScript, TSX, JavaScript, Go, C, C++, Java, C#, PHP) plus shared dedupe helpers. Scope note: wrapper-repo creation was explicitly descoped by the user for this session; turned out unnecessary anyway — all 9 grammars had working upstream SPM support (tree-sitter/tree-sitter-*), documented as a table in Languages.swift. Tested, checkpointed (c16746b). Review clean on first pass, moved doing → review → done.'
  timestamp: 2026-07-03T01:11:37.258749+00:00
depends_on:
- 01KWJ3PSVZTXYZDX1ASZ3GN09M
position_column: done
position_ordinal: '8680'
title: LSP-backed v1 language modules (ts/tsx/js, go, c/cpp, java, c#, php)
---
## What
Add the LSP-backed remainder of the v1 set, one file per module under `Sources/FoundationModelsCodeContext/Languages/`: TypeScript, TSX, JavaScript (shared `typescript-language-server` ServerSpec instance), Go (`gopls`), C and C++ (shared `clangd` spec), Java (`jdtls`), CSharp (`omnisharp`), PHP (`intelephense`). Register in `Languages.all`. Add grammar SPM dependencies to `Package.swift`. **Grammar availability spike (explicit AC below): enumerate which of these grammars ship upstream Package.swift support and which need a wrapper package; record the findings as a table in the module files' doc comments, and create wrapper repos under the swissarmyhammer org only for the ones that need it.** Chunk-kind tables ported per language from Rust `chunk.rs`; markers from `swissarmyhammer-project-detection`; specs from `builtin/lsp/*.yaml`.

## Acceptance Criteria
- [ ] Extension lookup resolves .ts/.tsx/.js/.go/.c/.cpp/.java/.cs/.php
- [ ] js/ts/tsx modules reference the identical ServerSpec instance (dedupe-by-command yields one command); likewise c/cpp
- [ ] Grammar availability table documented; every grammar dependency resolves and parses a snippet (non-error root node)

## Tests
- [ ] Extend `Tests/FoundationModelsCodeContextTests/LanguageModuleTests.swift`: per-module chunkKinds spot checks (e.g. java `method_declaration` → .method, c# `class_declaration` → .type); shared-spec identity assertions; parse smoke test per grammar
- [ ] Run `swift test --filter LanguageModuleTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.