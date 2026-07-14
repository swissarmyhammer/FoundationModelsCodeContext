import SwiftTreeSitter
import TreeSitterPHP

/// The PHP `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.php` files.
///
/// - Chunk kinds are ported from the PHP section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `function_definition` maps to `.function`; `method_declaration`
///   maps to `.method`; `class_declaration`, `interface_declaration`, and
///   `trait_declaration` map to `.type`.
/// - `containerNodeKinds` is the PHP-applicable subset of the Rust
///   `CONTAINER_KINDS` constant: `class_declaration` and
///   `interface_declaration` directly, plus `trait_declaration` as the
///   grammar-correct PHP spelling of that constant's Rust-specific
///   `trait_item` entry (tree-sitter-php's own trait node kind, not
///   tree-sitter-rust's).
/// - `projectMarkers` are ported from `swissarmyhammer-project-detection`'s
///   `PROJECT_TYPE_SPECS` entry for `ProjectType::Php` (`composer.json`).
/// - `languageServer` is ported from `builtin/lsp/intelephense.yaml`.
///
/// The upstream `tree-sitter-php` grammar exposes two entry points:
/// `tree_sitter_php()` (the full PHP dialect embedded in HTML, matching how
/// `.php` files are actually authored) and `tree_sitter_php_only()` (pure
/// PHP with no surrounding HTML). This module uses the former.
public enum PHPLanguage: LanguageModule {
    /// The language identifier (`"php"`).
    public static let name = "php"

    /// File extensions this module handles, without a leading dot: `["php"]`.
    public static let fileExtensions = ["php"]

    /// The tree-sitter-php grammar entry point used to parse `.php` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_php())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_definition` maps to `.function`; `method_declaration` maps
    /// to `.method`; `class_declaration`, `interface_declaration`, and
    /// `trait_declaration` map to `.type`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function,
        "method_declaration": .method,
        "class_declaration": .type,
        "interface_declaration": .type,
        "trait_declaration": .type,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Class, interface, and trait declarations provide this naming context
    /// without being chunked themselves.
    public static let containerNodeKinds: Set<String> = [
        "class_declaration",
        "interface_declaration",
        "trait_declaration",
    ]

    /// The marker file that identifies a PHP project: `composer.json`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("composer.json"),
    ]

    /// The PHP language server spec (`intelephense`).
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "intelephense",
        args: ["--stdio"],
        languageIDs: [name],
        installHint: "Install intelephense: npm install -g intelephense"
    )
}
