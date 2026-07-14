---
comments:
- actor: wballard
  id: 01kwvs297je7y0gg6yqjynr0a8
  text: |-
    Root cause confirmed: `LanguageModule.languageServer: ServerSpec?` (Sources/FoundationModelsCodeContext/Languages/LanguageModule.swift) is already the authoritative "does this extension have an LSP" signal — every tree-sitter-only module (SQL, JSON, YAML, Markdown, Bash) sets it to `nil`, every LSP-backed module (Swift, Rust, Python, TS/TSX/JS, Go, C, C++, Java, C#, PHP) sets it non-nil, each traced back to `builtin/lsp/*.yaml` in its own doc comment. No need to parse the yaml directly.

    Fix applied in Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift: `knownExtensions` now filters `Languages.all` to `module.languageServer != nil` before flat-mapping `fileExtensions`, instead of using the full `Languages.all` list. Updated doc comments on `isDiagnosableExtension`/`knownExtensions` to explain the indexable-vs-diagnosable distinction from Walker/Watcher's (deliberately unchanged) copy of the same expression.

    Verification: `swift build` clean, zero warnings. `swift test --filter DiagnosticsTests` — 19/19 pass including `scopeResolutionExcludesNonDiagnosableExtensions`, re-run 3x with no flakiness. Full `swift test` suite: 473/473 pass, exit 0. Spawned adversarial double-check agent for sign-off before handoff.
  timestamp: 2026-07-06T13:14:46.898343+00:00
- actor: wballard
  id: 01kwvs8kx1a1fq50srstq0a3f6
  text: |-
    Adversarial double-check: PASS, no findings. Independently confirmed: (1) only DiagnosticsScope.swift changed, Walker.swift/Watcher.swift untouched; (2) filter correctness verified module-by-module (LSP-backed: Swift/Rust/Python/TS/TSX/JS/Go/C/C++/Java/C#/PHP all languageServer != nil; tree-sitter-only: SQL/JSON/YAML/Markdown/Bash all languageServer == nil); (3) no cross-group extension collisions across all fileExtensions; (4) only caller of resolvePaths is DiagnosticsOps.diagnostics, no other code relies on old broader behavior; (5) independently re-ran swift test --filter DiagnosticsTests (19/19 pass) and full swift test (473/473 pass, exit 0); (6) checked for sibling instances of the same conflation bug elsewhere (CodeContext.swift, QueryAST.swift) — none found.

    Task is done and green. Leaving in `doing` per implement process for /review to pick up.
  timestamp: 2026-07-06T13:18:14.433183+00:00
- actor: wballard
  id: 01kwvsye8xhv6fx55tcxewrm08
  text: |-
    Round 1 review (scope: HEAD~1..HEAD, commit 465323c) — clean, 0 findings across 15 checks (1 refuted candidate discarded).

    Verified fix: `knownExtensions` in DiagnosticsScope.swift now filters `Languages.all` to modules with `languageServer != nil` before flat-mapping `fileExtensions`, correctly separating "diagnosable" (has an LSP) from "indexable" (any registered language, including tree-sitter-only formats like Markdown). Walker.swift/Watcher.swift intentionally keep their own separate, unfiltered indexable-extension logic — different concept (what to index vs. what to diagnose), correctly untouched.

    Test evidence (from task description / prior verification): DiagnosticsTests 19/19 across 3 runs; full suite 3/5 clean at 473/473 (2/5 hit the pre-existing, separately-tracked ConnectionTests flaky timeout — 01KWVSJAR801YR97D051YDWPR5 — unrelated to this fix); build clean; adversarial double-check PASS.

    Moving to done.
  timestamp: 2026-07-06T13:30:09.565368+00:00
position_column: done
position_ordinal: a180
title: DiagnosticsScopeResolver.workingTree includes Markdown files, but they have no LSP to diagnose
---
Sources/FoundationModelsCodeContext/Diagnostics/DiagnosticsScope.swift: `DiagnosticsScopeResolver.isDiagnosableExtension` (and its `knownExtensions` set) is built from `Languages.all.flatMap { $0.fileExtensions }` — the same extension set `Walker`/`Watcher` use to decide what to *index*. `MarkdownLanguage.fileExtensions = ["md", "markdown", "mdx"]` (Sources/FoundationModelsCodeContext/Languages/Markdown.swift) registers Markdown there for tree-sitter chunking purposes, but Markdown has no LSP server entry in `builtin/lsp/*.yaml` (see that file's own doc comment: "a `.md` file doesn't have... Markdown entry in `builtin/lsp/*.yaml`"). So `.md` is indexable but not diagnosable, and `isDiagnosableExtension` conflates the two, causing `DiagnosticsScope.workingTree` resolution to wrongly include Markdown files.

Reproduces deterministically (3/3 runs) in isolation:

```
cd /Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext
swift test --filter DiagnosticsTests/scopeResolutionExcludesNonDiagnosableExtensions
```

Fails with:
```
✘ Test scopeResolutionExcludesNonDiagnosableExtensions() recorded an issue at DiagnosticsTests.swift:455:13: Expectation failed: resolved.isEmpty
↳ resolved.isEmpty → false
↳   resolved → ["README.md"]
```

The test (Tests/FoundationModelsCodeContextTests/DiagnosticsTests.swift, `scopeResolutionExcludesNonDiagnosableExtensions`) commits README.md, modifies it, then resolves `.workingTree` scope and expects the result to be empty (Markdown excluded as non-diagnosable) — it is not.

Also causes the *full* `swift test` suite (not just `--filter DiagnosticsTests`) to report 1 failing issue out of 462 tests — discovered while independently re-verifying kanban task 01KWJW6NBMV98C8EK62VVYGN2X (ConnectionTests coverage additions). Confirmed unrelated to that task: only Tests/FoundationModelsCodeContextTests/ConnectionTests.swift and Tests/FoundationModelsCodeContextTests/Support/scripted-lsp-server.swift are modified in the working tree; DiagnosticsScope.swift, Markdown.swift, and DiagnosticsTests.swift are all untouched/already-committed.

Likely fix: `isDiagnosableExtension` needs a "has an LSP" extension set distinct from `Languages.all`'s full indexable set — e.g. derived from the `builtin/lsp/*.yaml` language registry (whatever type/lookup already backs LSP-server-selection-by-extension), rather than reusing `Languages.all.flatMap { $0.fileExtensions }` verbatim. Needs investigation into what that registry type is named/where it lives before implementing. #test-failure