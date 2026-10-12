---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4r7berfx51517azy8kzvd6n
  text: |-
    ## Measured cause (work step 1)

    Setup: a shallow clone of django/django in the session scratchpad (7080 files, 10296 non-ignored entries in the walk). A temporary probe test in IntegrationTests (debug build, not kept) opened a real CodeContext on the clone (FakeEmbedder, no watcher, auto-install off), called start(), and then each 0.5 s during the first index pass measured:
    - actorWait: the round trip of one empty call into the CodeContext actor.
    - mainWait: the round trip of `MainActor.run {}`.
    - walkOffActor: `ProjectDetection.detectProjects(rootDirectory:)` in a detached task (no actor).
    - detectProjects: the full `context.detectProjects()`.

    Results (40 samples during the first pass, which took 528 s):
    - actorWait: 0 ms in each sample.
    - mainWait: 0 ms in each sample.
    - walkOffActor: 5.4 s to 9.6 s.
    - detectProjects: 5.5 s to 10.0 s. This is the same as the walk.
    - With no index pass (idle): Walker.walkEntries 4.8 s to 6.8 s, full detection 5.3 s to 5.8 s.
    - start() itself took 17.7 s (it also walks the tree, in the reconcile and in LspSupervisor.start).

    Break-down of the walk (idle, same tree):
    - directory listing and resource values: 0.34 s to 0.44 s.
    - gitignore checks (`GitignoreStack.isIgnored`): 4.1 s to 4.3 s for 10300 checks, thus about 0.4 ms for each entry. For each entry and for each of the 15 root patterns, `RelativePath.of` makes two `standardizedFileURL` values and two path-component arrays.
    - a POSIX readdir scan of the same tree: 0.1 s.

    Conclusion:
    - The hypothesis of the card ("detectProjects waits for the index pass on the actor") is not what this measurement shows. The call did not wait for the actor or for the main actor in any sample.
    - The cost is the full gitignore-aware tree walk itself (5 s to 10 s on Django in debug). The index pass only adds CPU load (idle 5 s, during the pass up to 10 s). On the SWE-bench host (pylsp, embedder, agent model on the same CPUs) this gives the 13 s to 33 s that the run saw.
    - The walk runs synchronously on the CodeContext actor. Thus while it runs, it also holds the actor, and each other operation and each actor hop of the index loop waits for it. Also, a call that starts while the cooperative pool is full (for example the hash TaskGroup of the reconcile, one child task for each file) must wait for a free pool thread.
    - The state publish goes to the main actor and awaits it. In this probe the main actor was free, but in a host app it can be busy.
  timestamp: 2026-10-12T14:13:04.399168+00:00
