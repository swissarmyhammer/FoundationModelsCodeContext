# Tools

This package ships three FoundationModels tools.
`CodeContextTools.make(context:)` makes them from one `CodeContext`, and the
host gives them to a `LanguageModelSession`:

```swift
import FoundationModels
import FoundationModelsCodeContext

let tools = try CodeContextTools.make(context: context)
let session = LanguageModelSession(tools: tools, instructions: instructions)
```

`CodeContextTools.toolNames` gives the name of each tool, in the order of
`make`. `CodeContextTools.operationNames` gives the op strings of each tool,
with the name of the tool as the key. The tool types stay internal, thus the
host needs no other import.

| Tool | Operations | What it does |
|---|---|---|
| `code_search` | 9 | Find symbols, walk the call graph, and search the text and the syntax tree of the workspace. |
| `code_navigation` | 10 | Move through the code from a position in a file. |
| `code_index` | 4 | Report the state of the index and of the language servers, and rebuild the index. |

`make` also takes `includesSchemaInInstructions`. It is `true` by default. Make
it `false` when the host gives the operations to the model in its own
instructions.

## How to call an operation

Each tool fuses its operations into one schema. The model selects an operation
with the `op` parameter, for example `op: "get symbol"`. The other parameters
of the call are the parameters of that operation.

A recoverable failure does not stop the turn of the model. The operation gives
a corrective message instead. Read the message, correct the call, and try
again.

## The rules of a name

- An op string and a parameter name ignore the letter case, `_` and `-`. Thus
  `get type_definition`, `get typeDefinition`, `GET TYPE-DEFINITION` and
  `get typedefinition` all select the same operation.
- The verb and the noun can be in the two orders. Thus `get typedefinition` and
  `type_definition get` select the same operation.
- Each tool also accepts the verb aliases and the noun aliases of its tables
  below. Thus `lookup symbol` selects `get symbol`.
- Each parameter accepts the aliases of its row. `file` and `path` are aliases,
  thus `path` also gives the file.
- A `file` is a path relative to the root of the workspace. `get diagnostics`
  also accepts an absolute path or a glob.
- A `line` and a `character` are 0-based: the first line is line 0, and the
  first character is character 0. A `character` is a count of UTF-16 units.
- `query ast` takes its S-expression in the `astQuery` parameter. The aliases
  of that parameter are `query`, `sexp` and `pattern`.
- `get callgraph` accepts a symbol name, or a `<file>:<line>:<column>` locator
  with 0-based numbers.
- The `severity` parameter of `get diagnostics` takes a name: error, warning,
  information or hint. The `severity` field of the output is the LSP number:
  1 = error, 2 = warning, 3 = information, 4 = hint.

## `code_search`

| Op string | What it does |
|---|---|
| `get symbol` | Find the symbols whose name matches the query. Each result gives the location and the source text. |
| `search symbol` | Find the symbols whose name is near the query, with a fuzzy match. |
| `list symbol` | Give each symbol of one file, in the order of the file. |
| `get callgraph` | Walk the call graph from one symbol. |
| `get blastradius` | Find the symbols and the files that a change to one file, or to one symbol, can affect. |
| `grep code` | Find the indexed code chunks whose text matches a regular expression. |
| `search code` | Find the code chunks that are near a free-text query. |
| `find duplicates` | Find the code chunks that are near-duplicates of each other. |
| `query ast` | Run a tree-sitter S-expression query on the files of one language. |

### The parameters of `code_search`

