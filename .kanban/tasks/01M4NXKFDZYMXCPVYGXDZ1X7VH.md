---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4p0vnwck822my7x80wye1zq
  text: |-
    Research:
    - `TreeSitterWorker.embedDirtyChunks` drains the `embedded = 0` paths and calls `embedChunks(forFilePath:)` for each file. `embedChunks` reads the chunks of one file, `embedInBatches` sends slices of `batchSize` texts, and one `Store.write` writes the vectors and sets `embedded = 1`. Thus each call holds the chunks of one file only.
    - `CodeContext` passes `TreeSitterWorker.defaultEmbeddingBatchSize` (32). `plan.md` states the value 32.
    - FoundationModelsExtras at `edfd5d8` (in Package.resolved, includes `82c5791`): `MLXEmbedding.embed` sorts the token rows of one call and divides them into sub-batches of 16,384 tokens at most, (rows) x (longest row) (`EmbeddingBatchDivision.defaultTokenBudget`). Its doc comment says that FoundationModelsCodeContext embeds 32 chunks in each call. That text is in the other repo, and this task does not change it.
    - Test doubles: `GatedEmbedder` + `EmbedCallLog` record the size of each chunk call and keep the probe call apart. `FakeEmbedder` can fail on each call. No double fails on one call only, thus the failure-path test needs a new double.
    - Plan: a value type `EmbeddingCallQueue` keeps the dirty chunks of several files in file order. Each call takes the next `batchSize` texts, also from more than one file. A file is written and marked `embedded` when all its chunks have a vector. A failed call removes the files of that call (also their vectors from earlier calls and their chunks that are not sent). The cancellation check stays before each call.
    - The benchmark indexes this repo, thus new source and test files of this task add chunks. The texts count will change for that reason.
  timestamp: 2026-10-11T17:41:07.084328+00:00
- actor: claude-code
  id: 01m4p1q6j93m9t1108851g2ad7
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsCodeContext/Index/EmbeddingCallQueue.swift`: `EmbeddableChunk` (moved from TreeSitterWorker), `EmbeddingCall`, `EmbeddedFile`, `EmbeddingCallQueue` (append / nextCall / complete / skip / isEmpty / unsentCount).
    - `TreeSitterWorker.embedDirtyChunks` now reads the chunks of each dirty file, appends them to the queue, and sends a call each time `batchSize` texts are ready; the last call holds the texts that are left. `embedNextCall` checks cancellation before each call. `embed(_:with:tracer:)` logs one warning for each file of a failed call. `writeVectors(of:store:)` writes the complete files of a call in one transaction (vectors + `embedded = 1`). `embedInBatches` and `embedChunks` are removed.
    - `defaultEmbeddingBatchSize` 32 -> 256, with the reason in its doc comment (256 x 64 tokens = the 16,384-token sub-batch budget of FoundationModelsExtras; approximately 4 s for each call at the baseline rate, thus cancellation stays fast).
    - Tests: new `CrossFileEmbeddingTests` (3 tests: cross-file call, per-file mark, failure path + next pass), new `EmbeddingCallQueueTests` (4 tests). `GatedEmbedder` got `failingCallNumbers`. `TracingSpanTests.theEmbedSpansOfAnIndexPassAreChildrenOfThePassSpan` expected one embed span for each file; it now expects 2 spans (probe + one call for all 3 files), because the old count encoded the per-file calls that this task removes.
    - `plan.md` updated (256, cross-file calls).
    - `swift build --build-tests`: no compiler warning. The one SwiftPM line `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)` is also on a clean HEAD (checked with git stash), thus it does not come from this change.
    - `swift test`: 834 tests in 76 suites passed.
  timestamp: 2026-10-11T17:56:08.905067+00:00
- actor: claude-code
  id: 01m4p26f0eq6r21rqr43pjtd9z
  text: |-
    IndexBenchmark after this change (2026-10-11, release build, `swift build -c release --product IndexBenchmark` then `.build/release/IndexBenchmark "$PWD"`, Qwen3-Embedding-0.6B-4bit-DWQ, `defaultEmbeddingBatchSize` = 256):

    | | Baseline (description) | This change | Difference |
    |---|---|---|---|
    | Index pass | 144.17 s | 116.75 s | -27.42 s (-19.0%) |
    | Embed time | 130.49 s | 105.01 s (90% of the pass) | -25.48 s (-19.5%) |
    | Embed calls | 408 | 32 | -376 |
    | Texts embedded | 7,674 | 7,702 | +28 |
    | Largest call | (32 texts) | 256 texts | |
    | Texts per second, pass | 53.2 | 66.0 | +24% |
    | Texts per second, embed only | 58.8 | 73.3 | +25% |

    Other output: model load and first embed 2.75 s; 244 files walked, parsed and embedded; 2,443,149 text characters. The mean time of one call is approximately 3.3 s (105.01 s / 32), thus the cancellation latency stays near the 4 s that the doc comment of `defaultEmbeddingBatchSize` states.

    Why the texts count changed (+28): the benchmark copies and indexes the working tree of this repo, and this change adds and edits Swift and Markdown files in it. I chunked the changed files with `Chunker.chunk(file:module:)` at HEAD and in the working tree: 70 chunks before, 98 chunks after (EmbeddingCallQueue.swift +10, CrossFileEmbeddingTests.swift +8, EmbeddingCallQueueTests.swift +8, TreeSitterWorker.swift 15 -> 16, GatedEmbedder.swift 10 -> 11; TracingSpanTests.swift, plan.md and the task .md file unchanged). 98 - 70 = 28, which is the full difference. No text is cut and no token limit is added.
  timestamp: 2026-10-11T18:04:29.070086+00:00
- actor: claude-code
  id: 01m4p26w6ycnk43ffz52gxmfqt
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsCodeContext/Index/EmbeddingCallQueue.swift (new), Sources/FoundationModelsCodeContext/Index/TreeSitterWorker.swift, Tests/FoundationModelsCodeContextTests/CrossFileEmbeddingTests.swift (new), Tests/FoundationModelsCodeContextTests/EmbeddingCallQueueTests.swift (new), Tests/FoundationModelsCodeContextTests/Support/GatedEmbedder.swift, Tests/FoundationModelsCodeContextTests/TracingSpanTests.swift, plan.md, plus this task file. `swift build --build-tests`: no compiler warning (only the SwiftPM `missing creator for mutated node` line for the mlx-swift bundle, which is also on a clean HEAD). `swift test`: 834 tests in 76 suites passed. IndexBenchmark: pass 116.75 s (baseline 144.17 s), embed 105.01 s (130.49 s), 32 calls (408), 7,702 texts (7,674; +28 from the new and edited files of this change), 66.0 texts/s pass (53.2), 73.3 texts/s embed only (58.8).
    - next: /review. Not committed. Note: the doc comment of `EmbeddingBatchDivision.defaultTokenBudget` in FoundationModelsExtras still says that FoundationModelsCodeContext embeds 32 chunks in each call; that text is in the other repo.
  timestamp: 2026-10-11T18:04:42.590694+00:00
position_column: doing
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

- [x] One `embed(texts:)` call can hold the chunks of more than one file.
- [x] A file is marked `embedded` only when each of its chunks has a vector.
- [x] A failed call skips only the files of that call, and the next pass embeds them again.
- [x] Tests for the cross-file calls, the per-file mark, and the failure path.
- [x] Run `swift run -c release IndexBenchmark` on this package and record the result on this task, beside the baseline above.
- [x] `swift build` and `swift test` pass with no warnings. #index #feature