- actor: claude-code
  id: 01m4r7cqd8kbmps2759g03q7y0
  text: |-
    ## Research summary and design decision (work step 2)

    ### Research
    - Cloud Native Buildpacks (spec, Apache-2.0): each buildpack has `bin/detect`. Exit 0 = pass, 100 = fail, other = error. An order is a list of groups. The lifecycle tries the groups in sequence and selects the first group in which each non-optional buildpack passes. An optional buildpack can fail and then leaves the group. Lesson: one independent detect rule for each kind, and an explicit order.
    - Nixpacks (Railway): `trait Provider { fn name(); fn detect(&self, app: &App, env: &Environment) -> Result<bool>; ... }`. One provider for each language, and the detect step looks only at marker files of the app root (`app.includes_file("package.json")`, `app.has_match("*.csproj")`). The provider list has a fixed order. Lesson: a strategy is a small value with a name and one boolean predicate over the file tree.
    - Heroku `bin/detect` (Python buildpack, MIT): one shell script that checks a list of marker files (`requirements.txt`, `setup.py`, `pyproject.toml`, `Pipfile`, `poetry.lock`, `uv.lock`, `manage.py`, ...) in the build root, prints the name and exits 0, or exits 1. Lesson: rules are marker-file presence only; no content parse for most kinds.
    - GitHub Linguist (MIT) / go-enry (Apache-2.0): a chain of strategies (Modeline, Filename, Shebang, Extension, XML, Manpage, Heuristics, Classifier). Each strategy gets the candidates of the previous one and narrows them. The data (`languages.yml`: `filenames`, `extensions`) is apart from the strategy code. Lesson: keep the rule data in one table (here: `LanguageModule.projectMarkers` and `fileExtensions`) and keep the strategy code small. An ambiguous file name (here: a shared marker such as `Makefile` or `package.json`) needs a second rule (Linguist heuristics; here: a source file of the language below the marker).
    - mise / asdf (`.tool-versions`) and the VS Code / JetBrains project models: a project can be at any depth (monorepo). VS Code activates on `workspaceContains:**/package.json`. JetBrains framework detectors match a file pattern and then an optional content condition. Ignored and vendor folders do not count. Lesson: look for markers in each non-ignored directory, not only at the root.
    - No code was copied. Only the ideas above are used.

    ### Can the LanguageModule markers become the strategies?
    Yes. Each `LanguageModule` already holds the rule data: `projectMarkers` (file names and globs) and `fileExtensions` (the source evidence for a shared marker). Thus one strategy for each module is made from the module. No new marker table is necessary, and the behavior of the current detection stays the same.

    ### Design
    1. `ProjectDetectionStrategy` (protocol, Sendable): `language` and `detects(_ directory: ProjectDirectory) -> Bool`. One strategy for each project kind.
    2. `MarkerFileStrategy`: the strategy that is made from one `LanguageModule`. It passes when a marker of the module is in the directory. A marker that more than one module declares passes only when a source file of the module is below the directory (the current rule).
    3. `ProjectDirectory`: the data that a strategy reads: the directory URL, the names of its direct children, and the file extensions in its subtree.
    4. `ProjectDetector`: holds the ordered strategies (default: one for each module of `Languages.all`). It reads the file tree one time (the gitignore-aware `Walker.walkEntries`, which reads only the file system), makes one `ProjectDirectory` for each directory, and runs each strategy on each directory. It never uses the CodeContext actor, the index store, the embedder or the LSP supervisor. `ProjectDetection.detectProjects(rootDirectory:)` (public API, also used by `start()` and `LspSupervisor.start()`) calls the detector, thus each caller gets the same projects.
    5. The detector has an async entry that runs the scan on a GCD queue, not on the Swift cooperative pool and not on an actor (the prevailing pattern of `Watcher.start()`). Thus a full cooperative pool (for example the hash TaskGroup of the reconcile) does not delay it.
    6. `CodeContext.detectProjects()` becomes `nonisolated`. It calls the detector, then starts the update of `state.projects` on the main actor and does not wait for it. Thus no path of the call waits for the CodeContext actor, the main actor, the store, the embedder or the supervisor.
    7. Speed: the measurement shows that 4.1 s of the 5 s walk is `GitignoreStack.isIgnored`, which makes two standardized URLs for each pattern and each entry. Each pattern keeps the path components of its base directory, and `isIgnored` standardizes the entry URL one time only. The gitignore semantics do not change, and the one gitignore implementation stays in one place. The reconcile walk of `start()` also gets faster.

    Not in scope (YAGNI): content rules (for example `Cargo.toml` with `[workspace]`) and lockfile rules. The protocol permits such a strategy later, but no current consumer needs it.

    ### Tests
    - Test 1 (unit): start a context whose first index pass is held on a gated embedder, hold the CodeContext actor and the main actor on gates, call `detectProjects()`, expect the answer, and only then open the gates.
    - Test 2 (integration benchmark): a Django-size synthetic tree with the Django `.gitignore`, `detectProjects()` during the first index pass, budget 6 s. Also a recorded measurement on the real Django clone.
  timestamp: 2026-10-12T14:13:46.024215+00:00
