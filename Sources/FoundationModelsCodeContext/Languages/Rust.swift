import SwiftTreeSitter
import TreeSitterRust

/// The Rust `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.rs` files.
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
    /// The language identifier (`"rust"`).
    public static let name = "rust"

    /// File extensions this module handles, without a leading dot: `["rs"]`.
    public static let fileExtensions = ["rs"]

    /// The tree-sitter-rust grammar entry point used to parse `.rs` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_rust())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_item` maps to `.function` (covers both free functions and
    /// methods — the distinction is purely positional, inside vs. outside an
    /// `impl` block, not a separate node kind); `struct_item`, `enum_item`,
    /// `trait_item`, and `type_item` map to `.type`; `impl_item`,
    /// `mod_item`, `macro_definition`, `const_item`, and `static_item` map
    /// to `.other`.
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

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// `impl_item` (methods implemented for a type), `mod_item` (items
    /// nested in a module), and `trait_item` (method declarations nested in
    /// a trait) provide this naming context without being chunked
    /// themselves.
    public static let containerNodeKinds: Set<String> = [
        "impl_item",
        "mod_item",
        "trait_item",
    ]

    /// The marker file that identifies a Rust project: `Cargo.toml`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("Cargo.toml"),
    ]

    /// The Rust language server spec (`rust-analyzer`).
    ///
    /// Typed as optional per the protocol to allow tree-sitter-only modules
    /// with no server; Rust always provides one.
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "rust-analyzer",
        languageIDs: [name],
        installHint: "Install rust-analyzer: rustup component add rust-analyzer"
    )
}
