---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5pke794fe5wbfxnkbg3y79g
  text: |-
    ### test — green
    - evidence: red first: OneBasedToolSurfaceTests 22 issues in 8 tests (every line N-1, locator and line 0 wrong). Green: swift test 1114/1114 in 99 suites; IntegrationTests 22/22; only the allowed mlx warning.
    - design: inputs through ToolCoordinates.zeroBased (ToolSupport.outcome for the 7 position verbs, code_actions range, callgraph locator); outputs through OneBasedEncoder in ToolOutcome.encode, which adds 1 to Int values under line/character/column/startLine/endLine/startColumn/endColumn/startCharacter/endCharacter at any depth. Engine, kit.db, LSP wire stay 0-based. PositionInference notes now give 1-based numbers; the old one-past-the-end 1-based heuristic is removed.
    - next: commit, push, tell acp-agent and foundationmodelsmultitool-cf
  timestamp: 2026-10-24T09:21:30.916172+00:00
position_column: done
position_ordinal: ff8e80
title: 'code_context is 1-based at the tool surface: lines and columns in and out'
---
Peer (acp-agent bench) request, user decided option 1.

code_context is the only group that is 0-based; the model passes getSymbol startLine to files.read (1-based) and traceback lines to getDefinition, so it is one line off.

Scope:
- Outputs 1-based: every line/column a code_context verb returns (startLine/endLine of getSymbol, listSymbol, searchSymbol, grepCode, searchCode, layered context, callgraph, blast radius; every LSP range.start/end line+character in definition, typeDefinition, references, implementations, inboundCalls, workspace symbol, renameEdits, codeActions, diagnostics).
- Inputs 1-based: line and character of every cursor verb, and the file:line:col locator of get callgraph. character missing or 0 = start of line. line 0 forgiven as line 1 with a note.
- Storage (kit.db, tree-sitter) and LSP wire stay 0-based. Convert at the tool boundary, one place for inputs, one for outputs.
- Docs: zero-based -> 1-based in verb and parameter descriptions.

Test: each verb on a fixture with a known symbol on line N sees N, not N-1.

After push: tell foundationmodelsmultitool-cf (MultiTool+ForgivingBindings.swift:28-33 comment).