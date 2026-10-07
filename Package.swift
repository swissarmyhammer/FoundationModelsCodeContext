// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers are named constants, so the manifest has a single
// source of truth for each identifier.
let packageName = "FoundationModelsCodeContext"

// Per-language tree-sitter grammar packages. `alex-pinkus/tree-sitter-swift`
// does not commit generated parser sources on its default branch (SwiftPM
// can't run the tree-sitter CLI codegen step), so it is pinned to the
// `-with-generated-files` tag that does. The other grammars commit generated
// sources directly, so plain semver pins work.
let treeSitterSwiftPackage = "tree-sitter-swift"
let treeSitterRustPackage = "tree-sitter-rust"
let treeSitterTypeScriptPackage = "tree-sitter-typescript"
let treeSitterGoPackage = "tree-sitter-go"
let treeSitterCPackage = "tree-sitter-c"
let treeSitterCPPPackage = "tree-sitter-cpp"
let treeSitterJavaPackage = "tree-sitter-java"
let treeSitterCSharpPackage = "tree-sitter-c-sharp"
let treeSitterPHPPackage = "tree-sitter-php"
let treeSitterJSONPackage = "tree-sitter-json"
let treeSitterYAMLPackage = "tree-sitter-yaml"
let treeSitterMarkdownPackage = "tree-sitter-markdown"
let treeSitterBashPackage = "tree-sitter-bash"
let treeSitterRubyPackage = "tree-sitter-ruby"
let treeSitterElixirPackage = "tree-sitter-elixir"

// The local C targets that hold the JavaScript and the Python grammars.
// Each target holds the files of the tag `v0.25.0` of its upstream repo
// (`tree-sitter/tree-sitter-javascript`, `tree-sitter/tree-sitter-python`)
// with no change: `src/parser.c`, `src/scanner.c`, the headers in
// `src/tree_sitter/`, the header of `bindings/swift/<Module>/` (here in
// `include/`), and the MIT license of the grammar (`LICENSE`).
//
// Why a local target and not the package: the v0.25.0 manifests add
// `src/scanner.c` to their sources only when
// `FileManager.default.fileExists(atPath: "src/scanner.c")` is true. That
// path is relative to the folder of the top-level build, not to the
// package, thus a package that depends on the grammar does not compile the
// scanner, and the link fails with undefined
// `tree_sitter_<language>_external_scanner_*` symbols. A local target needs
// no step on the host. When a released tag lists the scanner in its
// manifest, the package can replace the target.
let treeSitterJavaScriptTargetName = "TreeSitterJavaScript"
let treeSitterPythonTargetName = "TreeSitterPython"

// The upstream scanner of `treeSitterPythonTargetName`. The target does not
// compile it directly: it compiles `scanner_build.c`, which includes it.
// The C compiler of a root package enables `-Wshorten-64-to-32`, and this
// file gives three such warnings. `scanner_build.c` stops that one warning,
// thus the upstream file stays with no change.
let treeSitterPythonScannerSource = "src/scanner.c"

// The license file of a local grammar target. It is not an input of the
// build, thus the target excludes it.
let grammarLicenseFileName = "LICENSE"

/// Builds the local C target of a grammar under `Sources/`.
///
/// SwiftPM compiles each `.c` file of the folder, and the folder `include/`
/// holds the public header. The upstream files keep their upstream place in
/// `src/`, thus `#include "tree_sitter/parser.h"` finds the header next to
/// the file.
///
/// - Parameters:
///   - name: The name of the target, of its module, and of its folder.
///   - includedSources: The upstream `.c` files that a build unit of the
///     target includes, thus SwiftPM must not compile them a second time.
func localGrammarTarget(name: String, includedSources: [String] = []) -> Target {
    .target(name: name, path: "Sources/\(name)", exclude: [grammarLicenseFileName] + includedSources)
}

// The telemetry APIs (the OpenTelemetry design of 2026-09-28). These are
// abstractions, not exporters. The library target links the APIs only: it
// bootstraps no backend and it does not depend on `swift-otel`. Until a host
// executable bootstraps a backend, each span, each logger and each metric of
// the library does nothing. `CodeContextTracing` holds the names that the
// library uses with these APIs.
let tracingPackage = "swift-distributed-tracing"
let loggingPackage = "swift-log"
let metricsPackage = "swift-metrics"

// The two GitHub organizations hosting the grammar packages above. Most
// grammars live in the canonical `tree-sitter` org; the YAML and Markdown
// grammars are community-maintained under `tree-sitter-grammars`. Extracted
// so each base URL has a single source of truth, like the package-name
// constants above.
let treeSitterOrgURL = "https://github.com/tree-sitter/"
let treeSitterGrammarsOrgURL = "https://github.com/tree-sitter-grammars/"

