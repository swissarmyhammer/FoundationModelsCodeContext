---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: swift build and swift test warn "missing creator for mutated node" for the mlx-swift_Cmlx bundle again
---
## What
Every `swift build`, `swift test` and `swift test --package-path IntegrationTests` on 2026-10-19 prints:
`warning: missing creator for mutated node: ('<repo>/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')` (and the same under `IntegrationTests/.build`).

Task 01M57PR2SXQJ4353TJRKW00HCN fixed this warning before and is in `done`, so it came back. ^t71wvkm confirmed it is present at HEAD with no working-tree source change (stashed its files, rebuilt, warning still printed).

## Change
Find what reintroduced it (git log since 01M57PR2SX, dependency pin of mlx-swift, toolchain update to Xcode 27.1 / Swift 6.4) and remove it, so test runs have zero warnings.