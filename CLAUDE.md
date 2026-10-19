# FoundationModelsCodeContext

## Allowed build warning

The zero-warning rule of `/test` has one exception in this repo. Every `swift build`, `swift test`
and `swift test --package-path IntegrationTests` prints this warning, and it does not make a run red:

```
warning: missing creator for mutated node: ('<repo>/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')
```

The cause is upstream. Swift Build plans a CodeSign task for the mlx-swift_Cmlx resource bundle and marks
its `Contents/MacOS` directory as mutated, but no task creates it. This repo cannot remove it (^3a92r6p,
^kw00hcn). Do not chase it. Remove this exception when a toolchain or mlx-swift release no longer prints it.

Only this exact warning is allowed. Any other warning, including another "missing creator" warning, is red.
