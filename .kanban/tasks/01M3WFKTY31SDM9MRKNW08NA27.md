---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3wmfpt9z8srmrnzr5mqn6t4
  text: |-
    Research and measurement (probe test, not kept; debug build, 32-core M-series):

    Synthetic tree: 2000 Python files, 4 classes x 10 methods each. Real Chunker: 88001 ts_chunks rows, 43.3 MB of chunk text (the class chunk holds the text of each method chunk, so the text is about 2x the file text).

    Old GrepCode.run with the pattern of the bench (`def add_immediate_loading|def add_deferred_loading|def clear_deferred_loading`):
    - idle: 2.80 s wall, 45.7 s CPU.
    - during a tree-sitter pass: 2.84 s wall, 45.9 s CPU.
    - during a tree-sitter pass and 30 busy threads: 3.83 s wall, 84.9 s CPU.
    - two calls at the same time with the same load: 6.7 s wall each, about 148 s CPU for the two.

    Breakdown of the CPU cost (sequential, same 88001 texts):
    - `Regex(pattern)` compile 88001 times: 14.9 s CPU. (The old code compiles the Swift Regex again in each child task.)
    - one compiled Swift Regex, `firstMatch` over all texts: 6.1 s CPU; `matches(of:)`: 6.2 s CPU.
    - one `NSRegularExpression`, `firstMatch` over all texts: 0.21 s CPU (about 30x faster than Swift Regex).
    - the rest of the 45.7 s is the cost of 88001 child tasks and of the compile in parallel.
    - load of 88001 rows (43 MB) with no match work: about 0.4 s.

    Conclusions:
    - Cause: CPU cost. Each call uses about 46 CPU-seconds for 88k chunks. A Django clone (django/ plus tests/, more files than the probe) gives more. On a machine with fewer cores, with the agent, pylsp, clangd and tsserver on the same CPUs, and with two calls at the same time, this gives 95 s to more than 120 s.
    - `innermostMatches(of:)` is NOT the cause. It is linear: one Dictionary keyed by file position, then one pass.
    - grepCode does NOT wait for the index (no `waitForFirstIndexPass()`, no lock). The store is a GRDB DatabasePool (WAL): the read does not wait for the writer. Measured: a tree-sitter pass in progress does not change the time of one call (2.80 s vs 2.84 s).
    - Question 2 (contention): the tree-sitter pass is sequential (one file at a time, one thread), so it does not take many CPUs. Contention comes from the CPU load of other processes and of concurrent grepCode calls, and each grepCode call itself uses all the cores of the cooperative pool (one child task for each chunk).

    Plan: compile the pattern one time; match with NSRegularExpression (ICU, already used in Gitignore.swift); match in the GRDB read closure on a row cursor (no TaskGroup, no full copy of the rows, no use of the cooperative pool); add the count of files that the tree-sitter layer did not index yet to GrepCodeResult; add a scale benchmark in IntegrationTests.
  timestamp: 2026-10-01T21:03:51.113531+00:00
