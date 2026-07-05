import SwiftTreeSitter
import TreeSitterBash

/// The Bash `LanguageModule`: grammar and chunk rules for `.sh`/`.bash`/`.zsh` files.
///
/// - Chunk kinds are ported from the Bash section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant: `function_definition` (covers both the `function name { ... }`
///   and `name() { ... }` forms tree-sitter-bash's grammar recognizes) maps
///   to `.function`.
/// - `containerNodeKinds` is empty: none of the Rust `CONTAINER_KINDS`
///   constant's entries are Bash-specific, and Bash has no real container for
///   chunked definitions — functions are declared at the top level (or
///   nested inside another function's body, which isn't a naming-context
///   node the way a class or module is).
/// - `projectMarkers` is empty: `swissarmyhammer-project-detection`'s
///   `ProjectType` enum has no Bash/shell variant — a shell script doesn't
///   identify a whole project the way `Cargo.toml` or `pyproject.toml` does.
/// - `languageServer` is `nil`: this is a tree-sitter-only module (no Bash
///   entry in `builtin/lsp/*.yaml`).
public enum BashLanguage: LanguageModule {
    /// The language identifier (`"bash"`).
    public static let name = "bash"

    /// File extensions this module handles, without a leading dot: `["sh", "bash", "zsh"]`.
    public static let fileExtensions = ["sh", "bash", "zsh"]

    /// The tree-sitter-bash grammar entry point used to parse shell script source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_bash())

    /// Definition node kind → meta-type mapping.
    ///
    /// `function_definition` maps to `.function`; it covers both the
    /// `function name { ... }` and `name() { ... }` forms tree-sitter-bash's
    /// grammar recognizes.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "function_definition": .function
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Empty: Bash functions are declared at the top level with no
    /// enclosing class or module construct to qualify a symbol_path with.
    public static let containerNodeKinds: Set<String> = []

    /// Marker files that identify a Bash project.
    ///
    /// Empty: `swissarmyhammer-project-detection`'s `ProjectType` enum has no
    /// Bash/shell variant.
    public static let projectMarkers: [ProjectMarker] = []

    /// Always `nil`: this is a tree-sitter-only module with no LSP server.
    public static let languageServer: ServerSpec? = nil
}
