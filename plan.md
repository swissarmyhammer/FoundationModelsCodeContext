# FoundationModelsCodeContext — Port Plan

Port the code-context and LSP capabilities from `../swissarmyhammer` (Rust) to a
Swift package, **FoundationModelsCodeContext**, used strictly **in-process**. One process, one
workspace, one owner of the index and the LSP servers.

## Goal

```swift
let context = try await CodeContext(rootDirectory: URL(filePath: "/path/to/repo"),
                                    embedder: someEmbedder)   // injected, see Embeddings
try await context.start()          // walk, reconcile, index, watch, spawn LSP

let hits    = try await context.searchSymbol("parse_config")
let graph   = try await context.callGraph(of: "handleRequest", direction: .inbound)
let radius  = try await context.blastRadius(file: "Sources/App/Server.swift")
let results = try await context.searchCode("retry with backoff", topK: 20)
let diags   = try await context.diagnostics(scope: .workingTree)

// SwiftUI harness binds to unified in-memory state (servers, progress, diagnostics)
struct StatusView: View {
    let state: CodeContextState        // @Observable, published by the kit
    var body: some View { ForEach(state.servers) { ... } }
}
```

This package is the engine only — no server of any kind, no MCP, no CLI. The
consumer is a **higher-level package that wraps these ops as FoundationModels
`Tool` implementations** for an in-process agent harness. Two design
consequences here:

- Every op result is a plain `Codable & Sendable` value type, so a `Tool`
  wrapper is a thin `call(arguments:) -> output` shim over one async method —
  no adaptation layer needed.
- `CodeContext` is cheap to hold alongside the agent's other tools and safe
  to call concurrently from tool invocations (actor-isolated where it
  matters, read-only queries in parallel).

## What we are NOT porting (simplifications)

| Rust subsystem | Why it's dropped |
|---|---|
| `swissarmyhammer-leader-election` (flock election, lease/heartbeat, unix-socket IPC, ZMQ bus) | Single process owns everything |
| Leader/Follower `WorkspaceMode`, `FollowerGuard`, `step_down`, `open_as_follower` | Same |
| `LiveLspRouter` / `MultiLspRouter` follower→leader routing seams | Ops talk to the in-process `LspSession` directly |
| `spawn_reelection_loop`, follower diagnostics subscriber, promotion gating | Same |
| `ane-embedding` (CoreML/ANE) and `llama-embedding` (GGUF) backends, `model-loader` | Embeddings come from `../FoundationModelsRouter` (MLX); no hand-rolled ANE |
| MCP tool layer (`swissarmyhammer-tools` dispatch, schema) and any server surface | Consumer wraps ops as FoundationModels `Tool`s in a higher-level package |
| YAML server-spec registry + `include_dir!` embedding | Specs become plain Swift values (see LSP registry) |
| `ReadOnlyFollower` errors, residual-writer defenses | No second writer exists |

## Source material (Rust → Swift)