- actor: claude-code
  id: 01m3wpm1cjrr13yj06qhfg6br0
  text: |-
    Implementation landed (not committed).

    TDD record:
    - RED 1: `grepCodeTellsHowManyFilesTheIndexDoesNotHoldYet` and `grepCodeOnACompleteIndexTellsThatTheIndexIsNotPartial` (SymbolOpsTests.swift, GrepCodeTests) failed to compile: no `unindexedFiles`. GREEN after `GrepCodeResult.unindexedFiles` / `isIndexPartial`.
    - RED 2: `GrepCodeScaleTests` (IntegrationTests) with the old matcher: CPU 45.79 s and 45.55 s, wall 2.65 s and 2.80 s; both tests failed on the CPU budget (5 s).
    - GREEN 2 after the new matcher: idle 0.29 s wall / 0.29 s CPU; during a tree-sitter pass 0.43 s wall / 0.68 s CPU.
    - Added `grepCodeResultEncodesTheCountOfUnindexedFilesAndDecodesItBack` (ResultEncodingTests) for the JSON contract and the round trip.

    What changed in `GrepCode.run`:
    - One `NSRegularExpression` for each call (ICU syntax). The old code compiled a Swift `Regex` again in each child task.
    - One GRDB `Row.fetchCursor` scan in one read transaction, on the reader queue of the store. No `TaskGroup`, no full copy of the rows.
    - The language filter builds its extension set one time (`ChunkFilter`), not one time for each row.
    - The count of unindexed files comes from the same read transaction.
    - The rest (sort, `innermostMatches(of:)`, cap) is the same; all 16 existing GrepCodeTests pass unchanged, also the UTF-8 offset test and the zero-length `\b` test.

    Notes for the next agent:
    - Behavior change: the pattern dialect is now ICU (`NSRegularExpression`), not Swift `Regex`. The tool description and docs/tools.md say "ICU syntax". The common patterns (alternation, `\w`, `\b`, `.*`, escapes, classes) are the same in the two dialects.
    - `IntegrationTests/Package.resolved` (git-ignored) had a stale FoundationModelsExtras pin, so the integration build failed with "cannot find 'TracedCall'". `swift package --package-path IntegrationTests update` corrected it. This is local state only.
    - The integration package now depends on GRDB (the benchmark writes chunk rows directly).
    - `CodeContextManager.grepCode` returns only the matches, thus it does not carry `unindexedFiles`. I did not change that API.
    - Question 3 went to the new card ^qrz0hg1.

    Test runs: `swift test` 741 tests in 68 suites passed; `swift test --package-path IntegrationTests` 11 tests in 8 suites passed.
  timestamp: 2026-10-01T21:41:10.162281+00:00
- actor: claude-code
  id: 01m3wpm6czpmm7k5s5x06k990z
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsCodeContext/Ops/GrepCode.swift, Sources/FoundationModelsCodeContext/Tools/Search/GrepCodeOperation.swift, docs/tools.md, Tests/FoundationModelsCodeContextTests/SymbolOpsTests.swift, Tests/FoundationModelsCodeContextTests/ResultEncodingTests.swift, IntegrationTests/Package.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift (new). Benchmark 88000 chunks: before 45.5-45.8 s CPU / 2.65-2.80 s wall; after 0.29 s CPU / 0.29 s wall idle, 0.68 s CPU / 0.43 s wall during a tree-sitter pass. swift test: 741 passed; IntegrationTests: 11 passed. New card ^qrz0hg1 for question 3.
    - next: /review
  timestamp: 2026-10-01T21:41:15.295913+00:00
- actor: claude-code
  id: 01m3wq2yhkbh1a1v59twrxvmhz
  text: |-
    ### test - green
    - evidence: swift test (root) - 741 tests in 68 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 11 tests in 8 suites passed, 0 failed, 0 skipped. swift format lint -s -r Sources Tests - exit 0.
    - fixed: the first lint run gave 6 errors. LineLength in GrepCodeOperation.swift (the description was too long; I shortened it, and docs/tools.md now holds the same text). OnlyOneTrailingClosureArgument in CodeContextSpans.swift (2 places), ProcessLanguageServerConnection.swift, CodeContext.swift and TracingSpanTests.swift (the body closure is now an argument in the parentheses, not a trailing closure).
    - note: each build prints one build-system line from the mlx-swift dependency: "warning: missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS". It is not from the code of this repo and I did not change it.
    - next: review
  timestamp: 2026-10-01T21:49:18.771985+00:00
- actor: claude-code
  id: 01m3wq3q98a1qyptb48pr3356g
  text: |-
    ### commit — changed
    - evidence: one local commit, "fix(grep): make grepCode fast on a large tree". Not pushed.
    - next: review
  timestamp: 2026-10-01T21:49:44.104061+00:00
- actor: claude-code
  id: 01m3wqkf1jw47ae9vmwnv1zebb
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (71e549d). 0 findings, 0 confirmed, 0 refuted. 14 validator runs, 0 failed. 10 files reviewed. 7 files not reviewed: 6 .kanban files (excluded by .reviewignore) and docs/tools.md (no validator matches this file).
    - next: none. The task is in done.
  timestamp: 2026-10-01T21:58:19.954680+00:00
