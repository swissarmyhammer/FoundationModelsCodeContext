import SwiftTreeSitter
import TreeSitterElixir

/// The Elixir `LanguageModule`: grammar and chunk rules for `.ex`/`.exs` files.
///
/// - `fileExtensions` are ported from the Elixir entry of the Rust
///   `swissarmyhammer-treesitter/src/language.rs` `LANGUAGES` table.
/// - Chunk kinds are ported from the Elixir section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. The grammar gives `def`, `defp`, `defmodule`, and each other
///   definition as a `call` node. The node kind alone does not tell which
///   definition the call makes, thus `call` maps to `.other`.
/// - `containerNodeKinds` is empty: no entry of the Rust `CONTAINER_KINDS`
///   constant is an Elixir node kind.
/// - `projectMarkers` is `mix.exs`. The Rust
///   `swissarmyhammer-project-detection` table has no Elixir entry, thus this
///   marker is not ported.
/// - `languageServer` is `nil`: `builtin/lsp/*.yaml` has no Elixir server.
public enum ElixirLanguage: LanguageModule {
    /// The language identifier (`"elixir"`).
    public static let name = "elixir"

    /// File extensions this module handles, without a leading dot: `["ex", "exs"]`.
    public static let fileExtensions = ["ex", "exs"]

    /// The tree-sitter-elixir grammar entry point used to parse Elixir source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_elixir())

    /// Definition node kind → meta-type mapping.
    ///
    /// `call` maps to `.other`: each Elixir definition is a call to a macro,
    /// and the node kind does not tell which macro.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "call": .other
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// Empty: `defmodule` is a `call` node, which `chunkKinds` already holds.
    public static let containerNodeKinds: Set<String> = []

    /// The marker file that identifies an Elixir (Mix) project: `mix.exs`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("mix.exs")
    ]

    /// Always `nil`: `builtin/lsp/*.yaml` has no Elixir server.
    public static let languageServer: ServerSpec? = nil
}
