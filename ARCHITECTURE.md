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
