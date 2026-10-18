---
assignees:
- claude-code
position_column: todo
position_ordinal: '9180'
title: 'swift build: warning "missing creator for mutated node" for the mlx-swift_Cmlx bundle'
---
## Problem
Each `swift test` build writes this warning:

`warning: missing creator for mutated node: ('.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')`

The warning comes from the SwiftPM build graph of the `mlx-swift` dependency (the `Cmlx` resource bundle). No source file of this package causes it. The test step requires zero warnings, thus this warning blocks a clean `green` result.

Found during ^94wns6b.

## Change
- Find the cause: the dependency version, the SwiftPM build system, or the bundle layout of `Cmlx`.
- Remove the warning, or record why it cannot be removed in this package.

## Acceptance criteria
- [ ] `swift test` builds with no `missing creator for mutated node` warning, or the task records why this package cannot remove it. #build-warning