// `tree-sitter-sql` (DerekStride/tree-sitter-sql, the grammar this project's
// Rust sibling depends on as the `tree-sitter-sequel` crate — crates.io
// reserves the `tree-sitter-sql` name) has no working SwiftPM dependency: its
// root-level `Package.swift` lists `src/parser.c` and `src/scanner.c` as
// build sources, but `src/parser.c` — the generated parser — is not
// committed to git at any tagged release or on `main`; only the hand-written
// `src/scanner.c` is checked in. The generated parser is produced by
// `tree-sitter generate` and bundled only into the npm/crates.io release
// tarballs SwiftPM never fetches. So there is no SQL entry in
// `grammarProducts`/`dependencies` below; `SQLLanguage.swift` documents the
// gap and declares `treeSitterLanguage: nil` rather than standing up a
// wrapper package to vendor generated sources ourselves (see
// `Languages.swift`'s stated policy for grammars with no upstream SwiftPM
// support).

let grammarProducts: [Target.Dependency] = [
    .product(name: "TreeSitterSwift", package: treeSitterSwiftPackage),
    .product(name: "TreeSitterRust", package: treeSitterRustPackage),
    .target(name: treeSitterPythonTargetName),
    // `tree-sitter-typescript` bundles both the TypeScript and TSX grammars
    // as two targets under a single "TreeSitterTypeScript" library product
    // (no separate "TreeSitterTSX" product exists upstream); depending on
    // that one product makes both the `TreeSitterTypeScript` and
    // `TreeSitterTSX` modules importable.
    .product(name: "TreeSitterTypeScript", package: treeSitterTypeScriptPackage),
    .target(name: treeSitterJavaScriptTargetName),
    .product(name: "TreeSitterGo", package: treeSitterGoPackage),
    .product(name: "TreeSitterC", package: treeSitterCPackage),
    .product(name: "TreeSitterCPP", package: treeSitterCPPPackage),
    .product(name: "TreeSitterJava", package: treeSitterJavaPackage),
    .product(name: "TreeSitterCSharp", package: treeSitterCSharpPackage),
    .product(name: "TreeSitterPHP", package: treeSitterPHPPackage),
    .product(name: "TreeSitterJSON", package: treeSitterJSONPackage),
    .product(name: "TreeSitterYAML", package: treeSitterYAMLPackage),
    // `tree-sitter-markdown` bundles the block-level grammar and the
    // separate inline-markup grammar as two targets under a single
    // "TreeSitterMarkdown" library product; depending on that one product
    // makes only the `TreeSitterMarkdown` (block-level) module importable
    // without an extra `import TreeSitterMarkdownInline`, which
    // `MarkdownLanguage` doesn't need — see its doc comment.
    .product(name: "TreeSitterMarkdown", package: treeSitterMarkdownPackage),
    .product(name: "TreeSitterBash", package: treeSitterBashPackage),
    .product(name: "TreeSitterRuby", package: treeSitterRubyPackage),
    .product(name: "TreeSitterElixir", package: treeSitterElixirPackage),
]

