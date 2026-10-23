---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5nj24j84xvkjabhzxfb6vhz
  text: |-
    ### test — green
    - red first: definition at `helper()` in user() returned `user`; the imported-name, qualified and no-match cases also failed.
    - fix: `DefinitionByName` in the index fallback of definition/typeDefinition. On a call or reference: the definitions with that name from lsp_symbols + ts_chunks, ranked same file → imported module / qualifier (Python `from M import x`, `import M [as q]`, relative imports) → the rest, capped at 10, with `resolvedBy: "name"` and a note; none → empty locations + note, never the enclosing function. On a defining name: that declaration.
    - evidence: `swift test` 1107/1107 in 98 suites; IntegrationTests 22/22; only the allowed mlx warning.
  timestamp: 2026-10-23T23:38:11.912422+00:00
position_column: done
position_ordinal: ff8d80
title: 'Index fallback of definition: resolve the name at a call site, never return the enclosing function'
---
With no live language server answer (bench: lsp_indexed=0 for django/db/models/base.py), the index fallback of `definition` returns the symbol that encloses the cursor. At a call site `helper()` inside `user()` it returns `user`: a wrong answer the model trusts.

Ask:
- When the cursor is on an identifier that is not the defining name, resolve it by name in the index: same file first, then the imported module / qualifier match, then the rest.
- Return every candidate, ranked, and mark the result as a name match (`resolvedBy: "name"`, with a note).
- When nothing matches, return no location and a note; never the enclosing function.
- The defining name (`def helper` at helper) keeps today's answer.

Test first: lib.py with helper and user() calling helper, no language server: definition at `helper()` in user() gives helper, not user. #bug