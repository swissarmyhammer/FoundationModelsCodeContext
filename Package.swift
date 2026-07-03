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
        .package(path: "../FoundationModelsRouter"),
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
    ],
    targets: [
        .target(
            name: packageName,
            dependencies: [
                .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ] + grammarProducts,
            path: "Sources/\(packageName)"
        ),
        .testTarget(
            name: "\(packageName)Tests",
            dependencies: [.target(name: packageName)],
            path: "Tests/\(packageName)Tests"
        ),
    ]
)