| Area | Rust source | Swift home |
|---|---|---|
| Workspace lifecycle, SQLite schema, cleanup, invalidation | `crates/swissarmyhammer-code-context/{workspace,db,cleanup,invalidation}.rs` | `Sources/FoundationModelsCodeContext/Index/` |
| Tree-sitter registry + semantic chunking | `crates/swissarmyhammer-treesitter/{language,chunk}.rs` | `Sources/FoundationModelsCodeContext/TreeSitter/` |
| TS call-edge heuristic | `crates/swissarmyhammer-code-context/ts_callgraph.rs` | `Sources/FoundationModelsCodeContext/TreeSitter/` |
| Hybrid ranker (BM25 + trigram + cosine, RRF) | `crates/swissarmyhammer-search/` | sibling [FoundationModelsRanker](https://github.com/swissarmyhammer/FoundationModelsRanker) package; `Sources/FoundationModelsCodeContext/Search/` keeps only corpus glue |
| LSP transport, session, daemon, supervisor | `crates/swissarmyhammer-lsp/{client,session,daemon,supervisor,types,diagnostics}.rs` | `Sources/FoundationModelsCodeContext/LSP/` |
| LSP background indexer (documentSymbol + call hierarchy → SQLite) | `crates/swissarmyhammer-code-context/{lsp_worker,lsp_communication,lsp_indexer}.rs` | `Sources/FoundationModelsCodeContext/Index/` |
| Layered cascade (LiveLsp → LspIndex → TreeSitter → None) | `crates/swissarmyhammer-code-context/layered_context.rs` | `Sources/FoundationModelsCodeContext/Ops/` |
| Query ops | `crates/swissarmyhammer-code-context/ops/*.rs` | `Sources/FoundationModelsCodeContext/Ops/` |
| Diagnose + settle engine | `crates/swissarmyhammer-diagnostics/{diagnose,settle,record}.rs` | `Sources/FoundationModelsCodeContext/Diagnostics/` |
| Project detection (marker files) | `crates/swissarmyhammer-project-detection/` | `Sources/FoundationModelsCodeContext/Projects/` |

## Package shape

```
FoundationModelsCodeContext/
  Package.swift            // swift-tools-version 6.1+, macOS 27 (floor inherited
                           // from FoundationModelsRouter)
  Sources/FoundationModelsCodeContext/
    CodeContext.swift      // public facade (actor)
    Languages/             // one LanguageModule per language (strategy) — grammar,
                           // chunk rules, project markers, server spec in one file
    Index/                 // SQLite store, walker/reconciler, workers, watcher
    TreeSitter/            // chunker, ts call edges, AST query (generic over Languages/)
    Search/                // corpus snapshot + Hit/Signals typealiases (BM25, trigram,
                           // cosine, RRF fusion live in the sibling FoundationModelsRanker package)
    LSP/                   // transport, session, daemon, supervisor, registry
    Diagnostics/           // diagnose, settle, report types
    Ops/                   // one file per operation, layered cascade
    Projects/              // project-type detection
    Embedding/             // TextEmbedding protocol + FoundationModelsRouter adapter
    Logging/               // os.Logger subsystem/category constants
  Tests/FoundationModelsCodeContextTests/
```

### Dependencies

- **FoundationModelsRouter** (GitHub URL, `main` — spelled identically to
  FoundationModelsRanker's declaration so the shared package identity resolves to a single
  origin; see the comment in `Package.swift`) — embeddings via `RoutedEmbedder`
  (`embed([String]) async throws -> [[Float]]`, L2-normalized, runtime `dimension`).
- **SwiftTreeSitter** (ChimeHQ) + per-language grammar packages.
- **GRDB** for SQLite (WAL, migrations, `DatabasePool` for concurrent reads).
  Alternative: raw `sqlite3` C API — more code, no dep. Recommend GRDB.
- Nothing else. No Yams (registry is Swift code), no swift-log (see Logging).

## Logging — the answer

**Use `os.Logger` (Apple unified logging) directly.** Rationale:

- The macOS 27 floor (inherited from FoundationModelsRouter) makes this an
  Apple-only package; the usual reason to prefer the `swift-log` facade
  (cross-platform backends) does not apply.
- Unified logging is structured, near-zero-cost when not captured, has built-in
  privacy redaction, and is queryable after the fact:
  `log stream --predicate 'subsystem == "com.swissarmyhammer.FoundationModelsCodeContext"'`
  or Console.app — exactly what you want when a language server dies at 2am.
- Categories map onto the Rust `tracing` targets we're porting:

```swift
enum Log {
    static let subsystem = "com.swissarmyhammer.FoundationModelsCodeContext"
    static let lsp        = Logger(subsystem: subsystem, category: "lsp")        // spawn/exit/restart/handshake
    static let lspWire    = Logger(subsystem: subsystem, category: "lsp-wire")   // request/response ids (.debug)
    static let index      = Logger(subsystem: subsystem, category: "index")      // walk/reconcile/chunk counts
    static let watcher    = Logger(subsystem: subsystem, category: "watcher")
    static let embedding  = Logger(subsystem: subsystem, category: "embedding")
    static let search     = Logger(subsystem: subsystem, category: "search")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
```

Log levels mirror the Rust code: state transitions at `.debug`, spawn/restart/
shutdown at `.info`/`.notice`, unexpected exits and handshake failures at
`.error` with the captured stderr tail. Child-process stderr is drained and
re-logged line-by-line at `.debug` (same as Rust's `StderrFilter` path).

If we ever want the host app to intercept logs programmatically, we can add a
minimal event-callback seam later — but don't build it now.

## Architecture

### The index (SQLite, Rust-derived schema — owned by us)

Start from the Rust schema — it's proven and simple — but it's ours to evolve:

- `indexed_files(file_path PK, content_hash, file_size, last_seen_at, ts_indexed, lsp_indexed, embedded)` — per-layer dirty flags
- `ts_chunks(file_path FK CASCADE, byte/line ranges, text, symbol_path, kind, embedding BLOB?)` — embedding is a little-endian Float32 blob; `kind` is the chunk's **meta-type** (`function | method | type | other`, from the language module's `chunkKinds` map — one addition over the Rust schema, so kind-aware ops don't re-parse)
- `lsp_symbols(id PK, name, kind, file_path FK CASCADE, ranges, detail)`
- `lsp_call_edges(caller_id, callee_id, files, from_ranges, source: 'lsp'|'treesitter')`

Location: `<root>/.code-context/kit.db`, WAL mode, dir self-gitignored. Same
directory convention as Rust sah but **our own database file** — no
cross-implementation compatibility (decided), so Rust's `index.db` and our
`kit.db` can coexist in one workspace without ever sharing a writer, and the
schema evolves freely through GRDB migrations.

**Startup reconcile** (`startup_cleanup` port): gitignore-aware walk
(replicate `ignore::WalkBuilder` semantics — honor `.gitignore`, skip hidden
and the `.code-context` dir), SHA-256 first-16-bytes content hash computed
concurrently (TaskGroup), then: deleted → DELETE (cascades), changed → mark
all layers dirty, new → INSERT dirty.

**Indexing workers** (structured-concurrency tasks owned by the `CodeContext` actor):

1. *Tree-sitter worker* — drain `ts_indexed = 0`: parse → chunk (definition
   node kinds → `SemanticChunk` with qualified `symbol_path`) → embed chunks
   (batched through the injected embedder; skip gracefully if unavailable,
   leaving `embedded = 0`) → write chunks + heuristic call edges → mark done.
   Parsing/embedding happen outside any DB transaction.
2. *LSP worker* (one per running daemon) — drain `lsp_indexed = 0` for that
   server's extensions: `didOpen` → `documentSymbol` (flatten to qualified
   symbols) → `prepareCallHierarchy`/`outgoingCalls` per function-like symbol →
   `didClose` → persist symbols + edges (`source = 'lsp'`) → mark done.
   Includes the Rust invalidation rule: when a file's symbol set shrinks,
   files with edges into removed symbols get `lsp_indexed = 0`.

**File watching**: FSEvents (recursive on root) debounced ~1s, filtered to
source extensions → mark dirty / delete rows → nudge workers. This replaces
Rust's `notify`/`async-watcher`; `FanoutWatcher` collapses to direct calls.

### Language modules (strategy pattern)

Everything language-specific lives in **one module per language, one file
each**, under `Sources/FoundationModelsCodeContext/Languages/`. This replaces the Rust
side's three parallel tables (tree-sitter `LANGUAGES`, the YAML `ServerSpec`
registry, and the project-detection marker table) with a single strategy:

