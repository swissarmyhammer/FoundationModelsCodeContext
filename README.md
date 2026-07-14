# FoundationModelsCodeContext

[![CI](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsCodeContext/actions/workflows/ci.yml)

In-process code intelligence for Swift: one actor that indexes a workspace,
supervises its language servers, and answers questions about the code.

`CodeContext` opens a repository, indexes it with tree-sitter (Swift, Rust,
Python, TypeScript, Go, and a dozen more languages), embeds code chunks for
semantic search, watches for file changes, and spawns real LSP daemons — all
inside your process, with no server, CLI, or IPC. Every operation returns a
plain `Codable & Sendable` value, so wrapping ops as FoundationModels `Tool`s
for an in-process agent harness is a thin shim over one async method.

```swift
import FoundationModelsCodeContext

// `embedder` is any `TextEmbedding`; `RoutedEmbedderAdapter` wraps a
// FoundationModelsRouter embedding model.
let context = try await CodeContext(
    rootDirectory: URL(filePath: "/path/to/repo"),
    embedder: embedder
)
try await context.start()   // walk, index, watch files, spawn LSP servers

let symbols = try await context.searchSymbol(query: "parseConfig")
let callers = try await context.callGraph(of: "handleRequest", direction: .inbound)
let radius  = try await context.blastRadius(file: "Sources/App/Server.swift")
let hits    = try await context.searchCode(query: "retry with backoff", topK: 20)
let report  = try await context.diagnostics(scope: .workingTree)

await context.stop()
```

Beyond the indexed layer, `CodeContext` exposes live LSP ops — `definition`,
`hover`, `references`, `implementations`, `renameEdits`, `codeActions` — and
publishes an `@Observable` `CodeContextState` (server status, index progress,
diagnostics) that SwiftUI views can bind to directly.

## Install

Add to your `Package.swift` dependencies (requires macOS 27):

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsCodeContext", branch: "main")
```

## Documentation

Design and porting notes live in [plan.md](plan.md). Hybrid search ranking
(BM25 + trigram + cosine, fused with RRF) comes from the sibling
[RankKit](https://github.com/swissarmyhammer/RankKit) package, and embeddings
from [FoundationModelsRouter](https://github.com/swissarmyhammer/FoundationModelsRouter).
