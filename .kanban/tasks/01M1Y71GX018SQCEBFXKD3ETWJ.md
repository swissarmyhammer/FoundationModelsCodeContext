---
comments:
- actor: claude-code
  id: 01m1yep6c2y9p9tm78gqy71akv
  text: |-
    Picked up. Research done.

    Blocker check: the router side is landed. `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter` `origin/main` is at `efe0147`, which contains `012b107 refactor(router): delete LanguageModelProfile.release() and its router coupling`. `rg "public func release\(\)" Sources` in the router returns nothing. Router task `^m8vj0jr` is in `done`.

    This repo still pins an older router: `.build/checkouts/FoundationModelsRouter` sits on `0b5fb79`, where `LanguageModelProfile.release()` still exists. So `Package.resolved` must move forward as part of this task, otherwise the examples keep compiling against the old API and the change proves nothing.

    Call sites confirmed, two only:
    - `Examples/CodeContextExample/main.swift` — `await profile.release()` after `await context.stop()`.
    - `Examples/ManagerExample/main.swift` — `await profile.release()` after `await manager.shutdown()`.
    (`Sources/.../Index/Watcher.swift` also matches `release()`, but that is `Unmanaged.release()` for the FSEvents box — unrelated, leave it.)

    Handle lifetime check: both examples hold `profile` as a top-level `let` for the whole run, and the `RoutedEmbedder` handle goes into a `RoutedEmbedderAdapter` that lives no longer than the profile. No handle outlives its profile in either file.

    One doc line needs the same edit: `CodeContextExample/main.swift`'s header says the example tears down "both the context and the resolved profile", which stops being true once the explicit call goes.
  timestamp: 2026-09-07T17:29:37.410422+00:00
- actor: claude-code
  id: 01m1yf6h8mmzdn692gpft8vs4s
  text: |-
    Implementation landed, TDD red-green with the compiler as the guard.

    RED: `swift package update foundationmodelsrouter` moved the pin from `0b5fb79` to `efe0147`, then `swift build --target CodeContextExample --target ManagerExample` failed with `Examples/ManagerExample/main.swift:123:15: error: value of type 'LanguageModelProfile' has no member 'release'`. That failure proves the two lines were the only thing holding the old API.

    GREEN: deleted both calls; the same build now reports `Build complete!` with no source warning.

    Note on `Package.resolved`: it is listed in `.gitignore` (line 7) and is not tracked, so no manifest change appears in the diff. This repo floats on the router's `main` branch, and the pin moves on the next resolve. The card's "picking up that router revision in Package.resolved" therefore needs no committed edit.

    Beyond the two deletions, each example now states why no teardown call is left, so a reader does not read the deletion as a forgotten cleanup:
    - `CodeContextExample/main.swift` — the header sentence that said the example tears down "both the context and the resolved profile" now says it stops the context, and that the router owns residency through ARC.
    - `ManagerExample/main.swift` — a comment above `await manager.shutdown()` says the same.

    Rules read before editing (`dump validators`, 7 validators, 60 rules, all Swift). The ones that bear on this diff and how the diff meets them:
    - `no-commented-code` and `dead-code` — the calls are deleted, not commented out.
    - `invariant-propagation` — the same treatment lands at every site; `rg` finds no third `profile.release()` call in the repo.
    - `inverse-operation-coverage` and `public-output-contract` — end-of-run behavior changes, so both files record that the router frees the resident models when the last reference goes away.
    - `idioms` gives whitespace to `swift-format`: `swift format lint --strict --recursive Examples` exits 0.
    - `Package.resolved` is under no rule.

    Verification: `swift build --build-tests` — `Build complete!`, no source warning. `swift test` — 561 tests in 47 suites passed. `swift build --package-path IntegrationTests --build-tests` — `Build complete!` (the only warnings are `-Wc++17-extensions` from the `mlx-swift` C++ checkout, which this repo does not own).
  timestamp: 2026-09-07T17:38:32.852979+00:00
- actor: claude-code
  id: 01m1yf6n38aez3pcebaxf1m92j
  text: |-
    ### implement — changed
    - evidence: 2 files — Examples/CodeContextExample/main.swift, Examples/ManagerExample/main.swift. Both `await profile.release()` calls deleted; stale teardown prose corrected in each. `swift build --build-tests` complete with no source warning; `swift test` 561 tests in 47 suites passed; `swift format lint --strict --recursive Examples` exit 0.
    - next: review
  timestamp: 2026-09-07T17:38:36.776971+00:00
position_column: doing
position_ordinal: '80'
title: Drop the profile.release() calls in the two examples once router residency is ARC-owned
---
## What

FoundationModelsRouter is making pooled residency ARC-owned. A resident model is freed when the last reference to it goes away, and `Router.resolve` drains the pending evictions before it measures the host budget. `LanguageModelProfile.release()` is then deleted (router tasks `^fa7b61c`, `^5ph8cdm`, `^m8vj0jr`).

This repo calls it in two examples, and both calls are the last statement of a shutdown block:

- `Examples/ManagerExample/main.swift:123` — `await profile.release()`, right after `await manager.shutdown()` at `:122`.
- `Examples/CodeContextExample/main.swift:99` — the same shape.

Delete both lines. Keep the `manager.shutdown()` calls: those end this repo's own work, and nothing about the router change replaces them.

Check, while there, that neither example keeps a `RoutedLLM` or `RoutedEmbedder` in a longer-lived object than the profile. That was a latent trap before the router change (a handle holds its profile weakly) and is safe after it, but an example is documentation, so it should show the shape a reader should copy: resolve, use, drop.

- [ ] Delete `await profile.release()` in `Examples/ManagerExample/main.swift`.
- [ ] Delete `await profile.release()` in `Examples/CodeContextExample/main.swift`.
- [ ] Confirm each example's shutdown block reads correctly with no cleanup call.

## Blocked on

Router `^m8vj0jr` (the deletion of `release()`), and this repo picking up that router revision in `Package.resolved`. Until then the calls still compile.

## Acceptance Criteria

- [ ] `grep -rn 'profile.release()' --include='*.swift' .` returns nothing.
- [ ] Both examples still call `manager.shutdown()`.
- [ ] `swift build` reports no new warnings.

## Tests

- [ ] Run `swift test`. Every suite passes.
- [ ] Run `swift build` for the example targets, so both edited files are proven to compile.
- [ ] Confirm the run reported the tests as executed. A `--filter` that matches a display name instead of a type name matches nothing and still exits `0`.

## Workflow

- Use `/tdd` — the suites are the guard; the edit itself is two deleted lines. #router #tech-debt