| Op string | Parameter | Aliases | Necessary | What it is |
|---|---|---|---|---|
| `get symbol` | `query` | `name`, `symbol` | yes | The symbol name to search for. |
| `get symbol` | `maxResults` | `limit`, `max` | no (default 50) | The maximum number of results. |
| `search symbol` | `query` | `name`, `symbol` | yes | The symbol name to search for. |
| `search symbol` | `kind` | `symbolKind`, `type` | no (all the kinds) | One of function, method, type or other. |
| `search symbol` | `maxResults` | `limit`, `max` | no (default 50) | The maximum number of results. |
| `list symbol` | `file` | `path`, `filePath`, `filename` | yes | The file whose symbols to give. |
| `get callgraph` | `symbol` | `name`, `locator` | yes | A symbol name, or a `<file>:<line>:<column>` locator. |
| `get callgraph` | `direction` | `dir` | no (default outbound) | One of inbound (to the callers), outbound (to the callees) or both. |
| `get callgraph` | `maxDepth` | `depth` | no (default 2) | The maximum number of call levels to walk. |
| `get blastradius` | `file` | `path`, `filePath`, `filename` | yes | The file that changes. |
| `get blastradius` | `symbol` | `name` | no (all the symbols) | The symbol inside the file that changes. |
| `get blastradius` | `maxHops` | `hops`, `depth` | no (default 3) | The maximum number of call-edge hops to walk. |
| `grep code` | `pattern` | `regex`, `query` | yes | The regular expression to search for. |
| `grep code` | `languages` | `extensions`, `langs` | no (all the languages) | The file extensions to search, with no dot. |
| `grep code` | `filePattern` | `glob`, `include` | no (all the files) | A POSIX glob that the path of a file must match. |
| `grep code` | `maxResults` | `limit`, `max` | no (default 50) | The maximum number of results. |
| `search code` | `query` | `text`, `q` | yes | The free text to search for. |
| `search code` | `topK` | `limit`, `maxResults`, `k` | no (default 20) | The number of hits to give. |
| `find duplicates` | `file` | `path`, `filePath`, `filename` | no (all the files) | The one file to compare. |
| `find duplicates` | `minSimilarity` | `threshold`, `similarity` | no (default 0.85) | The minimum similarity of a pair, from 0.0 to 1.0. |
| `find duplicates` | `minChunkBytes` | `minBytes`, `minSize` | no (default 100) | The minimum size, in bytes, of a chunk to compare. |
| `find duplicates` | `maxPerChunk` | `perChunk` | no (default 5) | The maximum number of duplicates for one chunk. |
| `query ast` | `language` | `lang` | yes | The language of the files to query, for example swift. |
| `query ast` | `astQuery` | `query`, `sexp`, `pattern` | yes | The tree-sitter S-expression query. |
| `query ast` | `maxResults` | `limit`, `max` | no (default 50) | The maximum number of results. |

### The aliases of `code_search`

| Verb alias | Real verb |
|---|---|
| `lookup` | `get` |
| `locate` | `get` |
| `ls` | `list` |
| `enumerate` | `list` |
| `match` | `grep` |

| Noun alias | Real noun |
|---|---|
| `symbols` | `symbol` |
| `graph` | `callgraph` |
| `calls` | `callgraph` |
| `impact` | `blastradius` |
| `source` | `code` |
| `duplicate` | `duplicates` |
| `dupes` | `duplicates` |

## `code_navigation`

Each operation of this tool starts from a position in a file. Without a running
language server the operations use the LSP index, and then tree-sitter. The
`sourceLayer` field of each result tells which layer gave the data.

| Op string | What it does |
|---|---|
| `get definition` | Find the place where the program declares the symbol at the position. |
| `get type_definition` | Find the place where the program declares the type of that symbol. |
| `get hover` | Give the type, the signature or the documentation of that symbol. |
| `get references` | Find each place that uses that symbol. |
| `get implementations` | Find each implementation of that symbol. |
| `get code_actions` | Find the code actions of a range, for example a quick fix. |
| `get rename_edits` | Give the edits of a rename. The operation changes no file. |
| `get inbound_calls` | Find each function that calls that symbol. |
| `search workspace_symbol` | Find the symbols of the workspace whose name matches the query. |
| `get diagnostics` | Give the errors and the warnings of a scope. |

### The parameters of `code_navigation`

The five operations `get definition`, `get type_definition`, `get hover`,
`get references` and `get implementations`, and also `get inbound_calls` and
`get rename_edits`, all take the same three position parameters:

| Parameter | Aliases | Necessary | What it is |
|---|---|---|---|
| `file` | `path`, `filePath`, `filename` | yes | The file that holds the position. |
| `line` | `row` | yes | The line of the position. The first line is line 0. |
| `character` | `column`, `col` | yes | The character offset in the line, in UTF-16 units. The first character is character 0. |

Each other parameter belongs to one operation:

