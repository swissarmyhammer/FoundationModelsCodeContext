---
comments:
- actor: wballard
  id: 01kwjx41f4c3yqmk3spp43yxzw
  text: |-
    Implemented via TDD. Added Sources/CodeContextKit/Projects/ProjectDetection.swift (DetectedProject Codable/Sendable result type, ProjectDetection.detectProjects(rootDirectory:) driven by Languages.all's projectMarkers, ProjectDetection.serverSpecs(for:) deduped by command) and Tests/CodeContextKitTests/ProjectDetectionTests.swift (9 tests: single-language detection, polyglot monorepo with correct directories, multi-marker/multi-language single dir, same-language-two-markers dedup, C# wildcard marker, gitignore exclusion via node_modules/, server-spec dedup, empty-input server-specs, Codable round-trip).

    Reused the existing Walker.walkEntries(rootDirectory:) for all traversal/gitignore semantics — no local gitignore reimplementation, per the task's constraint. Detection groups walked entries by parent directory (seeding the root explicitly since Walker never emits an entry for the root itself), then matches each LanguageModule's projectMarkers against each directory's child names via one shared matches(marker:entryName:) helper (no per-kind duplication).

    Ran full `swift test`: 166/166 pass, 0 failures, 0 warnings from the new file. Adversarial double-check (via really-done) returned REVISE with two minor findings, both fixed: (1) added the same-language-two-markers test that was flagged as interrogated-but-unverified; (2) added the missing `entries:` argument label on the private groupEntryNames helper. Re-ran full suite after fixes: still 166/166 green. Re-verifying with really-done complete — leaving task in doing for /review.
  timestamp: 2026-07-03T02:32:28.900510+00:00
depends_on:
- 01KWJ3PSVZTXYZDX1ASZ3GN09M
- 01KWJ3QTH53M16194BCTX6MKVP
position_column: doing
position_ordinal: '80'
title: Project detection from LanguageModule markers
---
## What
Create `Sources/CodeContextKit/Projects/ProjectDetection.swift` — port of `crates/swissarmyhammer-project-detection` driven by `Languages.all` markers instead of a hardcoded table. **Reuse the `Walker` from the walker/reconciler task for gitignore-aware traversal — do not re-implement gitignore semantics.** Match each module's `projectMarkers` (exact names like `Cargo.toml` and globs like `*.csproj`); one directory can match multiple modules; a monorepo yields one `DetectedProject(language, directory)` per hit. Public `Codable & Sendable` result type. Helper `serverSpecs(for: [DetectedProject]) -> [ServerSpec]` returning specs deduped by command.

## Acceptance Criteria
- [ ] A fixture monorepo with Package.swift + Cargo.toml + two package.json dirs detects swift, rust, and javascript/typescript projects with correct directories
- [ ] Dedupe: two package.json hits yield exactly one `typescript-language-server` spec
- [ ] Gitignored subtrees (e.g. node_modules via .gitignore) produce no detections — via the shared Walker, not a local reimplementation

## Tests
- [ ] `Tests/CodeContextKitTests/ProjectDetectionTests.swift` against temp-dir fixture repos: polyglot detection, multi-type single dir, dedupe-by-command, gitignore exclusion
- [ ] Run `swift test --filter ProjectDetectionTests` → all pass

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.