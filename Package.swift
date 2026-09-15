// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers are named constants, so the manifest has a single
// source of truth for each identifier.
let packageName = "FoundationModelsCodeContext"

// Per-language tree-sitter grammar packages. `alex-pinkus/tree-sitter-swift`
// does not commit generated parser sources on its default branch (SwiftPM
// can't run the tree-sitter CLI codegen step), so it is pinned to the
// `-with-generated-files` tag that does. The `tree-sitter` org's Rust/Python
// grammars commit generated sources directly, so plain semver pins work.
let treeSitterSwiftPackage = "tree-sitter-swift"
let treeSitterRustPackage = "tree-sitter-rust"
let treeSitterPythonPackage = "tree-sitter-python"
let treeSitterTypeScriptPackage = "tree-sitter-typescript"
let treeSitterJavaScriptPackage = "tree-sitter-javascript"
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
    .product(name: "TreeSitterPython", package: treeSitterPythonPackage),
    // `tree-sitter-typescript` bundles both the TypeScript and TSX grammars
    // as two targets under a single "TreeSitterTypeScript" library product
    // (no separate "TreeSitterTSX" product exists upstream); depending on
    // that one product makes both the `TreeSitterTypeScript` and
    // `TreeSitterTSX` modules importable.
    .product(name: "TreeSitterTypeScript", package: treeSitterTypeScriptPackage),
    .product(name: "TreeSitterJavaScript", package: treeSitterJavaScriptPackage),
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
        .package(url: "https://github.com/alex-pinkus/\(treeSitterSwiftPackage)", exact: "0.7.3-with-generated-files"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterRustPackage)", from: "0.24.0"),
        // Pinned exact: v0.24.0+ manifests gate `src/scanner.c` on
        // `FileManager.default.fileExists(atPath:)`, which resolves against
        // the *top-level build's* working directory rather than this
        // package's own checkout, so the external scanner silently drops
        // out of the build and the linker fails with undefined
        // `tree_sitter_python_external_scanner_*` symbols. v0.23.6 still
        // lists `src/scanner.c` unconditionally.
        .package(url: "\(treeSitterOrgURL)\(treeSitterPythonPackage)", exact: "0.23.6"),
        .package(url: "\(treeSitterOrgURL)\(treeSitterTypeScriptPackage)", from: "0.23.2"),
        // Pinned exact: the same `src/scanner.c`-gated-on-`FileManager` issue
        // documented above for `tree-sitter-python` also hits
        // `tree-sitter-javascript` starting at v0.25.0 (unresolved path
        // check drops the external scanner and the linker fails with
        // undefined `tree_sitter_javascript_external_scanner_*` symbols).
        // v0.23.1 still lists `src/scanner.c` unconditionally.
        .package(url: "\(treeSitterOrgURL)\(treeSitterJavaScriptPackage)", exact: "0.23.1"),
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
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: [
                .product(name: "FoundationModelsRanker", package: "FoundationModelsRanker"),
                .product(name: "Operations", package: "FoundationModelsExtras"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ] + grammarProducts,
            path: "Sources/\(packageName)"
        ),
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