| Op string | Parameter | Aliases | Necessary | What it is |
|---|---|---|---|---|
| `get definition` | `includeSource` | `withSource`, `source` | no (default false) | Whether each location also gives its source text. |
| `get type_definition` | `includeSource` | `withSource`, `source` | no (default false) | Whether each location also gives its source text. |
| `get references` | `includeDeclaration` | `withDeclaration`, `includeDecl` | no (default false) | Whether the result also includes the declaration. |
| `get references` | `maxResults` | `limit`, `max` | no (default 50) | The maximum number of results. |
| `get implementations` | `includeSource` | `withSource`, `source` | no (default false) | Whether each location also gives its source text. |
| `get implementations` | `maxResults` | `limit`, `max` | no (default 20) | The maximum number of results. |
| `get rename_edits` | `newName` | `name`, `to`, `newSymbol` | yes | The new name of the symbol. |
| `get code_actions` | `file` | `path`, `filePath`, `filename` | yes | The file that holds the range. |
| `get code_actions` | `startLine` | `fromLine`, `startRow` | yes | The line where the range starts. |
| `get code_actions` | `startCharacter` | `startColumn`, `fromColumn` | yes | The character offset where the range starts. |
| `get code_actions` | `endLine` | `toLine`, `endRow` | yes | The line where the range ends. |
| `get code_actions` | `endCharacter` | `endColumn`, `toColumn` | yes | The character offset where the range ends. |
| `get code_actions` | `only` | `kinds`, `actionKinds` | no (all the kinds) | The kinds to keep, for example quickfix or refactor. |
| `search workspace_symbol` | `query` | `name`, `symbol` | yes | The name, or a part of the name, to find. |
| `get diagnostics` | `scope` | `mode` | yes | One of working (each file that the working tree changes), file (the file or the glob of `file`) or sha (the files that the commit changes). |
| `get diagnostics` | `file` | `path`, `filePath`, `filename` | only for the scope file | A path, an absolute path or a glob. |
| `get diagnostics` | `sha` | `ref`, `commit`, `revision`, `range` | only for the scope sha | A commit name, or a `<from>..<to>` range. |
| `get diagnostics` | `severity` | `level`, `minSeverity` | no (default warning) | The lowest severity to report: error, warning, information or hint. |

### The aliases of `code_navigation`

| Verb alias | Real verb |
|---|---|
| `find` | `get` |
| `lookup` | `get` |
| `goto` | `get` |
| `list` | `get` |
| `check` | `get` |
| `query` | `search` |

| Noun alias | Real noun |
|---|---|
| `def` | `definition` |
| `typedef` | `type_definition` |
| `type` | `type_definition` |
| `info` | `hover` |
| `docs` | `hover` |
| `reference` | `references` |
| `refs` | `references` |
| `usages` | `references` |
| `implementation` | `implementations` |
| `impls` | `implementations` |
| `code_action` | `code_actions` |
| `actions` | `code_actions` |
| `fixes` | `code_actions` |
| `rename` | `rename_edits` |
| `inbound_call` | `inbound_calls` |
| `incoming_calls` | `inbound_calls` |
| `callers` | `inbound_calls` |
| `workspace_symbols` | `workspace_symbol` |
| `symbol` | `workspace_symbol` |
| `symbols` | `workspace_symbol` |
| `diagnostic` | `diagnostics` |
| `errors` | `diagnostics` |
| `problems` | `diagnostics` |

## `code_index`

| Op string | What it does |
|---|---|
| `get status` | Give the progress of the index: the number of files that the walk found, and the number of files that each layer indexed. |
| `get lsp_status` | Give the state of each language server that the workspace manages. |
| `rebuild index` | Mark the files of one layer dirty, so that the workspace indexes them again. |
| `detect projects` | Find the marker file of each language, for example `Package.swift`, and give one project for each language. |

### The parameters of `code_index`

`get status`, `get lsp_status` and `detect projects` have no parameter.

| Op string | Parameter | Aliases | Necessary | What it is |
|---|---|---|---|---|
| `rebuild index` | `layer` | `target` | yes | One of treesitter, lsp, embedding or all. |

### The aliases of `code_index`

| Verb alias | Real verb |
|---|---|
| `check` | `get` |
| `refresh` | `rebuild` |
| `scan` | `detect` |
| `discover` | `detect` |
| `find` | `detect` |
| `list` | `detect` |

| Noun alias | Real noun |
|---|---|
| `state` | `status` |
| `progress` | `status` |
| `index_status` | `status` |
| `lsp` | `lsp_status` |
| `servers` | `lsp_status` |
| `server_status` | `lsp_status` |
| `language_servers` | `lsp_status` |
| `project` | `projects` |
| `languages` | `projects` |

`index` is not a noun alias, because it is the real noun of `rebuild index`.