```swift
public protocol LanguageModule: Sendable {
    static var name: String { get }                    // "swift"
    static var fileExtensions: [String] { get }        // ["swift"]
    static var treeSitterLanguage: Language? { get }   // grammar entry point
    static var chunkKinds: [String: SymbolMetaType] { get }
        // definition node kind → meta-type, e.g. "function_item": .function,
        // "class_declaration": .type — drives chunking AND kind-aware ops
    static var containerNodeKinds: Set<String> { get }   // impl/class/mod → symbol_path
    static var projectMarkers: [ProjectMarker] { get } // Package.swift, *.xcodeproj
    static var languageServer: ServerSpec? { get }     // nil → tree-sitter-only
}

// Languages/Swift.swift, Languages/Rust.swift, Languages/Java.swift, …
// The ONE place a new language is wired in:
enum Languages {
    static let all: [any LanguageModule.Type] = [
        SwiftLanguage.self, RustLanguage.self, PythonLanguage.self, /* … */
    ]
}
```

- The chunker, project detection, the LSP supervisor, and extension→language
  routing are all **generic consumers of `Languages.all`** — none of them
  contain per-language knowledge.
- Adding a language = one new file conforming to `LanguageModule` + one line
  in `Languages.all`. No other file changes.
- Multi-language servers compose naturally: the javascript, typescript, and
  tsx modules all reference the same `typescript-language-server` spec
  (c/cpp → clangd likewise); the supervisor's dedupe-by-command collapses
  them to one daemon.
- Tree-sitter-only entries (json, yaml, markdown, sql, bash) set
  `languageServer: nil`; detection-only cases are `treeSitterLanguage: nil`.

### Tree-sitter layer

- Grammar registry derives from `Languages.all` (SwiftTreeSitter + grammar
  SPM packages). Extraction stays **node-kind driven** via each module's
  `chunkKinds` / `containerNodeKinds` and the shared name-field
  heuristics — no `.scm` files, matching the Rust design. Every chunk is
  stamped with its meta-type from `chunkKinds` at extraction time.
- `queryAST` op compiles user S-expression queries at runtime against files on
  disk (SwiftTreeSitter supports this directly).

### Search

Pure-Swift port of `swissarmyhammer-search`. Three independent signals per
query, each producing a **ranking**, fused by rank — never by raw score:

1. **BM25** over tokenized chunk text, two weighted fields
   (`symbol_path` ×5, body ×1).
2. **Character-trigram Dice** — typo/partial-identifier tolerance.
3. **Cosine** between the query embedding and chunk embeddings.

