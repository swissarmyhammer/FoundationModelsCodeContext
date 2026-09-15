# FoundationModelsCodeContext

[![CI](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml)

In-process code intelligence for Swift: one actor that indexes a repository,
controls its language servers, and answers questions about the code.

`CodeContext` opens a repository and indexes it with tree-sitter (Swift,
Rust, Python, TypeScript, Go, and ten more languages). It embeds code chunks
for semantic search, monitors file changes, and starts real LSP daemons —
all in your process, with no server, CLI, or IPC. Each operation returns a
plain `Codable & Sendable` value, so a FoundationModels `Tool` for an
in-process agent is a thin layer over one async method.

```swift
import FoundationModelsCodeContext

// `embedder` is your embedding model: any value that conforms to
// `TextEmbedding`, the embedding protocol of FoundationModelsRanker.
let context = try await CodeContext(
    rootDirectory: URL(fileURLWithPath: "/path/to/repo", isDirectory: true),
    embedder: embedder
)
try await context.start()  // walk, index, monitor files, start LSP servers

let symbols = try await context.searchSymbol(query: "parseConfig")
let hits = try await context.searchCode(query: "retry with backoff")

await context.stop()
```

Above the indexed layer, `CodeContext` gives live LSP operations —
`definition`, `hover`, `references`, `renameEdits`, and `codeActions` — and
an `@Observable` `CodeContextState` (server status, index progress,
diagnostics) that SwiftUI views can bind to. When a language server binary
is missing, `CodeContext` installs it automatically by default; see
[docs/language-servers.md](docs/language-servers.md).

## Install

Add the package to your `Package.swift` dependencies (macOS 27 is
necessary):

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsCodeContext", branch: "main")
```

## Documentation

- [Examples/CodeContextExample](Examples/CodeContextExample) — the full,
  compile-verified program for one repository.
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