- actor: claude-code
  id: 01m3wqkpwbe8v4q82x5wp058hy
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files (GrepCode.swift, GrepCodeOperation.swift, docs/tools.md, 2 unit test files, IntegrationTests/Package.swift, new GrepCodeScaleTests.swift)
    - test: green — swift test 741 passed; IntegrationTests 11 passed; swift format lint exit 0
    - commit: 71e549d
    - review: clean — 0 findings (14 validator runs)
  timestamp: 2026-10-01T21:58:27.979716+00:00
position_column: done
position_ordinal: d580
title: grepCode takes 95 s to more than 120 s on a fresh Django clone while the first index pass runs
---
## Problem

`tools.code_context.grepCode` takes 95 s to more than 120 s on a fresh Django clone. One grepCode snippet blocks the runCode snippet pool of the FoundationModelsACPAgent agent. (The pool and the polling are separate cards in Multitool and in the agent. This card is only the grepCode time.)

## Evidence

Source: FoundationModelsACPAgent SWE-bench run of 2026-10-01, instance `django__django-14667`, config `bench/code-context.config.yaml` (autoInstall true, semanticSearch false, a new clone and a new `.code-context/` index for each instance).

- 13:22:23 the instance started (session/new).
- 13:24:16 a runCode snippet with `grepCode({ pattern: "def add_immediate..." })` started. It settled at about 13:25:51 (about 95 s). The result was correct (`Query.clear_deferred_loading` in `django/db/models/sql/query.py`).
- 13:24:25 a second grepCode snippet started. It ended with "runCode timed out after 120.0 seconds with no progress".
- `tools.files.grep` over the same tree took about 2.3 s. A grepCode in an earlier instance of the same run answered in a few seconds.
- Effect: about 210 of 348 later runCode calls of that instance failed ("Too many runCode snippets are running at once") or went pending.
- The grepCode calls came about 2 minutes after session/new. The first index pass of the clone was probably still in progress.

Transcripts: `FoundationModelsACPAgent/bench/preds.code-context.transcripts/` (folder `django__django-14667`). Run log: `FoundationModelsACPAgent/bench/run.code-context.log`.

## Related log lines at each session close (all instances)

- A pylsp `references` request fails with `Swift.CancellationError`.
- Then "the content hashes of a file could not be read; the call sites of the file are not checked" and "the LSP index of a file could not be written to the store" (`CodeContextError`).
- Then clangd and typescript-language-server (and once pylsp) "did not exit in the shutdown grace period; the daemon kills it".
- clangd starts for a Python repository.

## First findings from the code (not yet measured)

- `CodeContext.grepCode` (`Sources/FoundationModelsCodeContext/CodeContext.swift:523`) does NOT call `waitForFirstIndexPass()`. It calls `GrepCode.run` directly.
- `Store` uses a GRDB `DatabasePool` (WAL). Reads do not wait for the writer. Thus a lock wait on the store is not a probable cause.
- `GrepCode.run` (`Sources/FoundationModelsCodeContext/Ops/GrepCode.swift:157`) loads ALL chunk rows into memory (`loadChunks`), then adds one child task for each chunk. Each task compiles the Swift `Regex` again (`matchChunk`). On Django there are many chunks. Swift `Regex` compile and match are slow, and the index pass uses the same CPUs at the same time.
- The last three commits (4f201b0, a57743f, d6182ee) changed `innermostMatches(of:)`. Make sure that this step is not quadratic in the number of hits or chunks.
- The second call timed out while the first call ran. Two concurrent calls each make one task for each chunk. This doubles the CPU load.

## Questions to answer

1. Does grepCode wait for the symbol index or for the LSP pass of the whole tree? (The code says no. Confirm with a trace on a Django clone.) If it waits anywhere, it must answer from what is indexed now, or use a text grep with the enclosing symbol from tree-sitter. It must tell that the index is partial. It must not hold the call for minutes.
2. Is there contention between grepCode and the background index work (tree-sitter pass, LSP references pass; pylsp is single-threaded)? Measure grepCode on a Django clone with the index pass done, and while it runs.
3. Must clangd and typescript-language-server start for a tree that is mostly Python? Must the close path cancel the indexer before it closes the store, so that the hash/index errors do not occur? (If this part is large, make a separate card.)

