import Foundation
import FoundationModelsCodeContext
import FoundationModelsRouter

/// # Runnable demo: standalone, single-root `CodeContext`.
///
/// The standalone "way in" to this package (see plan.md's Goal): point it at
/// one repository root and it walks the public API end to end — resolve an
/// embedder, open a `CodeContext`, start it, run a couple of read-only
/// queries, then tear both the context and the resolved profile down.
///
/// ## Why this resolves through `FoundationModelsRouter` directly
///
/// This package ships no embedder factory — `RoutedEmbedderAdapter`'s public
/// initializer takes an already-resolved `RoutedEmbedder` handle, and
/// plan.md's "Embeddings" section records why: resolving a
/// `FoundationModelsRouter` profile loads two generation models alongside the
/// embedding model and allows only one resident profile at a time, so owning
/// that lifecycle is a host-app decision, not something a library that only
/// consumes vectors should make. This example plays the host app's part
/// itself, calling `Router.resolve(profile:reporting:)` — the *only* public
/// resolution entry point FoundationModelsRouter exposes — to obtain the
/// `RoutedEmbedder` this file wraps.
///
/// ## What this file does and does not exercise
///
/// This target links nothing beyond `FoundationModelsCodeContext` and
/// `FoundationModelsRouter` themselves — no Hugging Face Hub client, no MLX
/// weight loader — so `swift build` stays fast and dependency-light. That is
/// this file's actual job: compile-verifying and documenting the public
/// surface of both packages (mirroring the package README's example), not
/// holding logic. It means a real, weight-downloading `swift run
/// CodeContextExample` needs more than this file alone provides:
///
///   - `Router.resolve` still reaches out over the network to size the
///     profile's candidates against Hugging Face repo metadata.
///   - Actually downloading and loading the chosen trio needs a configured
///     `LiveModelLoader` (a `Downloader` + `TokenizerLoader`, e.g. via
///     `MLXHuggingFace`'s `#hubDownloader()` / `#huggingFaceTokenizerLoader()`
///     macros) — see FoundationModelsRouter's own
///     `Examples/MultiModelGeneration` for the fully-wired version of this
///     same resolve-then-drive call pattern.
///   - Live LSP-backed ops and full indexing need the workspace's language
///     servers actually installed and on `PATH`. By default `CodeContext`
///     auto-installs a missing server for a detected language (opt out with
///     `CodeContext(..., autoInstall: LspAutoInstall(isEnabled: false))`; see
///     the package README's "Language servers" section) — so this example
///     needs no extra code to benefit, and passes no `autoInstall:` argument.
///
/// Run with `swift run CodeContextExample [root] [query]` as a local smoke
/// step once those pieces are wired up; it is not part of this package's
/// automated verification (`swift build` / `swift test` are).

let arguments = CommandLine.arguments
let rootPath = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let rootDirectory = URL(fileURLWithPath: rootPath, isDirectory: true)
let query = arguments.count > 2 ? arguments[2] : "TODO"

// MARK: - Resolve a RoutedEmbedder

// A profile resolves its `standard`/`flash`/`embedding` slots together —
// there is no embedding-only shape for `ProfileDefinition` (see plan.md) —
// so the generation slots still need plausible candidates to size against,
// even though only `embedding` is used below.
let profileDefinition = ProfileDefinition(
    name: "code-context-example",
    description: "Standalone CodeContext example: resolves an embedder to index one repo root.",
    standard: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
    flash: ["mlx-community/SmolLM-135M-Instruct-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"]
)

let router = Router(
    recordingsDir: FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeContextExample-\(UUID().uuidString)", isDirectory: true)
)

let profile = try await router.resolve(profile: profileDefinition, reporting: ResolutionProgress())
let embedder = RoutedEmbedderAdapter(routedEmbedder: profile.embedding)

// MARK: - Open, start, query, and stop a CodeContext

let context = try await CodeContext(rootDirectory: rootDirectory, embedder: embedder)
try await context.start()

let projects = try await context.detectProjects()
print("Detected projects: \(projects)")

let indexProgress = await context.indexStatus()
print("Index status: \(indexProgress)")

let symbolMatches = try await context.searchSymbol(query: query)
print("searchSymbol(\"\(query)\") matches: \(symbolMatches)")

let codeHits = try await context.searchCode(query: query)
print("searchCode(\"\(query)\") hits: \(codeHits)")

await context.stop()
await profile.release()