- actor: claude-code
  id: 01m4r98zzsh3qp5jk413pj350g
  text: |-
    ## Implementation and measurements (work steps 3 to 5)

    Implementation landed (not committed):
    - New `Projects/ProjectDetectionStrategy.swift`: `ProjectDirectory`, protocol `ProjectDetectionStrategy`, and `MarkerFileStrategy` (one for each `LanguageModule`; the shared-marker rule is the same as before).
    - New `Projects/ProjectDetector.swift`: holds the ordered strategies (`languageModules` = one for each module of `Languages.all`), reads the tree one time with `Walker.walkEntries`, groups by relative path strings (no URL for each entry), and has `detectProjectsOffCooperativePool(rootDirectory:)`, which runs the walk on a concurrent GCD queue.
    - `ProjectDetection.detectProjects(rootDirectory:)` (public, also used by `start()` and `LspSupervisor.start()`) now calls the detector. The old private helpers moved into the detector.
    - `CodeContext.detectProjects()` is now `nonisolated`. It calls the detector off the cooperative pool and then `CodeContextState.beginPublishingProjects(_:)`, which puts the update of `state.projects` on the main actor and does not wait for it.
    - Speed (the measured cause): `GitignorePattern` keeps the path components of its base directory; `GitignoreStack.isIgnored(pathComponents:isDirectory:)` takes the components of the entry; `Walker` builds the components of each child from its directory and makes no standardized URL for each entry. `RelativePath.of(components:relativeTo:)` and `RelativePath.components(of:)` are the shared helpers.
    - plan.md "Project detection" has two new bullets (Component, Isolation).

    Test 1 (unit, `DetectProjectsIsolationTests`): the first index pass is held on the gate of a `GatedEmbedder`, the executor of the `CodeContext` actor and the main actor are each held on a `ThreadGate` (new `Tests/.../Support/ThreadGate.swift`). The test calls `detectProjects()`, waits at most 5 s for the answer, and only then opens the gates.
    - RED (old code): no answer in 5 s (`projectsWhileHeld → nil`).
    - GREEN: the answer came, test passed in 0.034 s.

    Also `ProjectDetectorTests` (unit): one strategy for each module in registry order; a strategy of a caller runs on each directory; the off-pool detection gives the same projects as the synchronous detection.

    Test 2 (integration benchmark, `IntegrationTests/.../DetectProjectsScaleTests.swift`): a synthetic Django-size tree (9500 Python files, the Django `.gitignore`, `pyproject.toml` and `package.json`, `node_modules/` and `docs/_build/` that the walk must skip), a real `CodeContext` with an embedder that waits 2 s for each call, `detectProjects()` during the first index pass, budget 6 s.
    - RED (old gitignore code): 7.14 s.
    - GREEN: 0.73 s to 0.74 s in the full integration suite.
    - The new parent suite `ScaleBenchmarks` (`.serialized`) holds `GrepCodeScaleTests` and `DetectProjectsScaleTests`, so that the two benchmarks do not run at the same time. Reason: in one run the new benchmark ran at the same time as `GrepCodeScaleTests`, and the CPU budget of the grep test (process CPU time) failed with 13.7 s. After the change the grep test measured 0.62 s CPU during the index pass and 0.29 s idle.

    Recorded measurement on the real Django clone (shallow clone of django/django in the session scratchpad, 10296 non-ignored entries; temporary probe test, debug build, not kept), 10 calls during the first index pass:
    - `detectProjects()`: 0.95 s to 1.42 s (before: 5.5 s to 10.0 s).
    - `Walker.walkEntries`: 0.82 s to 1.06 s (before: 4.8 s to 6.8 s).
    - The projects are the same as before (`javascript`, `python` at the root).
    - `start()`: 3.9 s (before: 17.7 s), because the reconcile walk uses the same faster gitignore check.

    Notes for the next agent:
    - `IntegrationTests/Package.resolved` (git-ignored) had a stale FoundationModelsExtras pin, thus the integration build failed with "type 'FakeEmbedder' does not conform to protocol 'PooledEmbedding'". `swift package --package-path IntegrationTests update` corrected it. This is local state only.
    - `swift format lint -s -r Sources Tests` reports pre-existing errors in `Tests/FoundationModelsCodeContextTests/CodeEntitiesTests.swift` (a file this task did not change). Each changed or new file of this task lints clean.
    - The remaining cost of the walk is the NSRegularExpression match of each gitignore pattern and the directory listing. A POSIX readdir scan of the same tree takes 0.1 s, thus a further speed-up is possible in the Walker if a host needs it.

    Test runs: `swift build` clean. `swift test`: 838 tests in 78 suites passed. `swift test --package-path IntegrationTests`: 12 tests in 10 suites passed.
  timestamp: 2026-10-12T14:46:40.889803+00:00
