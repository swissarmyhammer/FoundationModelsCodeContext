---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m57sf6qctzrfwak3n476z081
  text: |-
    Research: the warning is in the build graph that Swift Build (the default build system of SwiftPM in Swift 6.4) plans for the `Cmlx` resource bundle of mlx-swift 0.32.3 (the newest tag). The bundle is the only resource bundle with compiled sources (10 `.metal` files to `default.metallib`). The manifest marks `Contents/MacOS` as mutated, but no task creates it. A clean build in a new scratch path gives the same warning, thus a stale `.build` is not the cause. `.build` was not deleted. The native build system gives no warning, but it does not compile the Metal files and it is deprecated, thus it is not a fix. No file of this package changed. Details are in the description, in the Cause and Evidence sections.

    Side finding: an orphan `swift-frontend -interpret scripted-lsp-server.swift` process (PPID 1, age 9 h 44 min) with the script of `aNegativeContentLengthFailsThePendingRequestAndStopsTheServer`. Recorded as ^0d568qc.

    The two scratch builds stay in the session scratchpad: the shell blocked `rm -rf` on them. They are outside the project.
  timestamp: 2026-10-18T15:18:18.092432+00:00
- actor: claude-code
  id: 01m57sfa3fd0pjhtdkz3qqy47e
  text: |-
    ### implement — no-change
    - evidence: no project file changed. The cause is recorded in the description, and the acceptance-criteria box is checked for the case "cannot remove". `swift build --build-tests`: 1 `missing creator` warning (no-op build). Clean `--scratch-path` build: the same 1 warning. `--build-system native` build: 0 `missing creator` warnings, no Cmlx bundle, 1 deprecation warning. Cause: Swift Build marks `mlx-swift_Cmlx.bundle/Contents/MacOS` as a mutated node with no creator for the Metal resource bundle of mlx-swift 0.32.3 (newest tag). New task ^0d568qc for an orphan scripted-lsp-server process.
    - next: /review. The test step must accept this one upstream warning until Swift Build or mlx-swift removes it.
  timestamp: 2026-10-18T15:18:21.551527+00:00
- actor: claude-code
  id: 01m57sg7q9jktavqna2qbke47w
  text: |-
    ### commit — changed
    - evidence: e11b4ac chore(kanban): record the cause of the Cmlx bundle build warning ^kw00hcn, 6 files
    - next: none
  timestamp: 2026-10-18T15:18:51.881901+00:00
- actor: claude-code
  id: 01m57sh9mcf8ynfcwz7es3adgy
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit e11b4ac): findings 0, confirmed 0, refuted 0. The 6 changed files are all in `.kanban/`, and `.reviewignore` excludes them. The description records the cause (the Swift Build plan for the `mlx-swift_Cmlx` Metal resource bundle of mlx-swift 0.32.3), the evidence (no-op build, clean scratch build, native build system), and why this package cannot remove the warning. The acceptance criterion is satisfied.
    - next: none. The task moved to done.
  timestamp: 2026-10-18T15:19:26.604590+00:00
- actor: claude-code
  id: 01m57shmm7vtt47m9x3zpmk729
  text: |-
    ### finish iteration 1 — clean
    - implement: no-change — cause recorded on the task (Swift Build and the Cmlx Metal bundle of mlx-swift 0.32.3)
    - test: skipped — no code change since the green run at 7000095 (1015 passed)
    - commit: e11b4ac (kanban records only)
    - review: clean — 0 findings; acceptance criterion met by the recorded cause
  timestamp: 2026-10-18T15:19:37.863813+00:00
position_column: done
position_ordinal: f680
title: 'swift build: warning "missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
## Problem
Each `swift test` build writes this warning:

`warning: missing creator for mutated node: ('.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

The warning comes from the SwiftPM build graph of the `mlx-swift` dependency (the `Cmlx` resource bundle). No source file of this package causes it. The test step requires zero warnings, thus this warning blocks a clean `green` result.

Found during ^94wns6b.

## Change
- Find the cause: the dependency version, the SwiftPM version and build system, or the bundle layout of `Cmlx`.
- Remove the warning, or record why it cannot be removed in this package.

## Cause (found)
- Dependency chain: this package -> `FoundationModelsExtras` (branch `main`) -> `swissarmyhammer/mlx-swift-lm` (branch `stable`, `.upToNextMinor(from: "0.32.3")`) -> `ml-explore/mlx-swift` 0.32.3. 0.32.3 is the newest tag of `mlx-swift` (`git ls-remote --tags`). Thus no newer version can change it.
- Toolchain: Swift 6.4 (Xcode 27.1). The default build system of SwiftPM is now `swiftbuild` (Swift Build).
- The `Cmlx` target of `mlx-swift` holds 10 `.metal` files (`Source/Cmlx/mlx-generated/metal`). Swift Build thus makes a `PACKAGE-RESOURCE` target with a `MetalLink` task that writes `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`. It is the only resource bundle of the graph with compiled sources.
- In the build manifest (`.build/out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/manifest.json`), the `nodes` table marks `mlx-swift_Cmlx.bundle/Contents/MacOS` as `is-mutated`, and the stale-file-removal task lists it as an expected output. No task creates it: the `MkDir` tasks create only the bundle, `Contents` and `Contents/Resources`. llbuild writes the warning for a mutated node with no creator. The other bundles (for example `GRDB_GRDB.bundle`) have no `Contents/MacOS` node, and they give no warning.
- The planned `CodeSign` task of the bundle also writes `mlx-swift_Cmlx.bundle/_CodeSignature` (a shallow-bundle path), but on disk the signature is in `Contents/_CodeSignature`. This is a second sign that Swift Build plans this bundle with the layout of a bundle that has an executable.
- Thus the cause is the plan that Swift Build makes for a resource bundle with Metal sources. It is not a stale `.build` state, and it is not a source file or a setting of this package.

## Evidence
- `swift build --build-tests` on the current `.build`: the warning shows on a no-op build (`Build complete! (2.11 sec)`).
- Clean build in a new scratch path (`swift build --build-tests --scratch-path <scratchpad>/cleanbuild`): the same warning shows. `.build` was not deleted.
- Native build system (`swift build --build-tests --build-system native --scratch-path <scratchpad>/nativebuild`): no warning, but the native build does not compile the `.metal` files and makes no `mlx-swift_Cmlx.bundle`. It also prints a deprecation warning. Thus it is not a fix.

## Why this package cannot remove it
- The node comes from the build plan of a dependency target. A package manifest has no setting that changes the bundle plan of a dependency target, or that stops an llbuild warning.
- A change to `mlx-swift` or `mlx-swift-lm` is out of scope of this package. A change of build system removes the Metal library and adds a deprecation warning.
- The fix belongs in Swift Build (swiftlang/swift-build): it must not mark `Contents/MacOS` as mutated for a resource bundle with no executable, or it must create the directory. Another fix is in `mlx-swift`, if it ships a prebuilt `default.metallib` as a resource.
- The test step must accept this one warning as an upstream warning until a toolchain or `mlx-swift` release removes it.

## Acceptance criteria
- [x] `swift test` builds with no `missing creator for mutated node` warning, or the task records why this package cannot remove it. #build-warning