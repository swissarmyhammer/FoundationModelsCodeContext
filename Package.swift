// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Repeated identifiers extracted to named constants so the manifest has a
// single source of truth, following the pattern established by the sibling
// FoundationModelsRouter package.
let packageName = "CodeContextKit"

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
    // Commit to macOS 27 / FoundationModels v2; floor inherited from
    // FoundationModelsRouter, whose RoutedEmbedder backs text embedding.
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
        // Referenced by URL rather than local path deliberately: RankKit (the
        // path dependency below) also depends on FoundationModelsRouter by
        // this exact URL — by CI necessity, see RankKit's Package.swift — and
        // SwiftPM rejects one package identity ('foundationmodelsrouter')
        // reached through two different origins (URL vs. path); today it's a
        // "Conflicting identity" warning, escalating to an error in future
        // SwiftPM versions. Keep the URL + branch spelling identical to
        // RankKit's so both chains resolve to a single origin. For local
        // co-development of the sibling checkout, use
        // `swift package edit foundationmodelsrouter --path ../FoundationModelsRouter`.
        .package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
        .package(path: "../RankKit"),
        // Pinned exact rather than `from:`: SwiftTreeSitter is still pre-1.0,
        // where ChimeHQ has made breaking API changes across minor versions,
        // so an open `from:` range could silently pull in a breaking update.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/alex-pinkus/\(treeSitterSwiftPackage)", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterRustPackage)", from: "0.24.0"),
        // Pinned exact: v0.24.0+ manifests gate `src/scanner.c` on
        // `FileManager.default.fileExists(atPath:)`, which resolves against
        // the *top-level build's* working directory rather than this
        // package's own checkout, so the external scanner silently drops
        // out of the build and the linker fails with undefined
        // `tree_sitter_python_external_scanner_*` symbols. v0.23.6 still
        // lists `src/scanner.c` unconditionally.
        .package(url: "https://github.com/tree-sitter/\(treeSitterPythonPackage)", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterTypeScriptPackage)", from: "0.23.2"),
        // Pinned exact: the same `src/scanner.c`-gated-on-`FileManager` issue
        // documented above for `tree-sitter-python` also hits
        // `tree-sitter-javascript` starting at v0.25.0 (unresolved path
        // check drops the external scanner and the linker fails with
        // undefined `tree_sitter_javascript_external_scanner_*` symbols).
        // v0.23.1 still lists `src/scanner.c` unconditionally.
        .package(url: "https://github.com/tree-sitter/\(treeSitterJavaScriptPackage)", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterGoPackage)", from: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterCPackage)", from: "0.24.1"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterCPPPackage)", from: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterJavaPackage)", from: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterCSharpPackage)", from: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterPHPPackage)", from: "0.23.11"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterJSONPackage)", from: "0.24.0"),
        // Pinned exact: v0.7.1+ manifests gate `src/scanner.c` on
        // `FileManager.default.fileExists(atPath:)` — the same
        // `tree-sitter-python`/`tree-sitter-javascript` issue documented
        // above — so the external scanner silently drops out of the build
        // and the linker fails with undefined
        // `tree_sitter_yaml_external_scanner_*` symbols. v0.7.0 still lists
        // `src/scanner.c` unconditionally.
        .package(url: "https://github.com/tree-sitter-grammars/\(treeSitterYAMLPackage)", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/\(treeSitterMarkdownPackage)", from: "0.5.0"),
        .package(url: "https://github.com/tree-sitter/\(treeSitterBashPackage)", from: "0.25.0"),
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: [
                .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
                .product(name: "RankKit", package: "RankKit"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ] + grammarProducts,
            path: "Sources/\(packageName)"
        ),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [
                .target(name: packageName),
                // Test files exercise RankKit primitives directly (e.g.
                // `CosineScoring.matvecScores`, `Tokenizer`/`Trigram`
                // disjointness assertions), so the module must be an explicit
                // dependency here, not just reachable through CodeContextKit.
                .product(name: "RankKit", package: "RankKit"),
            ],
            path: "Tests/\(packageName)Tests",
            // `scripted-lsp-server.swift` is a standalone script launched via
            // `/usr/bin/env swift <path>` as a scripted subprocess in
            // ConnectionTests — not a source file of this test module.
            exclude: ["Support/scripted-lsp-server.swift"]
        ),
    ]
)