- actor: claude-code
  id: 01m4r994w6sepw4vr89pdqrcwc
  text: |-
    ### implement — changed
    - evidence: 15 files. Changed: Sources/FoundationModelsCodeContext/CodeContext.swift, CodeContextState.swift, Index/Gitignore.swift, Index/RelativePath.swift, Index/Walker.swift, Projects/ProjectDetection.swift, plan.md, IntegrationTests/.../GrepCodeScaleTests.swift (now nested in ScaleBenchmarks, re-indent only). New: Projects/ProjectDetectionStrategy.swift, Projects/ProjectDetector.swift, Tests/.../DetectProjectsIsolationTests.swift, Tests/.../ProjectDetectorTests.swift, Tests/.../Support/ThreadGate.swift, IntegrationTests/.../DetectProjectsScaleTests.swift, IntegrationTests/.../ScaleBenchmarks.swift. Django clone during first pass: detectProjects 0.95-1.42 s (was 5.5-10.0 s); synthetic benchmark 0.73 s (was 7.14 s). swift test 838 passed; IntegrationTests 12 passed.
    - next: /review
  timestamp: 2026-10-12T14:46:45.894656+00:00
- actor: claude-code
  id: 01m4r9g2yn2gc6n7xhrv5sex5w
  text: |-
    ### test — green
    - evidence: swift build: complete, no compiler warning. swift test: 838 tests in 78 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests: 12 tests in 10 suites passed, 0 failed, 0 skipped.
    - note: SwiftPM prints one line, "missing creator for mutated node ... mlx-swift_Cmlx.bundle". It comes from the Cmlx dependency bundle in the build system. This change did not cause it. No source file in this package can remove it.
    - next: review
  timestamp: 2026-10-12T14:50:33.301673+00:00
- actor: claude-code
  id: 01m4r9r2ymj88rbpc58kjff7xb
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (1d13754). 3 findings (3 confirmed, 2 refuted). IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift:82, Sources/FoundationModelsCodeContext/CodeContextState.swift:164, Tests/FoundationModelsCodeContextTests/DetectProjectsIsolationTests.swift:58
    - next: Correct the 3 open items in "Review Findings (2026-10-12 09:51)". Then run the review again.
  timestamp: 2026-10-12T14:54:55.444092+00:00
- actor: claude-code
  id: 01m4r9rdhsx1nw3j739rnfmnx1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 15 files (8 changed, 7 new)
    - test: green — swift test 838 passed; IntegrationTests 12 passed
    - commit: 1d13754
    - review: findings — IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift:82, Sources/FoundationModelsCodeContext/CodeContextState.swift:164, Tests/FoundationModelsCodeContextTests/DetectProjectsIsolationTests.swift:58
  timestamp: 2026-10-12T14:55:06.297684+00:00
- actor: claude-code
  id: 01m4raa81p4a75myemx0ztng1t
  text: |-
    ## Review findings fixed (iteration 2)

    1. GrepCodeScaleTests: the search during the index pass now runs in `withAsyncCleanup`. The cleanup cancels `indexPass` and awaits its result on each path. DetectProjectsScaleTests had the same cause (the `passWatch` task was cancelled but never awaited, and `waitForFirstIndexPass()` does not stop on a cancel). The test now has no watch task: it reads `context.indexStatus()` after the call, and the pass is running while `filesEmbedded < filesWalked`. The `FirstPassProgress` actor is deleted.
    2. CodeContextState: a `Mutex<Task<Void, Never>?>` (`latestProjectsPublish`) keeps the newest publish task. `beginPublishingProjects(_:)` cancels the previous task under the lock and starts a new one; the main-actor job does not change `projects` when it is cancelled. The method returns the task (`@discardableResult`), so a caller can await or cancel it. `publishProjects(_:)` (awaited, used by `start()`) now awaits `beginPublishingProjects(_:).value`, thus both paths follow the same order rule.
       - What did not work: a first RED test used two publishes at different task priorities while the main actor was held. It passed on the old code: the main-actor queue ran the jobs in FIFO order, not by priority. The kept test puts a probe job between the two publishes on the held main actor; on the old code the probe saw the older list (RED confirmed by a run with the cancel guard removed).
    3. DetectProjectsIsolationTests: `start()` and the held section run in `withAsyncCleanup` (cleanup: open the embed gate, stop the context). The new helper `detectProjectsWhileTheActorsAreHeld(context:)` opens `actorGate` and `mainActorGate` and awaits `actorHold`, `mainActorHold` and `detection` in a cleanup that runs on each path, also when `waitForAnswer` throws. The detection task waits until both executors are held before it calls `detectProjects()`.
    - New shared helper `withAsyncCleanup` in Tests/FoundationModelsCodeContextTests/TestSupport.swift (the same shape as the one in IntegrationTests/.../IntegrationSupport.swift; the unit target cannot import that package).
    - New unit test `CodeContextStateTests.anOlderProjectListDoesNotLandAfterANewerPublishStarts`.
  timestamp: 2026-10-12T15:04:50.486148+00:00