**Fusion is Reciprocal Rank Fusion** (rank-based, same as Rust's `rrf_fuse`):

```
score(chunk) = Σ_signal  weight_signal / (K + rank_signal(chunk))     K = 60
```

BM25 scores, Dice coefficients, and cosines live on incomparable scales;
RRF sidesteps calibration entirely — only each signal's rank order matters.
A chunk missing from a signal (e.g. not yet embedded) simply contributes
nothing for that signal; fused scores are normalized to [0,1] and each `Hit`
carries its per-signal `Signals { bm25, trigram, cosine }` for
explainability. No embeddings at all → keyword-only results plus an
`IndexingProgress` note, same graceful degradation as Rust.

**Where the cosines happen — in process, on CPU, via Accelerate:**

- A `SearchCorpus` cache (owned by `CodeContext`) holds all embedded chunks
  in one **contiguous `[Float]` matrix** (N×dim, row per chunk, id sidecar
  array) plus the tokenized BM25/trigram structures. Loaded lazily from
  `ts_chunks` on first query, invalidated by a generation counter the
  indexing workers bump on write — next query reloads only if stale.
- Both corpus and query vectors are **L2-normalized** (the embedder
  guarantees it; the fake too), so **cosine = dot product**, and scoring all
  N chunks is one matrix–vector multiply: `cblas_sgemv`/vDSP over the cached
  matrix. ~100k chunks × 1024 dims ≈ 100M MACs — single-digit milliseconds
  on CPU; no Metal/MLX at query time (MLX is only inside the embedder when
  the *query text* is embedded, one call per search).
- `findDuplicates` reuses the same matrix: candidate pairs are compared
  within their meta-type partition (matrix–matrix product per partition when
  scoped to the workspace, one matvec per source chunk when scoped to a
  file), thresholded at `minSimilarity`.
- No vector DB and no ANN index by design — brute force is exact,
  zero-maintenance, and at workspace scale (10⁴–10⁵ chunks) faster than the
  bookkeeping an index would add. The seam to revisit: if a corpus ever
  exceeds ~10⁶ chunks, swap the matvec for a partitioned scan behind the
  same `SearchCorpus` API.

### Embeddings

FoundationModelsCodeContext defines a tiny seam and never owns model lifecycle:

```swift
public protocol TextEmbedding: Sendable {
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

- Shipped adapter: `RoutedEmbedderAdapter` wrapping FoundationModelsRouter's
  `RoutedEmbedder` (which already has exactly this shape).
- The **host app** resolves the Router profile and injects the embedder.
  Reason: `Router` allows one resident profile at a time and resolving one
  loads two LLMs alongside the embedder — that lifecycle belongs to the app,
  not to a library that merely consumes vectors.
- Tests inject a deterministic fake (hash-based vectors); no models, no
  downloads, no Metal in CI.
- Query text is embedded with the same embedder at search time; if the stored
  dimension differs from the current embedder's, treat all chunks as
  un-embedded and re-embed (dimension recorded in a small `meta` table).

### Project detection

Port of `swissarmyhammer-project-detection` — pure filesystem inspection, no
LSP involved. It answers "what kinds of code live under this root?" and is
what decides which language servers to spawn.

- **When**: runs inside `context.start()`, before any daemon spawns. Also
  callable on demand as `detectProjects()` (re-scans, refreshes
  `state.projects`).
- **Input**: the `rootDirectory` the `CodeContext` was constructed with —
  detection never takes its own path parameter.
- **How**: gitignore-aware walk looking for marker files —
  `Package.swift`/`*.xcodeproj` → swift, `Cargo.toml` → rust,
  `package.json`/`tsconfig.json` → javascript/typescript, `go.mod` → go,
  `pyproject.toml`/`setup.py`/`requirements.txt` → python,
  `pom.xml`/`build.gradle` → java, `*.csproj`/`*.sln` → c#,
  `composer.json` → php, `CMakeLists.txt`/`Makefile` → c/cpp — each marker
  declared by its `LanguageModule` (same marker semantics as the Rust crate).
  One directory can match **multiple types**, and a monorepo yields one
  `DetectedProject(type, directory)` per hit.
- **Output → servers**: the union of detected types maps through each
  module's `languageServer` spec, **deduped by command**, so a polyglot monorepo with
  six `package.json`s still runs exactly one `typescript-language-server`.
  Every daemon is initialized with the workspace `rootDirectory` as its
  `rootUri` — no per-sub-project roots, same simplification as Rust.
- Results land in `state.projects` and drive `state.servers`; a missing
  server binary shows up there as `.notFound` with its install hint rather
  than failing `start()`.

### LSP subsystem

Direct port of `swissarmyhammer-lsp`, minus election. All mutex-guarded shared
state becomes actors.

- **`ServerSpec`**: the Rust YAML spec fields become a plain Swift value —
  `command, args, languageIDs, startupTimeout (30s), healthCheckInterval
  (60s), installHint` — declared by each `LanguageModule` (shared instances
  for multi-language servers like `typescript-language-server` and `clangd`).
  No standalone registry; the supervisor collects specs from `Languages.all`.
  (Drop the `doctor:` blocks for now.)
- **Typed Swift API, no JSON-RPC layer.** The servers are external stdio
  processes whose only wire format is JSON-RPC, so `Content-Length` framing
  and message encoding exist — but strictly as a **private wire codec inside
  the server connection**, never as an abstraction or API. Nothing above the
  connection ever sees a method string, an id, or raw JSON. The seam the rest
  of the package (and tests) program against is a typed protocol:

  ```swift
  protocol LanguageServerConnection: Actor {
      func documentSymbols(in: DocumentURI) async throws -> [DocumentSymbol]
      func definition(in: DocumentURI, at: Position) async throws -> [Location]
      func hover(in: DocumentURI, at: Position) async throws -> Hover?
      func references(in: DocumentURI, at: Position) async throws -> [Location]
      func outgoingCalls(of: CallHierarchyItem) async throws -> [CallHierarchyOutgoingCall]
      // … one method per LSP capability we use (~17 total), typed in/out
      func didOpen/didChange/didSave/didClose(...)
      var serverNotifications: AsyncStream<ServerNotification> { get }  // publishDiagnostics
  }
  ```

  Request/response payloads are small hand-written `Codable` structs for just
  the methods we use — not a full LSP type library, no ChimeHQ dependency.
  Id-matching, the 30s per-request timeout, and the reader loop live inside
  the concrete `ProcessLanguageServerConnection`; tests use an in-memory fake
  conforming to the same protocol and never touch JSON.
- **`LspSession`** (actor): open-document set with `DocState(version, textHash)`,
  `syncOpen` (open-or-refresh, no-op-change suppression), per-URI diagnostics
  cache + `AsyncStream` fan-out (replaces tokio broadcast), `pullDiagnostics`
  (`textDocument/diagnostic`), `isReady` flag (flipped on ServerCancelled /
  ContentModified "still loading" replies), `resetDocuments()` on restart.
- **`LspDaemon`** (actor, one child process each) — the state machine:
  `notStarted → starting → running(pid) → failed(reason, attempts) →
  shuttingDown`, observable via `AsyncStream`. Lifecycle:
  1. Locate binary on PATH (miss → `.notFound` + install hint logged once).
  2. Spawn with piped stdio; stderr drained on a background task → `.debug` log.
  3. `initialize` (rootUri, empty capabilities — same optimistic stance as
     Rust: no capability gating, empty/null results mean "no data") then
     `initialized`, bounded by `startupTimeout`; on failure capture a stderr
     tail into the error and kill the child.
  4. **Health + auto-restart**: health check = process-exit detection
     (termination handler / periodic check every 60s). On unexpected exit:
     log `.error` with exit status, clear transport, `session.resetDocuments()`,
     state `.failed`, then restart with backoff **1, 2, 4, 8, 16, 32, 60 (cap)
     seconds**, giving up after **5 consecutive failures** (state stays
     `.failed`, visible in `lspStatus()`). Success resets the counter.
     `forceRestart()` resets the counter and restarts immediately.
  5. Graceful shutdown: `shutdown` request → `exit` notification → wait,
     bounded by 5s grace, else SIGKILL.
- **`LspSupervisor`** (actor): detect project types under root (marker files:
  `Package.swift`, `Cargo.toml`, `package.json`, `go.mod`, …), map to specs,
  **dedupe by command** (one daemon per server binary per workspace), own the
  daemons + the 60s health loop, expose `status()`, `forceRestart(command:)`,
  `shutdown()`, and `session(forFileExtension:)`.

### Observable state for SwiftUI (in-memory)

The kit unifies everything it knows — detected projects, LSP daemon health,
index progress, diagnostics — into one in-memory, SwiftUI-bindable model,
following the same pattern FoundationModelsRouter uses for
`ResolutionProgress`:

```swift
@MainActor @Observable
public final class CodeContextState {
    public private(set) var rootDirectory: URL             // the workspace this state describes
    public private(set) var projects: [DetectedProject]    // filled by detection during start()
    public private(set) var servers: [ServerStatus]        // per daemon: state, pid, restarts, lastError
    public private(set) var indexing: IndexProgress        // files walked/parsed/embedded/lsp-indexed, per layer
    public private(set) var diagnostics: [DocumentURI: [Diagnostic]]  // live cache, updated as servers publish
    public private(set) var isReady: Bool                  // all layers drained, servers settled
}
```

**How you get to it — vended off the `CodeContext` instance.** There is no
global; state is strictly per-workspace, scoped to the `CodeContext` that
owns it:

```swift
// The path under consideration enters exactly once, at construction.
let context = try await CodeContext(rootDirectory: repoURL, embedder: embedder)
try await context.start()

let state = context.state   // nonisolated let — created in init, same
                            // instance for the context's lifetime, safe to
                            // hand straight to a SwiftUI view
```

- One `CodeContext` per root directory; two workspaces = two contexts, two
  `state` objects, two indexes, two supervisor fleets. Nothing shared.
- `state` is a `nonisolated public let` on the `CodeContext` actor — grabbing
  the reference needs no `await`; reading its properties is main-actor
  (SwiftUI's home) by construction.
- `CodeContext` publishes into it (hopping to the main actor) from the
  workers, the supervisor's health loop, and the session's diagnostics
  stream — a SwiftUI harness just binds to it.
- This replaces the Rust side's status polling (`get status`, `lsp status`)
  as the *primary* surface; the async snapshot methods (`indexStatus()`,
  `lspStatus()`) remain as conveniences that read the same state.
- Query APIs stay `async` methods returning plain `Sendable` value types —
  results are request/response, not observable state.

### Layered ops

`LayeredContext` cascade, same semantics and provenance tags:

`liveLSP → lspIndex → treeSitter → none` — each op tries the live session
(`syncOpen` + request), falls back to indexed LSP symbols/edges, then
tree-sitter chunks, and returns an empty result tagged `.none` rather than
erroring when no layer has data.

Ops surface (public methods on `CodeContext`, mirroring the Rust op set):

- **Indexed**: `getSymbol`, `searchSymbol`, `listSymbols(file:)`, `grepCode`,
  `searchCode` (hybrid), `findDuplicates`, `queryAST`, `callGraph`
  (BFS over edges, direction in/out/both, depth ≤5), `blastRadius`
  (inbound BFS, hops ≤10, per-hop file aggregation), `indexStatus`,
  `rebuildIndex(layer:)`, `detectProjects`.
- **`findDuplicates` is meta-type-aware**: near-duplicate detection over
  symbol bodies compares **similar of a similar meta-type only** — methods
  against methods/functions, types against types — using the chunk `kind`
  column. A function body is never reported as a duplicate of a class, no
  matter the cosine. Scope: whole workspace or one file
  (`findDuplicates(file:minSimilarity:)`, default 0.85), grouped by source
  chunk with per-match similarity, same shape as the Rust op.
- **Live LSP — all ten ship in v1**: `definition`, `typeDefinition`, `hover`,
  `references`, `implementations`, `codeActions`, `renameEdits`
  (prepare+rename under one connection hold), `inboundCalls`,
  `workspaceSymbols`, plus `lspStatus`.
- **Diagnostics**: `diagnostics(scope: .workingTree | .file(glob) | .sha(range))`
  with the settle engine — seed from cache, wait for **300ms quiescence**,
  hard timeout **5s** → `pending: true`; fold in only *broken* one-hop
  dependents (from the call-edge index); severity floor defaults to warning.
  Clock injected for tests.

## Port order (each step compiles + is tested before the next)

1. **Package scaffold** — Package.swift (deps: FoundationModelsRouter — now a
   GitHub URL dependency on `main`, see Dependencies above — SwiftTreeSitter,
   GRDB, initial grammars), `Log` constants, error enum, CI-able `swift test`.
2. **Store** — GRDB schema + migrations, dirty-flag helpers, Float32-blob
   embedding codec, meta table (embedder dimension).
3. **Walker/reconciler** — gitignore-aware walk, concurrent hashing,
   reconcile logic (port of `startup_cleanup`), `.code-context/` bootstrap.
4. **Language modules + tree-sitter layer** — `LanguageModule` protocol,
   `Languages.all`, the v1 module files (node-kind tables ported per
   language), generic chunker (`symbol_path` qualification), TS worker
   writing chunks; then the TS call-edge heuristic; then `queryAST`.
5. **Embedding seam** — `TextEmbedding` protocol, fake for tests,
   `RoutedEmbedderAdapter`, batch embedding inside the TS worker.
6. **Search** — BM25/trigram/cosine/RRF port + `searchCode`, `findDuplicates`.
7. **Indexed ops** — `getSymbol` (match tiers Exact/Suffix/CaseInsensitive/Fuzzy),
   `searchSymbol`, `listSymbols`, `grepCode`, `callGraph`, `blastRadius`, status ops.
8. **LSP connection + session** — `LanguageServerConnection` protocol + typed
   payload structs, `ProcessLanguageServerConnection` (private wire codec,
   id-matching, timeouts) + in-memory fake, `LspSession` actor with
   diagnostics cache.
9. **LSP daemon + supervisor** — state machine, handshake, health loop,
   backoff auto-restart, graceful shutdown, project detection, registry.
10. **LSP indexer worker** — documentSymbol/call-hierarchy → SQLite,
    invalidation propagation; wire `source_layer` cascade into ops.
11. **Live ops** — definition/hover/references/…/renameEdits/workspaceSymbols.
12. **Diagnostics** — settle engine (injected clock), scopes, dependents
    fold-in, report types.
13. **Observable state** — `CodeContextState` (@MainActor @Observable), wired
    from workers, supervisor health loop, and diagnostics stream; snapshot
    methods read the same state.
14. **Watcher + facade polish** — FSEvents pipeline, `CodeContext.start()/stop()`
    lifecycle, end-to-end integration test against a fixture repo (and, gated
    on tool availability, a live `sourcekit-lsp` smoke test).

## Testing strategy

- Every LSP layer sits behind `LanguageServerConnection` — unit tests use a
  scripted in-memory fake (canned typed responses, induced crashes to exercise
  backoff/restart) and never touch JSON; the wire codec gets its own small
  round-trip tests.
- One gated integration test drives real `sourcekit-lsp` (present wherever
  Xcode is) end-to-end: spawn → index → definition → kill -9 the child →
  assert auto-restart and recovery.
- Embedding tests use the deterministic fake; a gated integration test uses
  the real FoundationModelsRouter profile.
- Search ranker gets golden tests ported from the Rust crate's cases.
- Fixture mini-repos under `Tests/Fixtures/` for walk/reconcile/watch tests.

## Open questions to discuss

1. ~~Grammar set for v1~~ **Resolved: TIOBE-driven.** Criterion: TIOBE top 15
   (June 2026) — the cutoff lands at Swift, #15 — ∩ languages the Rust side
   already has grammars + chunk rules for, plus the formats an agent harness
   always meets.
   - From TIOBE 1–15: **python, c, c++, java, c#, javascript, sql, rust, go,
     php, swift** (skipping Visual Basic #7, R #9, Delphi #10, Scratch #11 —
     no sah chunk rules, negligible agent-harness value).
   - Plus: **typescript/tsx** (TIOBE ranks it separately but it's essential),
     and **json, yaml, markdown, bash** for config/docs/scripts.
   - LSP registry already covers the compiled ones (`jdtls`, `omnisharp`,
     `intelephense`, `clangd`, `rust-analyzer`, `gopls`, `pylsp`,
     `typescript-language-server`, `sourcekit-lsp`); sql/json/yaml/markdown
     are tree-sitter-only layers, same as Rust.
   - Long tail (kotlin, ruby, scala, dart, …) rides on the registry design:
     one table row + one grammar dep each, added on demand.
2. ~~LSP transport: hand-rolled vs ChimeHQ~~ **Resolved: no JSON-RPC layer at
   all.** Typed Swift API (`LanguageServerConnection`) is the only seam; the
   JSON-RPC wire encoding is a private detail of the process-backed
   implementation. No ChimeHQ/JSONRPC dependency.
3. ~~Server registry: Swift code vs drop-in files~~ **Resolved: code only, as
   a strategy pattern.** No file/YAML extensibility — adding a language is
   easy enough in code. Everything language-specific (grammar, chunk node
   kinds, project markers, server spec) lives in one `LanguageModule` per
   language, one file each, registered in `Languages.all`; all consumers are
   generic over that list (see "Language modules").
4. ~~Index compatibility~~ **Resolved: not needed.** FoundationModelsCodeContext owns its
   schema outright — same `.code-context/` directory convention, but its own
   `kit.db` file, so Rust sah's `index.db` and ours can coexist in one
   workspace with no shared writer and no schema coupling. Migrations via
   GRDB, versioned independently.
5. ~~Live-op set for v1~~ **Resolved: all ten live LSP ops ship in v1** —
   nothing deferred. Alongside them, `blastRadius` and meta-type-aware
   `findDuplicates` (methods/functions/types compared only within their own
   meta-type) are explicitly first-class indexed ops.

## Manager (multi-root workspaces)

`CodeContext` is deliberately single-root (see "Observable state for
SwiftUI": "One `CodeContext` per root directory; two workspaces = two
contexts... Nothing shared."). `CodeContextManager` is the second, additive
way in for a host that wants several repos in one process — it never wraps
or replaces `CodeContext`; it owns a routed collection of them and stays out
of the standalone entry point's way entirely. This section records the
agreed design decisions the manager's doc comments reference.

- **Git repo = the project unit.** `RootDiscovery` treats a directory
  containing a direct `.git` entry (directory or file — worktrees and
  submodules count) as one project, full stop — unlike `ProjectDetection`,
  there is no marker-file fallback. `discoverRoots(under:)` walks a parent
  directory gitignore-obliviously (it must see `.git` itself, so it cannot
  reuse the indexing walker's hidden-entry skip) and prunes below every root
  it finds, so a repo nested inside another repo's working tree is never
  returned. `gitRoot(containing:)` walks upward from an arbitrary path to
  the nearest such ancestor, for lazy routing.

- **Three entry points, one open-or-get core.** A caller reaches a root's
  `CodeContext` one of three ways: discover every root under a parent via
  `RootDiscovery.discoverRoots(under:)` and open each explicitly; open one
  known directory directly (git repo or not — explicit `context(for:)`
  accepts any directory, discovery-driven or not); or resolve lazily by
  file path via `context(containing:)`, which walks the already-open roots
  first and only falls back to `RootDiscovery.gitRoot(containing:)` (opening
  it on demand, gated by `openIfNeeded`) when nothing open already covers
  it. All three funnel into the same private open-or-get core
  (`createStartAndRegister`), so every path — explicit or lazy — passes
  through one overlap check and one dedupe table, never a second one a
  future entry point could accidentally skip.

- **Overlap rule.** Roots are standardized (`URL.standardizedFileURL`) before
  every comparison, then: an exact match against an already-open root
  returns that root's own context; a root that is a **descendant** of an
  already-open root also returns that ancestor's context — its walker
  already covers the subtree, so no second context is ever created for
  something nested inside one already open; a root that is an **ancestor**
  of one or more already-open (or still-opening) roots throws
  `CodeContextError.overlappingRoot`, naming the conflicting children — the
  caller must `close(root:)` every already-open child first. The check
  covers `inFlightOpens` (roots mid-open, not yet registered) as well as
  `contexts`, not `contexts` alone: without that, two brand-new nested roots
  opened concurrently could each pass the check before either is registered
  and both end up started, violating the invariant the manager exists to
  enforce. Concurrent calls for the same root (or a descendant of a
  still-opening root) dedupe onto the one in-flight `Task` rather than
  racing to build their own `CodeContext`, mirroring `LspSupervisor`'s own
  `inFlightStart` coalescing.

- **Keep-all-started lifecycle.** Every successful `context(for:)` call has
  already run `start()` on the context it returns — there is no
  "open but not started" state visible outside the manager. A `start()`
  failure leaves the root unregistered rather than parked half-open. The
  only ways down are `close(root:)` (stop one root, no-op if it isn't open)
  and `shutdown()` (close every open root); nothing else removes a root from
  `contexts`.

- **Fan-out + merge with partial failure.** `Ops/ManagerQueries.swift`
  extends `CodeContextManager` with workspace-wide
  `searchCode(query:topK:weights:)`, `searchSymbol(query:kind:maxResults:)`,
  and `grepCode(pattern:languages:filePattern:maxResults:)`. Each runs the
  same per-root `CodeContext` op concurrently across every open context in a
  `TaskGroup` (never serially) and catches a failing root's own error into a
  `FanOutFailure { root, message }` instead of letting one bad root sink the
  whole call. Every surviving result is wrapped `Rooted<Value> { root, value
  }` — the per-context result's own paths stay root-relative, so `root` is
  what disambiguates an identically-pathed match in one open repo from the
  same path in another. **Merge rule: rank-major interleave, never
  score.** `SearchCode.run`'s fused score is RRF-normalized to `[0, 1]`
  *per corpus*, relative to each root's own chunk population, so sorting the
  union by raw score would systematically favor a small repo's inflated
  scores over a large repo's genuinely stronger but comparatively
  scaled-down ones. Instead the union is walked rank `0, 1, 2, ...` across
  every contributing root (sorted by root path as a tie-break) in turn, so
  every root's rank-0 result precedes every root's rank-1 result and a
  union cap smaller than any single root's own count still samples from
  every contributing root rather than exhausting the alphabetically-first
  root's quota first.

- **`ManagerState` aggregation, vacuous-ready semantics.** `ManagerState` is
  the manager's `CodeContextState` counterpart — a `@MainActor @Observable`
  aggregate keyed by standardized root URL, published into via
  `nonisolated` awaitable `publishOpened(root:state:)` /
  `publishClosed(root:)` calls that hop to the main actor, mirroring
  `CodeContextState`'s own publish/observe contract. `isReady` is computed,
  not cached — `contexts.values.allSatisfy(\.isReady)` — so it tracks
  through to every child `CodeContextState`'s own `@Observable` `isReady`
  without the manager needing to republish anything itself, and is
  **vacuously `true`** when no root is open, matching how
  `CodeContextState.isReady` documents its own vacuous initial state: no
  roots open means nothing outstanding to wait for.
