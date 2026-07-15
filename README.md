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

## Two ways in

**One repo — `CodeContext`.** The snippet above opens a single workspace
directly; see [`Examples/CodeContextExample`](Examples/CodeContextExample)
for the full, compile-verified program (embedder resolution → init → start →
queries → stop).

**Several repos — `CodeContextManager`.** For a workspace holding multiple
repositories, `CodeContextManager` owns one `CodeContext` per open root,
enforces a non-overlapping-roots invariant, and adds workspace-wide fan-out
queries whose results are tagged with the root that produced them.
[`Examples/ManagerExample`](Examples/ManagerExample) is the compile-verified
twin of this snippet:

```swift
import FoundationModelsCodeContext

// `embedder` is the same `TextEmbedding` used above, shared by every repo
// the manager opens.
let manager = await CodeContextManager(embedder: embedder)

let roots = try RootDiscovery.discoverRoots(under: URL(filePath: "/path/to/workspace"))
for root in roots {
    _ = try await manager.context(for: root)   // opens (and starts) each repo
}

// Lazy routing: resolve whichever open root covers an arbitrary file,
// discovering and opening its enclosing git repo on demand if none is open
// yet. Returns nil if no open root covers it and none can be discovered.
let owner = try await manager.context(containing: someFile)

// Fan out across every open root; each hit is root-qualified via `Rooted`.
// Scores are normalized per root, so never compare `hit.value.hit.score`
// across two different `hit.root`s.
let (hits, failures) = await manager.searchCode(query: "retry with backoff")
for hit in hits {
    print(hit.root.path, hit.value.filePath, hit.value.hit.score)
}

await manager.shutdown()
```

## Install

Add to your `Package.swift` dependencies (requires macOS 27):

```swift
.package(url: "https://github.com/swissarmyhammer/FoundationModelsCodeContext", branch: "main")
```

## Documentation

Design and porting notes live in [plan.md](plan.md). Hybrid search ranking
(BM25 + trigram + cosine, fused with RRF) comes from the sibling
[FoundationModelsRanker](https://github.com/swissarmyhammer/FoundationModelsRanker) package, and embeddings
from [FoundationModelsRouter](https://github.com/swissarmyhammer/FoundationModelsRouter).