- actor: claude-code
  id: 01m4raab83thtx5cq7wfye33ah
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsCodeContext/CodeContextState.swift, Tests/FoundationModelsCodeContextTests/CodeContextStateTests.swift, Tests/FoundationModelsCodeContextTests/DetectProjectsIsolationTests.swift, Tests/FoundationModelsCodeContextTests/TestSupport.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift, IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/DetectProjectsScaleTests.swift. swift build clean; swift format lint clean on the 6 files; swift test 839 passed in 78 suites; swift test --package-path IntegrationTests --filter ScaleBenchmarks 3 passed. 3 of 3 review findings checked.
    - next: /review
  timestamp: 2026-10-12T15:04:53.763866+00:00
- actor: claude-code
  id: 01m4rag34sz9b1ctb9pmk4wpwr
  text: |-
    ### test - green
    - evidence: swift build - complete, no warning from this change. swift test - 839 tests in 78 suites passed, 0 failed, 0 skipped. swift test --package-path IntegrationTests - 12 tests in 10 suites passed, 0 failed, 0 skipped.
    - note: The only warning is "missing creator ... mlx-swift_Cmlx.bundle". It comes from a dependency.
    - next: review
  timestamp: 2026-10-12T15:08:02.073287+00:00
- actor: claude-code
  id: 01m4ramtv1k9swweh7ww5dcwmf
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (c8f69dc). 0 findings, 0 confirmed, 0 refuted. 7 validator runs, 0 failed. 6 files reviewed. All 3 items in the prior section "Review Findings (2026-10-12 09:51)" are checked.
    - next: The task is in done. Send the commit sha c8f69dc to the FoundationModelsACPAgent session.
  timestamp: 2026-10-12T15:10:37.409628+00:00
- actor: claude-code
  id: 01m4ran2jf8ceryhhrp79krd20
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 6 files
    - test: green — swift test 839 passed; IntegrationTests 12 passed
    - commit: c8f69dc
    - review: clean — 0 findings; 3 of 3 prior findings checked
  timestamp: 2026-10-12T15:10:45.327321+00:00
position_column: done
position_ordinal: dd80
title: detectProjects must never wait for index work
---
## Problem

In SWE-bench run no-otel-1011 (2026-10-11, Django clones, CodeContext before 3e84f52), each runCode call of `tools.code_context.detectProjects` did not complete in the 6 s settle period of runCode. The result came 7.4 s to 26.7 s after the settle period (9.4 s in django__django-13964). In older runs, it came 3.2 s to 7.2 s after the settle period. In django__django-13964, a pending detectProjects call started a loop of 73 calls that did nothing.

FoundationModelsACPAgent only starts the code context and mounts its tools. It does not add a wait.

## Requirement

The user said: "we need detection to not be blocked by any indexing".

`detectProjects` must never wait for index work. This includes:

- the first index pass,
- a later index pass,
- a re-index after a file change,
- an embedding pass,
- a language-server start.

## Design direction

The user said: "code context should be able to detect projects even if we need to add in a strategy pattern rule based detector. i'm sure there are packages in other languages we can look to for inspiration".

Thus project detection can be a separate component, apart from the index:

- A set of detector strategies. There is one strategy for each project kind.
- Each strategy is a rule over marker files. Examples: `Package.swift`; `Cargo.toml` with `[workspace]`; `pyproject.toml` or `setup.py`; `package.json` with a lockfile; `go.mod`; `CMakeLists.txt`; `Makefile`.
- The detector reads only the file tree and the marker files. It never uses the index or the `CodeContext` actor.