## Answers

Measured with the benchmark `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift`: a synthetic tree of 2000 Python files, 88000 chunks, about 40 MB of chunk text (the class chunk holds the text of its method chunks), debug build, 32-core machine. The pattern is the pattern of the bench run (`def add_immediate_loading|def add_deferred_loading|def clear_deferred_loading`).

**The cause.** CPU cost of the old matcher. One call used about 46 s of CPU time on 88000 chunks:
- `Regex(pattern)` compiled again in each of the 88000 child tasks: about 15 s of CPU.
- Swift `Regex` matching over the chunk texts: about 6 s of CPU (one compiled `NSRegularExpression` does the same work in 0.2 s).
- The rest: the cost of 88000 child tasks, which also use all the threads of the Swift concurrency pool.
On a 32-core machine this gave 2.6 s to 2.8 s of wall time. On a machine with fewer free cores (the agent, the language model, pylsp, clangd and tsserver use the same CPUs), with a larger tree (Django has more files than the probe), and with two calls at the same time, the same CPU cost gives 95 s to more than 120 s.
- `innermostMatches(of:)` is NOT the cause: it is linear (one Dictionary keyed by the file position, then one pass over the hits).

**Question 1.** grepCode does not wait for the symbol index, the first index pass or the LSP pass. `CodeContext.grepCode` calls `GrepCode.run` directly, and the GRDB `DatabasePool` read does not wait for the writer. Measured: a tree-sitter pass in progress did not change the time of one old call (2.80 s idle, 2.84 s during the pass). grepCode now tells when the index is partial: `GrepCodeResult.unindexedFiles` (the count of files with `ts_indexed = 0`, read in the same transaction as the chunks) and `GrepCodeResult.isIndexPartial`. The tool description tells the model to read `unindexedFiles`. `CodeContextManager.grepCode` gives only the matches (it already drops `truncated` and `totalChunksSearched`), thus that fan-out API does not carry the new field.

**Question 2.** The tree-sitter pass is sequential (one file at a time, one thread, one write transaction for each file), thus it does not take many CPUs and it does not block the read. The contention was CPU contention: each old grepCode call used all the cores of the concurrency pool, and two concurrent calls doubled that. pylsp, clangd and tsserver are other processes; they take CPU but they do not block the read. Measured with the old code: during a tree-sitter pass plus 30 busy threads, one call used 3.8 s of wall time and 85 s of CPU; two concurrent calls used 6.7 s of wall time each and about 148 s of CPU together.

**The fix.** `GrepCode.run` compiles the pattern one time as an `NSRegularExpression` (ICU syntax; `Gitignore.swift` already uses it), reads the chunk rows with one GRDB cursor in one read transaction, and matches each row in sequence. No task group, no full copy of the rows, no work on the threads of the concurrency pool. Measured after the fix, same benchmark: idle 0.29 s wall and 0.29 s CPU; during a tree-sitter pass 0.43 s wall and 0.68 s CPU (the CPU time includes the pass). Before the fix: 2.65 s to 2.80 s wall and 45.5 s to 45.8 s CPU.

**Question 3.** Separate card ^qrz0hg1. Short answer: clangd starts because the C/C++ modules use the `Makefile` marker (Django has `docs/Makefile`), and typescript-language-server starts because of the `package.json` marker at the Django root. Detection uses marker files only. The close path already cancels the indexer before it shuts down the servers, and `stop()` does not close the store. The error lines come from the cancellation: the cancelled LSP index task calls the store, GRDB throws `CancellationError`, `Store` wraps it in `CodeContextError.storage`, and the worker logs it as an error.

## Acceptance criteria

- [x] A test or benchmark reproduces the slow grepCode on a large tree (a Django clone or a synthetic tree of the same size) and records the time.
- [x] The cause is found and written in this card (regex compile per chunk, task per chunk, `innermostMatches`, CPU contention with the index pass, or other).
- [x] grepCode on a Django-size tree answers in a few seconds, also while the first index pass runs.
- [x] When the index is partial, the grepCode result tells this (for example from `indexStatus()`).
- [x] Questions 2 and 3 have an answer in this card, or a separate card.
#bug #tools #index