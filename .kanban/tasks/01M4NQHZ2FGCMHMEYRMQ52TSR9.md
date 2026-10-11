---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4nqk2x68yayqgrnqnkkg87h
  text: 'The related task in FoundationModelsExtras is `^v4fc9za` (on the Extras board): sort the embed texts by token count and divide them into sub-batches in `MLXEmbedding.embed`. Do that task first. Then make the `TreeSitterWorker` calls larger.'
  timestamp: 2026-10-11T14:59:08.326358+00:00
- actor: claude-code
  id: 01m4nqs1aarw9v60qcsh29sy9f
  text: |-
    ### Scope note (before /finish)
    - Do NOT change `TreeSitterWorker.defaultEmbeddingBatchSize` in this task. That item waits for FoundationModelsExtras `^v4fc9za` (sort and divide by token count). Larger calls before that change make the padding cost larger, not smaller.
    - All other items of "Change", "Where" and "Acceptance criteria" are in scope.
  timestamp: 2026-10-11T15:02:23.306961+00:00
- actor: claude-code
  id: 01m4nqzntsvwe5shke94xgm3dr
  text: |-
    ### Research
    - The embedding step reads the chunk text from `ts_chunks` (`TreeSitterWorker.embedChunks`), not from the parse. Thus the embed text must go into the store. Plan: a new nullable column `embedding_text` in `ts_chunks` (migration `v3_embeddingText`). The worker writes NULL when the embed text is the same as `text`, and reads `COALESCE(embedding_text, text)`.
    - A change of the embed-text version must make the chunker run again, because the stored embed text comes from the chunker. Plan: in `TreeSitterWorker.run`, before the tree-sitter drain, compare the version in `meta` (key `embedding_text_version`) with the current version. On a difference: set `ts_indexed = 0`, `embedded = 0`, and `embedding = NULL` for all rows, and record the version, in one transaction. No stored version is version 0 (the rules before this change). On a new index this has no effect, because all files are dirty.
    - A container chunk is a node whose kind is in `chunkKinds` AND in `containerNodeKinds` (Swift class/struct/enum/protocol, Rust impl/mod/trait, Python class).
    - Member chunks: chunks whose nearest enclosing chunk is the container. The chunk walk carries the index of the nearest enclosing chunk as its context, thus one walk finds the members.
    - Python `decorated_definition` has no `body` field. Its declaration uses the `body` of its `definition` field, thus `@property def name(self):` is one member line.
    - No ARCHITECTURE.md in this repo.
  timestamp: 2026-10-11T15:06:00.921714+00:00
- actor: claude-code
  id: 01m4nrtz2xtzcp8dxm7dfpdwvv
  text: |-
    ### Implementation notes
    - New file `Sources/FoundationModelsCodeContext/TreeSitter/ContainerEmbeddingText.swift`: `Chunker.embeddingTextVersion = 1` and `ContainerEmbeddingText` (declaration, doc text, member declarations). `Chunker.collectChunks` now carries the index of the nearest enclosing chunk as the walk context, thus one walk finds the members.
    - `LanguageModule.docTextLocation` (new `DocTextLocation` enum) with default `.precedingComments`. `PythonLanguage` overrides it with `.bodyStringStatement(statementKind: "expression_statement", stringKind: "string")`.
    - `SemanticChunk.embeddingText` (init parameter `embeddingText: String? = nil`, nil gives `text`).
    - Migration `v3_embeddingText` adds nullable `ts_chunks.embedding_text`. The worker writes NULL when the embed text is the text, and embeds `COALESCE(embedding_text, text)`.
    - `Store.embeddingTextVersion()` (0 when not recorded) and `setEmbeddingTextVersion(_:)`. The two meta accessors now share `metaInteger(forKey:)` / `setMetaInteger(_:forKey:)`.
    - `TreeSitterWorker.reconcileEmbeddingTextVersion(store:)` runs at the start of each pass, before the tree-sitter drain. A version change also resets `ts_indexed`, because the stored embed text comes from the chunker. `clearAllEmbeddings(db:dirtyFlags:)` is shared with `reconcileEmbedderDimension`.
    - New metadata keys `embedding.text_version` and `embedding.stored_text_version` (added to the vocabulary test list).
    - `TreeSitterWorker.defaultEmbeddingBatchSize` is not changed (scope note).
    - plan.md: the tree-sitter worker section describes the embed text and the version.

    ### Environment discovery
    - The local `Package.resolved` (gitignored) pinned FoundationModelsExtras at 130eb40 and FoundationModelsRanker at an old main. HEAD needs the newer revisions (`PooledEmbedding` with no `dimension`, no `TextEmbedding` in Ranker). I ran `swift package update foundationmodelsextras` and `swift package update foundationmodelsranker`. No tracked file changed.

    ### Follow-up
    - New task ^zsqta1q: a decorated Python class (`decorated_definition` wrapping a `class_definition`) still embeds its full text through the wrapper chunk, because the wrapper is not a container kind.
  timestamp: 2026-10-11T15:20:55.133679+00:00