Start from the current detection code ("Project detection from LanguageModule markers", task 01KWJ3RH1RE9WJY5353AHD6JSK). Find out if the `LanguageModule` markers can become the strategies.

Research these packages for the rule design. Do not copy code unless its license is compatible.

- Cloud Native Buildpacks: each buildpack has a `detect` step that passes or fails on marker files. Look at detection groups and their order.
- Nixpacks (Railway): one "provider" for each language, with `detect()` over marker files, and an order of providers.
- Heroku buildpacks: `bin/detect`.
- GitHub Linguist and go-enry: language detection by file name, extension and heuristics. These are for files more than for projects, but the rule format is good.
- Mise and asdf `.tool-versions`, and the project-model detection of VS Code and JetBrains: rules for monorepos and nested projects.

The CodeContext session decides the final design. Record the design and the research results in this task before the implementation.

## Possible cause (not measured)

`detectProjects()` walks the full tree on the `CodeContext` actor and then goes to the main actor. The first index pass runs on the same actor. Thus the call waits for the index pass.

## Work

1. Measure the cause first. Record the time that `detectProjects` waits for the actor, the time of the tree walk, and the time on the main actor, on a Django clone during the first index pass.
2. Do the research in "Design direction". Decide the design and record it in this task.
3. Fix the cause. Possible fixes:
   - A rule-based detector component that is apart from the index (see "Design direction").
   - Answer from the projects that `start()` found before.
   - Walk the tree off the actor.
4. Make sure that no path of `detectProjects` waits for the `CodeContext` actor, the index store, the embedder, or the language-server supervisor while index work runs.

## Acceptance criteria

- [x] `detectProjects` does not wait for index work of any type in the list above.
- [x] Test 1: a test runs `detectProjects` while an index pass holds the actor (or the index store) busy. The test expects the answer without a wait for that pass. For example, the test blocks the index pass on a gate, calls `detectProjects`, gets the answer, and only then opens the gate.
- [x] Test 2 (second check): on a Django clone, during the first index pass, `detectProjects` answers in less than 6 s. A benchmark or a recorded measurement shows this result.
- [x] Record the measured cause in this task.
- [x] Record the design decision and the research results in this task.

## Requester

The FoundationModelsACPAgent session. When the task is done, send the commit sha to that session.

#bug #performance

## Review Findings (2026-10-12 09:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 14 file(s) reviewed, 5 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `plan.md` — no validator matches this file

- [x] `IntegrationTests/Tests/FoundationModelsCodeContextIntegrationTests/GrepCodeScaleTests.swift:82` `swift/concurrency` — The `indexPass` task is cancelled and awaited only after `measureSearch` returns. If `measureSearch` throws, the index pass keeps running on its own after the test ends. Cancel and await `indexPass` in a `defer` block, or in the cleanup of `withAsyncCleanup`, so the task ends on every path.
- [x] `Sources/FoundationModelsCodeContext/CodeContextState.swift:164` `swift/concurrency` — The new method starts an unstructured Task that nothing keeps. The task cannot be cancelled or awaited. If two detections finish close together, their publishes can land in any order, so an older project list can replace a newer one. The doc comment justifies the fire-and-forget shape, but the task still has no owner. Store the latest publish task in a private property of CodeContextState. Cancel or replace the previous handle before you start a new one, so that only the newest detection publishes. Keep the call non-blocking. If the fire-and-forget shape is kept on purpose, state in the doc comment why no ordering guarantee is needed.
- [x] `Tests/FoundationModelsCodeContextTests/DetectProjectsIsolationTests.swift:58` `swift/concurrency` — If `waitForAnswer` throws, the test exits before it opens the gates or awaits `actorHold`, `mainActorHold` and `detection`. The held actor executor and the held main actor stay blocked, and the unawaited tasks leak. Wrap the held section in `defer` or in `withAsyncCleanup`. Open `actorGate` and `mainActorGate`, and await `actorHold`, `mainActorHold` and `detection`, on every path, including a throw from `waitForAnswer`.