let package = Package(
    name: packageName,
    // Commit to macOS 27. FoundationModels v2 and FoundationModelsRanker
    // need this floor.
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(
            name: packageName,
            targets: [packageName]
        )
    ],
    dependencies: [
        // Referenced by URL, not by a local path. This is the CI convention of the
        // package family: the shared workflow checks out only the calling repo, so a
        // `../FoundationModelsRanker` path dependency does not resolve there. For local
        // co-development of the sibling checkout, use
        // `swift package edit foundationmodelsranker --path ../FoundationModelsRanker`.
        .package(url: "git@github.com:swissarmyhammer/FoundationModelsRanker.git", branch: "main"),
        // Referenced by URL for the same CI reason as the Ranker entry above. Its `Operations`
        // product gives `@Operation` and `OperationTool`, which the FoundationModels tools of this
        // package use. The Extras manifest declares tools version 6.2, so this manifest declares
        // 6.2 too. For local co-development of the sibling checkout, use
        // `swift package edit foundationmodelsextras --path ../FoundationModelsExtras`.
        .package(url: "git@github.com:swissarmyhammer/FoundationModelsExtras.git", branch: "main"),
        // Pinned exact rather than `from:`: SwiftTreeSitter is still pre-1.0,
        // where ChimeHQ has made breaking API changes across minor versions,
        // so an open `from:` range could silently pull in a breaking update.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/alex-pinkus/\(treeSitterSwiftPackage)", exact: "0.7.4-with-generated-files"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterRustPackage)", from: "0.24.0"),
        // The Python and JavaScript grammars are local targets, not packages.
        // See `treeSitterJavaScriptTargetName` above.
        .package(url: "\(treeSitterOrgURL)\(treeSitterTypeScriptPackage)", from: "0.23.2"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterGoPackage)", from: "0.23.4"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterCPackage)", from: "0.24.1"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterCPPPackage)", from: "0.23.4"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterJavaPackage)", from: "0.23.5"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterCSharpPackage)", from: "0.23.1"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterPHPPackage)", from: "0.23.11"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterJSONPackage)", from: "0.24.0"),
        // Pinned exact: v0.7.1+ manifests gate `src/scanner.c` on
        // `FileManager.default.fileExists(atPath:)` — the same
        // `tree-sitter-python`/`tree-sitter-javascript` issue documented
        // above — so the external scanner silently drops out of the build
        // and the linker fails with undefined
        // `tree_sitter_yaml_external_scanner_*` symbols. v0.7.0 still lists
        // `src/scanner.c` unconditionally.
        .package(url: "\(treeSitterGrammarsOrgURL)\(treeSitterYAMLPackage)", exact: "0.7.0"),
        .package(url: "\(treeSitterGrammarsOrgURL)\(treeSitterMarkdownPackage)", from: "0.5.0"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterBashPackage)", from: "0.25.0"),
        // Pinned exact: FoundationModelsMultitool links these grammars through
        // this package, and its golden tests compare each parse with the Rust
        // `swissarmyhammer-sem` crate, which uses these versions. Both
        // manifests list `src/scanner.c` with no `FileManager` check.
        .package(url: "\(treeSitterOrgURL)\(treeSitterRubyPackage)", exact: "0.23.1"),
        .package(url: "https://github.com/elixir-lang/\(treeSitterElixirPackage)", exact: "0.3.5"),
        // The same version ranges as FoundationModelsRouter and FoundationModelsExtras, so
        // that one graph resolves each telemetry API to one version.
        .package(url: "https://github.com/apple/\(tracingPackage).git", from: "1.4.1"),
        .package(url: "https://github.com/apple/\(loggingPackage).git", from: "1.15.1"),
        .package(url: "https://github.com/apple/\(metricsPackage).git", from: "2.11.0"),
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: [
                .product(name: "FoundationModelsRanker", package: "FoundationModelsRanker"),
                .product(name: "Operations", package: "FoundationModelsExtras"),
                // `TracedCall` opens a span and writes one "enter" log record when a call starts
                // (rule 8 of the OpenTelemetry design, hang detection). The LSP request, the embed
                // call and the index pass use it.
                .product(name: "FoundationModelsExtras", package: "FoundationModelsExtras"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Tracing", package: tracingPackage),
                .product(name: "Logging", package: loggingPackage),
                .product(name: "Metrics", package: metricsPackage),
            ] + grammarProducts,
            path: "Sources/\(packageName)"
        ),
        // The JavaScript and Python grammars of `grammarProducts`. See
        // `treeSitterJavaScriptTargetName` for the upstream tag and for the
        // reason that they are local.
        localGrammarTarget(name: treeSitterJavaScriptTargetName),
        localGrammarTarget(name: treeSitterPythonTargetName, includedSources: [treeSitterPythonScannerSource]),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [
                .target(name: packageName),
                // Test files exercise FoundationModelsRanker primitives directly (e.g.
                // `CosineScoring.matvecScores`, `Tokenizer`/`Trigram`
                // disjointness assertions), so the module must be an explicit
                // dependency here, not just reachable through FoundationModelsCodeContext.
                .product(name: "FoundationModelsRanker", package: "FoundationModelsRanker"),
                // The tool tests use `OperationTool`, `AnyOperation` and `GeneratedContent`
                // directly, so the `Operations` module must be an explicit dependency here, not
                // just reachable through FoundationModelsCodeContext.
                .product(name: "Operations", package: "FoundationModelsExtras"),
                // The tracing tests give an explicit `InMemoryTracer` to the code under test and
                // read the finished spans from it. They do not bootstrap the global system.
                .product(name: "InMemoryTracing", package: tracingPackage),
                // The logging tests read the log records of the code under test from an
                // `InMemoryLogHandler`. Some tests give the handler to the code under test in a
                // `Logger`. The content test bootstraps the handler one time for the test process.
                .product(name: "Logging", package: loggingPackage),
                .product(name: "InMemoryLogging", package: loggingPackage),
                // The metrics tests give a `TestMetrics` factory to the code under test and read
                // the recorded values from it. They do not bootstrap the global system.
                .product(name: "MetricsTestKit", package: metricsPackage),
            ],
            path: "Tests/\(packageName)Tests",
            // `scripted-lsp-server.swift` is a standalone script launched via
            // `/usr/bin/env swift <path>` as a scripted subprocess in
            // ConnectionTests — not a source file of this test module.
            exclude: ["Support/scripted-lsp-server.swift"]
        ),
        // Standalone, single-root "way in" example (see plan.md's Goal and the
        // package README). It is a thin script over the public API of this
        // package, and it is not part of the library product. The caller
        // supplies the embedding model: the example defines its own small
        // `TextEmbedding` conformance and gives it to `CodeContext`. Thus it
        // needs only the library target.
        .executableTarget(
            name: "CodeContextExample",
            dependencies: [
                .target(name: packageName)
            ],
            path: "Examples/CodeContextExample"
        ),
        // Second "way in" example, over `CodeContextManager` instead of one `CodeContext`.
        // It opens each repo root below a parent directory, not one fixed root. Like
        // `CodeContextExample` above, it defines its own `TextEmbedding` conformance and
        // gives it to the manager. Thus it needs only the library target.
        .executableTarget(
            name: "ManagerExample",
            dependencies: [
                .target(name: packageName)
            ],
            path: "Examples/ManagerExample"
        ),
    ]
)
