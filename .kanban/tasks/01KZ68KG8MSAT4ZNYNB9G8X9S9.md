---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Check in a .swift-format describing the style the repo actually uses, then format once
---
## What

The project's stated formatting step is `swift format -i -r Sources Tests`, but the
repo has no `.swift-format` file — not at the root, and not in any parent
directory — so the formatter falls back to its own defaults, which this repo does
not follow.

Measured on the current `main`:

- swift-format defaults to **2-space** indentation; all 121 Swift files under
  `Sources` and `Tests` are **4-space** indented.
- swift-format defaults to a **100**-column limit; the repo has **1313** lines
  over 100 columns, the longest **362**.

So running the stated command rewrites the whole repo: **123 files changed,
27,964 insertions, 26,670 deletions**. Any task that runs it as written produces
a repo-wide diff that buries the actual change under review, and any task that
skips it leaves new files unformatted. Both outcomes are wrong, and the choice
gets re-litigated on every card — it was hit and worked around by hand on
`^tbr1qkt`, which had to revert 121 files and format its own two with an
out-of-repo configuration.

## Acceptance Criteria

- [ ] A `.swift-format` is checked in at the repo root describing the style the code is actually written in — 4-space indentation and a line length that does not rewrap the existing long lines (nothing in the repo wraps at 100).
- [ ] `swift format lint -r Sources Tests` passes against that configuration with zero findings, in one commit that touches formatting only and no behavior.
- [ ] The formatting pass is its own commit, separate from any feature work, so it can be skipped in `git blame`.
- [ ] CI runs `swift format lint -r Sources Tests` so the repo cannot drift out of its own style again — `.github/workflows/ci.yml` has no formatting step today.

## Tests

- [ ] `swift format lint -r Sources Tests` exits clean.
- [ ] `swift build` reports zero warnings after the pass.
- [ ] `swift test` shows the same results before and after — formatting must change no behavior.
#chore