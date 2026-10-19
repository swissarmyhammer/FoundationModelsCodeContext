---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5ad0m2b9whhj65pjbekk1br
  text: |-
    Research. The premise of this card is false. ^kw00hcn never removed the warning. Its implement step was `no-change`: it wrote down the cause and checked its acceptance box under "or record why this package cannot remove it" (commit e11b4ac, kanban files only). So the warning did not come back. It was never gone.

    Checked each cause the card names:
    - git log: `git log e11b4ac..HEAD -- Package.swift Package.resolved IntegrationTests/Package.swift IntegrationTests/Package.resolved` gives nothing. No manifest or pin changed after ^kw00hcn.
    - mlx-swift pin: Package.resolved pins 0.32.3 (19601207). `git ls-remote --tags ml-explore/mlx-swift` still lists 0.32.3 as the newest tag, so there is no newer release to move to.
    - Toolchain: Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1 (27A9275). ^kw00hcn recorded the same toolchain.
    - Stale .build: a new scratch path (`swift build --target Cmlx --scratch-path <scratchpad>/nosign`) prints the same warning on a clean build. ^kw00hcn also saw it on a clean scratch build.

    The mechanism, from the llbuild manifest (`.build/out/Intermediates.noindex/XCBuildData/<id>.xcbuilddata/manifest.json`):
    - `nodes` marks both `mlx-swift_Cmlx.bundle` and `mlx-swift_Cmlx.bundle/Contents/MacOS` as `is-mutated`.
    - Only the stale-file-removal task's `expectedOutputs` names `Contents/MacOS`. No command lists it as an output. The `MkDir` tasks create only the bundle, `Contents` and `Contents/Resources`.
    - The PACKAGE-RESOURCE target plans a `CodeSign` task for the bundle, with output `mlx-swift_Cmlx.bundle/_CodeSignature`. That is the layout of a shallow bundle, while the bundle on disk is deep (`Contents/_CodeSignature`). The other mutated `Contents/MacOS` path in the graph is `FoundationModelsCodeContextTests.xctest/Contents/MacOS/FoundationModelsCodeContextTests`, which is a real executable. It looks like Swift Build marks the executable path of every signed bundle as mutated. A resource bundle has no executable, so the path is just the empty `Contents/MacOS` folder, and nothing creates it. llbuild warns about any mutated node that has no creator.

    Workarounds tried (none worked):
    - `-Xxcbuild CODE_SIGNING_ALLOWED=NO` on a scratch build: the warning stays, and the manifest still plans `CodeSign`. The swiftbuild build system ignores the flag. `swift build --help-hidden` has no other build-setting pass-through. A CLI flag would not fix a plain `swift build` / `swift test` anyway.
    - `--build-system native` (from ^kw00hcn): it does not compile the Metal library, and it prints a deprecation warning.
    - Removing mlx from the graph: the library target depends on the `FoundationModelsExtras` product, and that product depends directly on `MLXLMCommon`, `MLXLLM`, `MLXEmbedders`, `MLXFoundationModels` and `MLXHuggingFace` (mlx-swift-lm, then mlx-swift). `IndexBenchmark` needs MLX as well. Cutting MLX out would mean restructuring FoundationModelsExtras, which is outside this repo and this card.

    No failing check was added. A clean-build grep for the warning would stay red for good, because nothing in this repo can turn it green. The repro command is `swift build --build-tests 2>&1 | rg 'missing creator for mutated node'`. It prints 1 line even on a no-op build.
  timestamp: 2026-10-19T15:38:20.619851+00:00
- actor: claude-code
  id: 01m5ad0s0s42c7gv0ewt592f98
  text: |-
    ### implement — stuck
    - evidence: no files changed. `swift build --build-tests` prints 1 `missing creator for mutated node ... mlx-swift_Cmlx.bundle/Contents/MacOS` (no-op build, 1.67 s). A clean scratch build also prints 1. `git log e11b4ac..HEAD` over Package.swift/Package.resolved (root and IntegrationTests) is empty. mlx-swift 0.32.3 is still the newest tag. Toolchain is Swift 6.4 / Xcode 27.1, unchanged. ^kw00hcn never fixed the warning; it only recorded it as upstream. Cause: Swift Build (the default SwiftPM build system) plans CodeSign for the PACKAGE-RESOURCE bundle of the mlx-swift Cmlx Metal target and marks `Contents/MacOS` as mutated, but no task creates that folder. `-Xxcbuild CODE_SIGNING_ALLOWED=NO` has no effect.
    - next: a human decides. Options: (a) file a bug on swiftlang/swift-build: a resource bundle with no executable must not mark `$(EXECUTABLE_FOLDER_PATH)` as mutated; (b) ask mlx-swift to ship a prebuilt `default.metallib` resource instead of `.metal` sources; (c) make the test step's zero-warning rule allow this one upstream warning until a toolchain or mlx-swift release removes it.
  timestamp: 2026-10-19T15:38:25.689624+00:00
- actor: claude-code
  id: 01m5ad1bpg3k5m2h1b661t4mtn
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — 0 files; cause is outside this repo: Swift Build marks mlx-swift_Cmlx.bundle/Contents/MacOS as mutated but no task creates it (CodeSign planned for a resource bundle with no executable). The pin, toolchain and Package files are unchanged since e11b4ac; ^kw00hcn recorded it as upstream and never removed it.
    - needs a human decision: (a) file a bug on swiftlang/swift-build, (b) ask mlx-swift to ship a prebuilt metallib, or (c) allow this one upstream warning in the zero-warning rule.
  timestamp: 2026-10-19T15:38:44.816347+00:00
- actor: claude-code
  id: 01m5agwk397v745n3qetxrtfyg
  text: |-
    ### decision — allow the warning
    - The user chose option (c), allow the warning, on 2026-10-19.
    - New CLAUDE.md at the repo root records this one exact upstream warning as the only exception to the zero-warning rule of /test, with its cause and when to remove the exception.
    - next: commit, then review
  timestamp: 2026-10-19T16:46:02.857449+00:00
position_column: doing
position_ordinal: '80'
title: swift build and swift test warn "missing creator for mutated node" for the mlx-swift_Cmlx bundle again
---
## What
Every `swift build`, `swift test` and `swift test --package-path IntegrationTests` on 2026-10-19 prints:
`warning: missing creator for mutated node: ('<repo>/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')` (and the same under `IntegrationTests/.build`).

Task 01M57PR2SXQJ4353TJRKW00HCN fixed this warning before and is in `done`, so it came back. ^t71wvkm confirmed it is present at HEAD with no working-tree source change (stashed its files, rebuilt, warning still printed).

## Change
Find what reintroduced it (git log since 01M57PR2SX, dependency pin of mlx-swift, toolchain update to Xcode 27.1 / Swift 6.4) and remove it, so test runs have zero warnings.