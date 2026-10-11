---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Send embed calls that cover the dirty chunks of several files, not 32 chunks of one file
---
## Problem

`TreeSitterWorker.embedInBatches` sends at most `defaultEmbeddingBatchSize` (32) chunks in one `embed(texts:)` call, and the chunks of one call come from one file only. FoundationModelsExtras `82c5791` (task ^v4fc9za) now sorts the texts of one call by token count and divides them into sub-batches. That sort helps only when one call holds many texts of different lengths.

`IndexBenchmark` on this package (2026-10-11, Qwen3-Embedding-0.6B-4bit-DWQ, release build) gave:

- 7,674 texts in 408 calls: on average 19 texts for each call, and approximately 320 ms for each call.
- Index pass 144.17 s. Embed time 130.49 s (91% of the pass). 53.2 texts per second.

## Change

- Collect the texts of the dirty chunks of several files, and send them in larger `embed(texts:)` calls.
- Keep the per-file contract: a file is marked `embedded` only when all its chunks have a vector. When a call fails, skip only the files of that call, as now.
- Keep the cancellation check before each call.
- Choose the call size with a reason in its doc comment. Do not add a token limit (the user does not want one).

## Acceptance criteria

- [ ] One `embed(texts:)` call can hold the chunks of more than one file.
- [ ] A file is marked `embedded` only when each of its chunks has a vector.
- [ ] A failed call skips only the files of that call, and the next pass embeds them again.
- [ ] Tests for the cross-file calls, the per-file mark, and the failure path.
- [ ] Run `swift run -c release IndexBenchmark` on this package and record the result on this task, beside the baseline above.
- [ ] `swift build` and `swift test` pass with no warnings. #index #feature