---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4nt0hjytvs5mns56v77fnch
  text: |-
    Research results:
    - `Chunker.collectChunks` gives each chunk node a `FoundChunkNode`. Only a node whose kind is in `containerNodeKinds` is a container, and only a container collects member declarations. A member is a chunk whose nearest enclosing chunk is that container.
    - For `@dec class Row:`, the nearest enclosing chunk of each method is the `class_definition`, not the `decorated_definition`. Thus the wrapper collects no members and embeds its full text.
    - `ContainerEmbeddingText.declaration` and `bodyString` already find the body through the `definition` field of a wrapper. Thus `summary(of: wrapper, ...)` gives "decorators + class line" and the docstring with no change.
    - Plan: mark a chunk node as a container also when its `definition` field is a container kind. When the nearest enclosing chunk of a node is the wrapper of that node, record the wrapper on the node and do not make the node a member. When a member declaration goes to a container, it also goes to the wrapper of that container.
    - The symbol path of a top-level `decorated_definition` chunk is `decorated_definition` (the wrapper has no name field).
  timestamp: 2026-10-11T15:41:26.494139+00:00
- actor: claude-code
  id: 01m4nt9zd6hr4n3spw0469hykp
  text: |-
    Implementation is complete.
    - `Chunker.collectChunks`: a chunk node is a container when its kind is a container kind, or when its `definition` field is a container kind (`isContainer(_:module:)`). When the nearest enclosing chunk of a node is the wrapper of that node, the node records `wrapperIndex` and is not a member of the wrapper. `addMemberDeclaration(of:toContainerAt:in:source:)` adds each member declaration to the container and to each wrapper of it.
    - `ContainerEmbeddingText.wrappedDefinition(of:)` is new (internal). `body(of:)` uses it.
    - `Chunker.embeddingTextVersion` is now 2. Its doc comment tells what version 1 was.
    - New golden `Goldens/embedding-text/python-decorated/` (`@functools.total_ordering @dataclasses.dataclass(frozen=True) class Row` and `@functools.cache def label`). The fixture has a docstring on each item, `__all__`, and uses each name. `ruff check --isolated --select D1,PLR2004,F` and `vulture` give no findings, and the module runs.
    - New test `theDecoratedDefinitionChunkOfAPythonFunctionEmbedsItsFullText`. It passed before the change too: it is a guard that the change does not touch decorated functions.
    - `plan.md` describes the wrapper summary.
    - TDD: RED was 2 failures (the python-decorated case of the two container golden tests). GREEN: 8/8 EmbeddingTextTests pass.
    - Full run: `swift build` and `swift test` pass, 827 tests in 74 suites, 0 failures. The only `warning:` lines in the output are the SwiftPM build-graph line "missing creator for mutated node" for the `mlx-swift_Cmlx.bundle` dependency product. That line does not come from the compiler or from this change.
  timestamp: 2026-10-11T15:46:35.558911+00:00
- actor: claude-code
  id: 01m4nta2egb0zxvs7wce2sahvh
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/TreeSitter/Chunker.swift, Sources/FoundationModelsCodeContext/TreeSitter/ContainerEmbeddingText.swift, Tests/FoundationModelsCodeContextTests/EmbeddingTextTests.swift, Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python-decorated/source.py, Tests/FoundationModelsCodeContextTests/Goldens/embedding-text/python-decorated/expected.txt, plan.md; `swift build` OK; `swift test` 827 tests in 74 suites, 0 failures
    - next: /review
  timestamp: 2026-10-11T15:46:38.672141+00:00
- actor: claude-code
  id: 01m4ntjj1awb5sw2zr6a1mqzad
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a6cbb97). 0 findings, 0 confirmed, 0 refuted. 9 validator pairs attempted, 0 failed.
    - next: none. The task is in done.
  timestamp: 2026-10-11T15:51:16.778916+00:00
- actor: claude-code
  id: 01m4ntjrz6akj9r9tf7s6k21p2
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 6 files (Chunker.swift, ContainerEmbeddingText.swift, EmbeddingTextTests.swift, python-decorated golden, plan.md)
    - test: green — swift test, 827 tests in 74 suites passed, 0 skipped
    - commit: a6cbb97
    - review: clean — 0 findings; task in done
  timestamp: 2026-10-11T15:51:23.878386+00:00
position_column: done
position_ordinal: db80
title: A decorated Python class embeds its full text through its decorated_definition chunk
---
## Problem

`PythonLanguage.chunkKinds` makes `decorated_definition` a chunk (`.other`). It is not in `containerNodeKinds`. Thus for a decorated class (for example `@dataclass class Row:` or a Django model with a decorator), the `decorated_definition` chunk embeds the full text of the class. The `class_definition` chunk inside it embeds the summary (task ^q52tsr9), but the wrapper chunk still sends all the member text to the embedder.

## Change

When a `decorated_definition` wraps a container (its `definition` field is a `class_definition`), make the wrapper chunk embed a summary too: the decorators, the class declaration, the doc text and the member declarations. Do not change the chunks of a decorated function.

## Acceptance criteria

- [x] The embed text of a `decorated_definition` that wraps a class is a summary, not the full text.
- [x] A decorated function keeps its full text as its embed text.
- [x] Increase `Chunker.embeddingTextVersion`, so that an index re-embeds one time.
- [x] A golden test for a decorated Python class.
- [x] `swift build` and `swift test` pass with no warnings.

#index #feature