---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: 'Watcher: a file removed before the debounced flush is not a warning'
---
## What
`Watcher.applyChange(relativePath:kind:)` (`Sources/FoundationModelsCodeContext/Index/Watcher.swift`) logs the warning `the watcher cannot read a changed file and skips it in this flush` when `Walker.hashFile` fails for a `.created`/`.modified` event. An agent that writes a scratch file and deletes it within the debounce window produces this warning, the same noise source that ^b91evm0 removed from the tree-sitter and LSP index workers.

## Approach
- Split the failure of `Walker.hashFile` the same way as `SourceText.read(at:)` (`Index/SourceText.swift`): no file at the path (`CocoaError.fileReadNoSuchFile`) -> debug level, and delete the row (`store.deleteFile(filePath:)`) as for a `.removed` event; other read errors keep the warning and add the error type name (`Log.errorType(of:)`).
- Reuse the classification of `SourceText` instead of a second copy.

## TDD
1. Failing test: a `.created` change for a path with no file -> no warning record for the path, and its `indexed_files` row is gone.
2. Test: an unreadable file (chmod 000) -> the warning stays, with the error type. #index #bug