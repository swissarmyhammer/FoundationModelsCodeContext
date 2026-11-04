# Architecture

## No backward compatibility

This package has not shipped, and none of the swissarmyhammer packages has. We do not keep backward compatibility, and we do not write code for it.

- When a file format or an on-disk layout changes, write and read only the new one. Do not keep a reader for the old format, and do not write migration code. Data on disk in the old format may simply stop working.
- When an API changes, change every caller in the same change, or in the packages that depend on it. Do not keep deprecated aliases, shims, or old overloads.
- Do not keep a schema version only so that an old file can still be read.

This rule holds until we ship. When we ship, this section will say what we promise from then on.

## Line numbers start at 1 at the tool boundary

Each line number and each column that the model sees or gives starts at 1. This is the same rule as the file tools of FoundationModelsMultitool. A line from `getSymbol` or `grepCode` goes directly into `files.read` and `files.edit`.

The index, tree-sitter and the language servers count from 0. Thus the engine and the public Swift types in `Ops/` use 0-based lines and UTF-16 columns, and their doc comments say "zero-based". The tools convert in one location, `Tools/ToolCoordinates.swift`:

- Each input line and column goes through `ToolCoordinates.zeroBased`. A line of 0 or less becomes line 1, and the result gets the note from `ToolCoordinates.lineNote`.
- Each tool result encodes through `OneBasedEncoder`. It adds 1 to each `Int` value whose key is in `ToolCoordinates.positionKeys`, at each depth of the result.

Rules:

- Do not convert a line or a column in an operation. Let the tool boundary do it.
- A result value that is already 1-based must not use a key in `positionKeys`, because the encoder then adds 1 a second time.
- A byte offset or a count is not a position. Do not give it a key in `positionKeys`.
- When you add a key for a line or a column, add it to `positionKeys` and to `OneBasedToolSurfaceTests`.

## Retrieval and selection

`searchCode` retrieves candidates, and then a language model selects from them. The host supplies both models. This package ships no model.

Retrieval reads three layers of the index, from the lowest to the highest:

- tree-sitter: chunks and call edges that come from the syntax tree
- LSP: symbols and call edges that come from the language servers
- search: the ranked lookup over the chunks that the two layers made

The search layer has three signals for each chunk: BM25, trigram Dice and embedding cosine. `HybridRanker` of FoundationModelsRanker fuses the three signals with RRF. `SignalWeights` sets the weight of each signal. The embedding signal is absent when the host gives no embedder.

Selection runs after retrieval:

- The host gives a required selection model: a `SelectionFactory` that returns a `SelectionConfig`. It has the same shape as the `SelectionFactory` of FoundationModelsMultitool. The host picks the model.
- `CodeContext` and `CodeContextManager` take `selection` as a required parameter. It has no `nil`, no default and no retrieval-only mode.
- `SelectionTier` of FoundationModelsRanker takes the retrieval hits and selects from them. The result is the selected hits, in the order of the model.
- An error of the factory or of the model session is the error of the call. We do not catch it, and we have no fallback.
- A search with no candidate applies no factory and calls no model.

In the traces, the selection step is the `select` span. It is a child of the `search` span, so the `search` span covers both retrieval and selection. Neither span holds the query or the text of a chunk.

Rules:

- Do not add a retrieval-only path that skips the selection model.
- Do not load a model in this package. The host owns model loading and model residency.
- `CodeContextManager.searchCode` runs the selection model one time for each search, over the merged candidates of all roots, and not one time for each root.
