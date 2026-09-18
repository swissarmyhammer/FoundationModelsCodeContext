# FoundationModelsCodeContext

[![CI](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml)

In-process code intelligence for Swift: one actor that indexes a repository,
controls its language servers, and answers questions about the code.

`CodeContext` opens a repository and indexes it with tree-sitter (Swift,
Rust, Python, TypeScript, Go, and ten more languages). It embeds code chunks
for semantic search, monitors file changes, and starts real LSP daemons —
all in your process, with no server, CLI, or IPC. Each operation returns an
`Encodable & Sendable` value. The package also ships three FoundationModels
tools — `code_search`, `code_navigation` and `code_index` — so an in-process
agent can call the same operations.

```swift
import FoundationModelsCodeContext

// `embedder` is your embedding model: any value that conforms to
// `TextEmbedding`, the embedding protocol of FoundationModelsRanker.
let context = try await CodeContext(
    rootDirectory: URL(fileURLWithPath: "/path/to/repo", isDirectory: true),
    embedder: embedder
)
try await context.start()  // monitor files, start LSP servers, start the index in the background
await context.waitForFirstIndexPass()  // optional: wait for the complete first index pass

let symbols = try await context.searchSymbol(query: "parseConfig")
let hits = try await context.searchCode(query: "retry with backoff")

await context.stop()
```

`start()` returns before the index is complete. The first index pass runs in
the background. While it runs, the symbol operations and the language-server
operations answer from the partial index, and `indexStatus()` shows how much
of the index is complete. `await context.waitForFirstIndexPass()` waits for
the complete first pass.

`embedder: nil` turns the embedding layer off. Then there is no semantic
search: `searchCode` and `findDuplicates` throw
`CodeContextError.embeddingDisabled`, and `indexStatus().isEmbeddingEnabled`
is `false`. The other operations stay available.

Above the indexed layer, `CodeContext` gives live LSP operations —
`definition`, `hover`, `references`, `renameEdits`, and `codeActions` — and
an `@Observable` `CodeContextState` (server status, index progress,
diagnostics) that SwiftUI views can bind to. When a language server binary
is missing, `CodeContext` installs it automatically by default; see
[docs/language-servers.md](docs/language-servers.md).

## Tools

`CodeContextTools.make(context:)` gives the three FoundationModels tools of one
`CodeContext`: `code_search` (9 operations), `code_navigation` (10) and
`code_index` (4). Give them to a `LanguageModelSession`:

```swift
import FoundationModels
import FoundationModelsCodeContext

let tools = try CodeContextTools.make(context: context)
let session = LanguageModelSession(tools: tools, instructions: instructions)
```

Each tool fuses its operations into one schema. The model selects an operation
with the `op` parameter, for example `get symbol`. `CodeContextTools.toolNames`
gives the three names, and `CodeContextTools.operationNames` gives the op
strings of each tool. For each operation, each parameter and each alias, see
[docs/tools.md](docs/tools.md).

## Install

Add the package to your `Package.swift` dependencies (macOS 27 is
necessary):

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsCodeContext", branch: "main")
```

## Documentation

- [Examples/CodeContextExample](Examples/CodeContextExample) — the full,
  compile-verified program for one repository.
- [docs/tools.md](docs/tools.md) — the three tools, with each operation, each
  parameter and each alias.
- [docs/multiple-repos.md](docs/multiple-repos.md) — `CodeContextManager`
  for a workspace with many repositories.
- [docs/language-servers.md](docs/language-servers.md) — the server table
  and the auto-install controls.
- [plan.md](plan.md) — design and porting notes.

Hybrid search ranking (BM25 + trigram + cosine, fused with RRF) comes from
[FoundationModelsRanker](https://github.com/swissarmyhammer/FoundationModelsRanker).
Your app supplies the embedding model through `TextEmbedding`. This package
has no embedding model of its own. The same value also works with the
`Searcher` of FoundationModelsRanker. `Searcher` also takes a FoundationModels
`LanguageModelSession` for its selection tier. `CodeContext` itself takes no
language model.
