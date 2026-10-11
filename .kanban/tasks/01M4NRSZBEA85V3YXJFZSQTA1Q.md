---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A decorated Python class embeds its full text through its decorated_definition chunk
---
## Problem

`PythonLanguage.chunkKinds` makes `decorated_definition` a chunk (`.other`). It is not in `containerNodeKinds`. Thus for a decorated class (for example `@dataclass class Row:` or a Django model with a decorator), the `decorated_definition` chunk embeds the full text of the class. The `class_definition` chunk inside it embeds the summary (task ^q52tsr9), but the wrapper chunk still sends all the member text to the embedder.

## Change

When a `decorated_definition` wraps a container (its `definition` field is a `class_definition`), make the wrapper chunk embed a summary too: the decorators, the class declaration, the doc text and the member declarations. Do not change the chunks of a decorated function.

## Acceptance criteria

- [ ] The embed text of a `decorated_definition` that wraps a class is a summary, not the full text.
- [ ] A decorated function keeps its full text as its embed text.
- [ ] Increase `Chunker.embeddingTextVersion`, so that an index re-embeds one time.
- [ ] A golden test for a decorated Python class.
- [ ] `swift build` and `swift test` pass with no warnings.

#index #feature