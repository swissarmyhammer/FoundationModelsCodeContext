---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5n8f7tfm2jzj3qzcnh222es
  text: |-
    ### test — green
    - red first: the 5 new SymbolOpsTests failed on the old code (B.validate, D.clean, E.validate gave no symbols; B._check_validity and Unknown.clean gave no candidates or note).
    - evidence: `swift test` 1089 tests in 95 suites passed; `swift test --package-path IntegrationTests` 22 tests passed; only the allowed mlx-swift_Cmlx warning.
    - next: commit, push, send the sha to the acp-agent bench session.
  timestamp: 2026-10-23T20:50:35.471664+00:00
position_column: done
position_ordinal: ff8980
title: getSymbol resolves "Class.member" through the base classes, and gives near candidates when nothing matches
---
## What
From the acp-agent bench (run bench24-1023b, django__django-13933): `getSymbol("ModelMultipleChoiceField.validate")` gave `{"symbols":[]}`. That class does not define `validate`; it inherits it from `ModelChoiceField`. The model's snippet then failed on `symbols[0].text`. `getSymbol("ModelChoiceField._check_validity")` also gave `[]` with no hint (the real member is `_check_values`).

Forgiving tools (Postel): accept what the model clearly means.

## Change
- `Sources/FoundationModelsCodeContext/Ops/SymbolOps.swift`
  - New tier `SymbolMatchTier.inherited`, tried after `suffix` and before `caseInsensitive`. For a `Class.member` query, find the class (a `.type` candidate whose path is `Class` or ends with `.Class`), read its base classes from the class text, walk the bases in Python MRO order (C3), and return the first base member `<Base>.member`. Mark it with the new `SymbolMatch.inheritedFrom` (the qualified path of the class that defines it).
  - When every tier is empty: `symbols` stays empty (call graph and blast radius root at `symbols.first`, so a loose match must not land there). Instead, `GetSymbolResult.candidates` has the near matches, with tier `.near`, plus a short `note`:
    - the same member name in other classes;
    - members of the class (its own and inherited) with a close name.
- Base-class reading is Python-only for now (`class B(A, mixins.C, metaclass=M):`). Other languages give no bases, and so no inherited tier.

## Test (first, red)
`SymbolOpsTests`:
- Python fixture: `class A` with `validate`, `class B(A)` without. `getSymbol("B.validate")` → `A.validate`, tier `.inherited`, `inheritedFrom == "A"`.
- `getSymbol("A._check_validity")` with `A._check_values` → `symbols` empty, `candidates` holds `A._check_values` with tier `.near`, and `note` is set.

#bug