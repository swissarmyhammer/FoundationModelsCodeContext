# Many repositories: `CodeContextManager`

For a workspace that holds more than one repository, `CodeContextManager`
owns one `CodeContext` for each open root. It makes sure that open roots do
not overlap, and it adds workspace-wide fan-out queries. Each result shows
the root that made it.

[`Examples/ManagerExample`](../Examples/ManagerExample) is the full,
compile-verified program:

```swift
import FoundationModelsCodeContext

// `embedder` is the same `TextEmbedding` used for a single `CodeContext`.
// Each repository that the manager opens shares it.
let manager = await CodeContextManager(embedder: embedder)

let roots = try RootDiscovery.discoverRoots(under: URL(filePath: "/path/to/workspace"))
for root in roots {
    _ = try await manager.context(for: root)   // opens (and starts) each repo
}

// Lazy routing: find the open root that contains an arbitrary file. If no
// open root contains it, the manager tries to discover and open the git
// repository around it. Returns nil if that is not possible.
let owner = try await manager.context(containing: someFile)

// Fan out across each open root; each hit is root-qualified with `Rooted`.
// Scores are normalized for each root, so do not compare
// `hit.value.hit.score` across two different `hit.root`s.
let (hits, failures) = await manager.searchCode(query: "retry with backoff")
for hit in hits {
    print(hit.root.path, hit.value.filePath, hit.value.hit.score)
}

await manager.shutdown()
```