- actor: claude-code
  id: 01m4nrv2cg9ng6fv85jr0hjc53
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` (no warnings in package sources); RED seen first (missing `embeddingText` / `embeddingTextVersion`); `swift test --filter "EmbeddingTextTests|StoreTests"` 20 tests passed; full `swift test` 826 tests in 74 suites passed. Files: Sources/.../TreeSitter/ContainerEmbeddingText.swift (new), Sources/.../TreeSitter/Chunker.swift, Sources/.../Languages/LanguageModule.swift, Sources/.../Languages/Python.swift, Sources/.../Index/Migrations.swift, Sources/.../Index/Store.swift, Sources/.../Index/TreeSitterWorker.swift, Sources/.../Tracing/CodeContextTracing.swift, Tests/.../EmbeddingTextTests.swift (new), Tests/.../Goldens/embedding-text/{swift,rust,python}/ (new), Tests/.../StoreTests.swift, Tests/.../CodeContextTracingTests.swift, plan.md.
    - next: /review
  timestamp: 2026-10-11T15:20:58.512048+00:00
- actor: claude-code
  id: 01m4ns8kxwnj335a4m62mas175
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (d0df4e4). 10 findings (10 confirmed, 1 refuted). All are in Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py: lines 1, 5, 13, 17, 20, 29 (2 findings), 30, 33 (2 findings). The 3 Rust tool rules failed because there is no Cargo.toml. They gave no findings.
    - next: Do the 10 findings in the "## Review Findings (2026-10-11 10:22)" checklist. Then run /review again. The task stays in review.
  timestamp: 2026-10-11T15:28:22.460028+00:00
- actor: claude-code
  id: 01m4ns946pxad6vx5f3nrg7m5j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 13 paths (ContainerEmbeddingText.swift, Chunker, LanguageModule, Python, Migrations, Store, TreeSitterWorker, tracing, tests, goldens, plan.md)
    - test: green — swift test, 826 tests in 74 suites passed, 0 skipped
    - commit: d0df4e4
    - review: findings — Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:1, :5, :13, :17, :20, :29, :29, :30, :33, :33
  timestamp: 2026-10-11T15:28:39.126358+00:00
- actor: claude-code
  id: 01m4nsh65pch2851gsc7rmh14s
  text: |-
    ### Review findings fix (python golden source.py)
    - Before the change, `vulture --min-confidence 60 source.py` gave 8 results, not 4: also `limit`, `size`, `find` and `matches`. `ruff check --isolated --select D100,D101,D102,D103,D104,D106,D107` gave the 6 D1 results. I removed the cause in the full file, not only on the lines of the findings.
    - The module, `Repository`, `__init__`, `size`, `find`, `Meta` and `helper` now have docstrings.
    - A module-level `__all__` names `Base`, `Repository` and `helper`. `find` uses `matches` and `limit`. `helper(repository, key)` uses `size`, `find` and `Meta.ordering`. `__init__` sets `rows`.
    - New `class Base` with a docstring, because `Repository(Base)` used a name that the file did not define. The declaration line `class Repository(Base):` does not change.
    - The comment directly before `class Repository` stays, thus the golden still shows that Python does not take a preceding comment as doc text.
    - `expected.txt` did not change. Member docstrings are in the member body, and the member line is the declaration only. Thus the summary is the same. The test compares with the real output, and it passes.
    - Now `vulture` and `ruff` (D1 codes, and the ruff default rules) report nothing for the file.
  timestamp: 2026-10-11T15:33:03.286221+00:00
- actor: claude-code
  id: 01m4nsh8hkxeg2dej96rvvmb9v
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py. `vulture --min-confidence 60 source.py`: 0 results (8 before). `ruff check --isolated --no-cache --select D100,D101,D102,D103,D104,D106,D107 source.py`: 0 results (6 before). `swift test --filter EmbeddingTextTests`: 7 tests passed. expected.txt and the test did not change. All 10 findings are checked.
    - next: /test, then /review
  timestamp: 2026-10-11T15:33:05.715482+00:00
position_column: doing
position_ordinal: '80'
title: Embed a summary of each container chunk, not its full text
---
## Problem

The index embeds the full text of each chunk. `Chunker` makes one chunk for each AST node of a chunk kind (`Sources/FoundationModelsCodeContext/TreeSitter/Chunker.swift`). A container (a class, a struct, a protocol, an impl) is a chunk, and each of its members is also a chunk. Thus the container chunk holds all the member text a second time.

In Django, a class like `QuerySet` is thousands of lines. The embedder gets the full class. The SWE-bench run of FoundationModelsACPAgent turned embeddings off for this reason (`FoundationModelsACPAgent/bench/code-context.config.yaml`, `semanticSearch: false`): on 2026-09-18 the Django clone had 44,532 chunks, and the embedder did 273 of them in 8 minutes.

The user does not want a token limit. A token limit is arbitrary.

## Change

For a container chunk, make a separate embed text from:

1. The declaration: the node text from its start to the start of its `body` field. Most tree-sitter grammars have a `body` field.
2. The doc text: the comment nodes directly before the declaration (`///`, `/** */`, `#`). In Python, the first string statement of the body.
3. The member signatures: the declaration of each member chunk (the same rule as step 1), one line for each member.

