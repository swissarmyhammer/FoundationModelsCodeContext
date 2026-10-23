---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5nhjbvftze5nk0h97wwrr6n
  text: |-
    ### test — green
    - red first: `get definition` { path, line } returned the corrective "missing … character" string, not an object.
    - fix: `PositionInference` + `CodeContext.resolvePosition`; the seven position operations take `character: Int?` and `symbol` (aliases name/identifier; rename: identifier/oldName); the result adds `position` { line, character, note } only when inferred.
    - evidence: `swift test` 1102/1102 in 97 suites; IntegrationTests 22/22; only the allowed mlx warning.
    - note: with no language server, the index fallback of definition answers the enclosing symbol at a call site (existing behaviour); the bench's live pylsp layer resolves call sites.
  timestamp: 2026-10-23T23:29:35.087284+00:00
position_column: done
position_ordinal: ff8c80
title: 'Position verbs infer the column: character optional, symbol/name/identifier finds it on the line'
---
From bench24-1023b (django__django-14155, seq 8357): `code_context.getDefinition` failed with 'Tool "getDefinition" is missing its required argument "character".' A model knows the file, the line and the name, rarely the exact column.

Ask (Postel), for get definition / type_definition / hover / references / implementations / inbound_calls / rename_edits:
- `character` optional (`column`/`col` already alias it).
- Accept `symbol` (aliases `identifier`, and `name` where it does not clash): find that whole identifier on the line (first match), else within a few lines around; use its position.
- With neither, use the first identifier on the line that is not a keyword (`def`, `class`, `return`, ...).
- A column out of range for 0-based but in range for 1-based is taken as 1-based.
- When the position was inferred, the result says so in `position` { line, character, note }.

Test first: a Python fixture; `get definition` { path, line } with no character, and with symbol "helper", both find helper's definition. #bug