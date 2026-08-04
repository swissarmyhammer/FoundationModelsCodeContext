---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Extend the swift-format pass and the CI format gate to Examples and Package.swift
---
## What

`^9g8x9s9` checked in a `.swift-format` at the repo root and added a CI gate, but
both the documented developer command and the CI step are scoped to
`Sources Tests`:

```
swift format -i -r Sources Tests
swift format lint -r --strict Sources Tests
```

That leaves three Swift files in the repo outside the style the repo just
adopted, free to drift exactly the way `^9g8x9s9` exists to prevent:

- `Examples/CodeContextExample/main.swift`
- `Examples/ManagerExample/main.swift`
- `Package.swift`

`Examples/*` are real build targets — `.github/workflows/ci.yml` already passes
`example-targets: CodeContextExample ManagerExample` to the reusable workflow, so
CI compiles them but never checks their formatting.

`^9g8x9s9` deliberately did not widen the scope, because its acceptance criteria
name `Sources Tests` verbatim four times and widening it would have mixed an
unrelated diff into a commit that has to stay skippable in `git blame`. This card
is that widening, on its own.

## Notes for whoever picks this up

`Package.swift` carries a `// swift-tools-version:` comment on its first line.
`^9g8x9s9` found that swift-format destructively mangles a file whose first line
is a `#!` shebang — it pulls the following `//` comment lines up onto it, eating
a little more of the header on every run, and `// swift-format-ignore-file` does
not stop it. Check whether the tools-version comment suffers the same fate before
formatting `Package.swift`; if it does, the fix already used in this repo is a
`.swift-format-ignore` file naming the single file to skip (see
`Tests/FoundationModelsCodeContextTests/Support/.swift-format-ignore`).

## Acceptance Criteria

- [ ] `Examples` (and `Package.swift`, if it survives the pass — see Notes) are formatted against the repo's checked-in `.swift-format`, in a commit that touches formatting only and no behavior.
- [ ] The `format` job in `.github/workflows/ci.yml` lints the widened scope, still with `--strict` (plain `swift format lint` exits 0 even when it reports findings).
- [ ] A second `swift format -i -r <scope>` pass produces no further diff — the widened scope is idempotent.

## Tests

- [ ] `swift format lint -r --strict <widened scope>` exits clean.
- [ ] `swift build` reports zero new warnings.
- [ ] `swift build --target CodeContextExample --target ManagerExample` still builds.
- [ ] `swift test` shows the same results before and after. #chore