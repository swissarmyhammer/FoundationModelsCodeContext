---
assignees:
- claude-code
position_column: done
position_ordinal: ff9280
title: 'getSymbol near candidates: score by word tokens too, so a different word order is near'
---
## What
Near candidates are scored only by edit distance now (`closeNameDistance`), so a name with the same words in a different order is dropped. Also score a name by its word tokens (split on `_`, non-alphanumerics and camelCase boundaries, lowercased). The token distance is the number of words in one name but not the other. A name is near by its tokens when it shares at least two words with the query, and at least half of the query's words. The distance of a near name is the smaller of the two distances.

## Evidence
SWE-bench run nokanban24b (2026-11-07), django__django-13710: for the query `InlineAdminMixin`, the only near name was `InlineAdminForm`. `InlineModelAdmin` (django/contrib/admin/options.py) has the words Inline and Admin too, but it was not a candidate. The model repeated the query 4 times, then searched with grep.

## Code
Sources/FoundationModelsCodeContext/Ops/SymbolOps.swift: `closeNameDistance(_:_:)` and `nearCandidates(candidates:query:hierarchy:)`.

## Acceptance
- [ ] `InlineAdminMixin` gives `InlineModelAdmin` as a near candidate
- [ ] A name that shares only one word is not near by its tokens
- [ ] Tests in SymbolOpsTests, failing first #bug