A chunk that is not a container keeps its full text as its embed text.

## Where

- `LanguageModule` (`Sources/FoundationModelsCodeContext/Languages/LanguageModule.swift`): add a rule for the location of the doc text. Give a default for the languages with comments before the node. Python overrides it.
- `Chunker`: make the embed text when it makes a container chunk. It has the parse tree at that time.
- `SemanticChunk`: add a field for the embed text (for example `embeddingText`). The `text` field does not change.
- `TreeSitterWorker`: embed the embed text, not `text`. Store the full `text` in `ts_chunks` as now. `grepCode` and the search results do not change.
- Index metadata: store a version number for the embed-text rules. When the stored version is not the current version, clear all embeddings and re-embed (as `reconcileEmbedderDimension` does for a dimension change). The dimension check does not see this change, because the vector length stays the same.
- `TreeSitterWorker.defaultEmbeddingBatchSize` (32, one file): after the FoundationModelsExtras task sorts and divides batches by token count, send larger calls (for example the dirty chunks of several files). More texts in one call give the sort more rows of similar length. (Out of scope for this task: see the scope note comment.)

## Related work

FoundationModelsExtras task: sort and divide the texts of `MLXEmbedding.embed` into sub-batches by token count. That task removes the padding cost of long texts that are not containers (for example a 1,000-line function). Both tasks are necessary.

## Acceptance criteria

- [x] A container chunk embeds its declaration, its doc text and its member signatures, not its full text.
- [x] A chunk that is not a container embeds its full text.
- [x] `ts_chunks.text` keeps the full text of each chunk.
- [x] Python takes the docstring from the first string statement of the body.
- [x] A change of the embed-text version clears all embeddings and re-embeds them one time.
- [x] Tests for Swift, Rust and Python containers, with golden embed texts.
- [x] `swift build` and `swift test` pass with no warnings.

## Follow-up

Run the Django SWE-bench again in FoundationModelsACPAgent. If indexing is fast, remove `semanticSearch: false` from `bench/code-context.config.yaml`. #index #feature #cross-repo

## Review Findings (2026-10-11 10:22)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 8 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 4 file(s) not reviewed — no validator matched:
> - `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/expected.txt` — no validator matches this file
> - `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/rust/expected.txt` — no validator matches this file
> - `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/swift/expected.txt` — no validator matches this file
> - `plan.md` — no validator matches this file

> ⚠️ tool rule 'code-hygiene/dead-code-rust' failed — the tool judged nothing, so its findings are missing:
> error: could not find `Cargo.toml` in `/Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext` or any parent directory
> dead-code-rust: cargo could not check the workspace

> ⚠️ tool rule 'code-hygiene/function-length-rust' failed — the tool judged nothing, so its findings are missing:
> error: could not find `Cargo.toml` in `/Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext` or any parent directory
> function-length-rust: cargo could not run clippy over the workspace

> ⚠️ tool rule 'code-hygiene/missing-docs-rust' failed — the tool judged nothing, so its findings are missing:
> error: could not find `Cargo.toml` in `/Users/wballard/github/swissarmyhammer/FoundationModelsCodeContext` or any parent directory
> missing-docs-rust: cargo could not run clippy over the workspace

- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:1` `code-hygiene/missing-docs-python` — D100 Missing docstring in public module.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:5` `code-hygiene/dead-code-python` — unused class 'Repository'.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:13` `code-hygiene/missing-docs-python` — D107 Missing docstring in `__init__`.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:17` `code-hygiene/missing-docs-python` — D102 Missing docstring in public method.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:20` `code-hygiene/missing-docs-python` — D102 Missing docstring in public method.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:29` `code-hygiene/dead-code-python` — unused class 'Meta'.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:29` `code-hygiene/missing-docs-python` — D106 Missing docstring in public nested class.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:30` `code-hygiene/dead-code-python` — unused variable 'ordering'.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:33` `code-hygiene/dead-code-python` — unused function 'helper'.
- [x] `Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python/source.py:33` `code-hygiene/missing-docs-python` — D103 Missing docstring in public function.
