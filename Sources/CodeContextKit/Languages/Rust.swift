import SwiftTreeSitter
import TreeSitterRust

/// The Rust `LanguageModule`: grammar, chunk rules, project markers, and
/// LSP server spec for `.rs` files.
///
/// - Chunk kinds are ported from the Rust section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `function_item` covers both free functions and methods in
///   tree-sitter-rust's grammar (there's no separate method node kind — the
///   distinction is purely positional, inside vs. outside an `impl` block),
///   so it maps to `.function` rather than `.method`. `impl_item` maps to
///   `.other`: it implements methods for an existing type rather than
///   declaring a new one.
/// - `containerNodeKinds` is the Rust-applicable subset of the Rust
///   `CONTAINER_KINDS` constant (`impl_item`, `mod_item`, `trait_item`).
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::Rust`.
/// - `languageServer` is ported from `builtin/lsp/rust-analyzer.yaml`.
public enum RustLanguage: LanguageModule {
    public static let name = "rust"

    public static let fileExtensions = ["rs"]

    public static let treeSitterLanguage: Language? = Language(tree_sitter_rust())

    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_item": .function,
        "impl_item": .other,
        "struct_item": .type,
        "enum_item": .type,
        "trait_item": .type,
        "mod_item": .other,
        "macro_definition": .other,
        "const_item": .other,
        "static_item": .other,
        "type_item": .type,
    ]

    public static let containerNodeKinds: Set<String> = [
        "impl_item",
        "mod_item",
        "trait_item",
    ]

    public static let projectMarkers: [ProjectMarker] = [
        .fileName("Cargo.toml"),
    ]

    public static let languageServer: ServerSpec? = ServerSpec(
        command: "rust-analyzer",
        languageIDs: ["rust"],
        installHint: "Install rust-analyzer: rustup component add rust-analyzer"
    )
}
