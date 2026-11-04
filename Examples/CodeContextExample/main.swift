import ExampleSupport
import Foundation
import FoundationModelsCodeContext
import FoundationModelsExtras

/// # Runnable demo: standalone, single-root `CodeContext`.
///
/// This is the standalone "way in" to this package (see plan.md's Goal). Point
/// it at one repository root. It then uses the public API from start to end: it
/// makes an embedder and a selection model, opens a `CodeContext`, starts it, runs two read-only
/// queries, and stops the context.
///
/// ## The caller supplies the embedding model
///
/// This package loads no embedding model. The caller gives any `PooledEmbedding`
/// value to `CodeContext(rootDirectory:embedder:selection:)`. The protocol has one
/// member: `embed(texts:)`, which returns one unit-length vector for each text.
/// The protocol declares no vector length: `CodeContext` reads the length
/// from the first vector that the embedder returns. A production host wraps
/// its real model (for example an MLX embedder) in a small conformance with
/// this one member.
///
/// This target uses `HashingEmbedder` of the `ExampleSupport` target, a conformance that needs no
/// model and no network. It counts hashed tokens, so `searchCode` finds texts that share
/// words, not texts that share meaning. Put a real model behind the same
/// member to get semantic search.
///
/// ## The caller supplies the selection model
///
/// The caller gives a `SelectionFactory` to `CodeContext(rootDirectory:embedder:selection:)`. This
/// file gives the on-device model through `ExampleSelection`, where the contract is described.
///
/// ## What this file does and does not exercise
///
/// This target links only `FoundationModelsCodeContext`, so `swift build` stays
/// fast and has few dependencies. The job of this file is to compile-verify and
/// document the public surface of the package. It holds no library logic.
///
///   - Live LSP-backed ops and full indexing need the language servers of the
///     workspace on `PATH`. By default `CodeContext` auto-installs a missing
///     server for a detected language (opt out with
///     `CodeContext(..., selection: selection, autoInstall: LspAutoInstall(isEnabled: false))`; see
///     the "Language servers" section of the package README). Thus this example
///     needs no extra code for this, and gives no `autoInstall:` argument.
///
/// Run with `swift run CodeContextExample [root] [query]`.

let rootDirectory = ExampleArguments.directoryURL()
let query = ExampleArguments.query()

// MARK: - Make the caller-defined embedder

// The embedder of the `ExampleSupport` target. It has a fixed vector length, so the two examples
// that use it make the same vectors.
private let embedder = HashingEmbedder.example

// MARK: - Make the caller-defined selection model

// The selection factory of the `ExampleSupport` target.
let selection = ExampleSelection.onDeviceModel

// MARK: - Open, start, query, and stop a CodeContext

let context = try await CodeContext(rootDirectory: rootDirectory, embedder: embedder, selection: selection)
try await context.start()

// `start()` returns before the index is complete. This call waits for the
// complete first index pass, thus each query below reads a complete index.
await context.waitForFirstIndexPass()

// MARK: - The FoundationModels tools of this context

// `CodeContextTools.make(context:)` gives the three tools of one `CodeContext`.
// A host gives them to a `LanguageModelSession`. This example only prints the
// name of each tool and its op strings: it calls no language model.
//
// This demo is a command-line program, and it has no logging system. It writes
// each result that the reader asked for through `ExampleOutput.report(_:)`, the
// one place that holds the swiftlint directive for `no_direct_standard_out_logs`.
let tools = try CodeContextTools.make(context: context)
for tool in tools {
    let operations = CodeContextTools.operationNames[tool.name] ?? []
    ExampleOutput.report("Tool \(tool.name): \(operations.joined(separator: ", "))")
}

// MARK: - Query the context

let projects = try await context.detectProjects()
ExampleOutput.report("Detected projects: \(projects)")

let indexProgress = await context.indexStatus()
ExampleOutput.report("Index status: \(indexProgress)")

let symbolMatches = try await context.searchSymbol(query: query)
ExampleOutput.report("searchSymbol(\"\(query)\") matches: \(symbolMatches)")

let codeHits = try await context.searchCode(query: query)
ExampleOutput.report("searchCode(\"\(query)\") hits: \(codeHits)")

await context.stop()
