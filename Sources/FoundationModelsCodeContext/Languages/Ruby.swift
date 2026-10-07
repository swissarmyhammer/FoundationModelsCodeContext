import SwiftTreeSitter
import TreeSitterRuby

/// The Ruby `LanguageModule`: grammar, chunk rules, project markers, and LSP server spec for `.rb` files.
///
/// - `fileExtensions` are ported from the Ruby entry of the Rust
///   `swissarmyhammer-treesitter/src/language.rs` `LANGUAGES` table.
/// - Chunk kinds are ported from the Ruby section of the Rust
///   `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant. `method` and `singleton_method` (`def self.name`) map to
///   `.method`; `class` maps to `.type`; `module` maps to `.other`, because a
///   module declares a namespace or a mixin, not a type.
/// - `containerNodeKinds` is the Ruby subset of the Rust `CONTAINER_KINDS`
///   constant (`module`).
/// - `projectMarkers` is `Gemfile`. The Rust
///   `swissarmyhammer-project-detection` table has no Ruby entry, thus this
///   marker is not ported. Project detection uses it to start `solargraph`.
/// - `languageServer` is ported from `builtin/lsp/solargraph.yaml`.
public enum RubyLanguage: LanguageModule {
    /// The language identifier (`"ruby"`).
    public static let name = "ruby"

    /// File extensions this module handles, without a leading dot: `["rb", "rake", "gemspec"]`.
    public static let fileExtensions = ["rb", "rake", "gemspec"]

    /// The tree-sitter-ruby grammar entry point used to parse Ruby source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_ruby())

    /// Definition node kind → meta-type mapping.
    ///
    /// `method` and `singleton_method` map to `.method`; `class` maps to
    /// `.type`; `module` maps to `.other`.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "method": .method,
        "singleton_method": .method,
        "class": .type,
        "module": .other,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// A module qualifies the classes and the methods in it, for example
    /// `Outer.Inner.method`.
    public static let containerNodeKinds: Set<String> = [
        "module"
    ]

    /// The marker file that identifies a Ruby project: `Gemfile`.
    public static let projectMarkers: [ProjectMarker] = [
        .fileName("Gemfile")
    ]

    /// The Ruby language server spec (`solargraph`).
    public static let languageServer: ServerSpec? = ServerSpec(
        command: "solargraph",
        arguments: ["stdio"],
        languageIDs: [name],
        installHint: "Install solargraph: gem install solargraph",
        installer: ServerSpec.InstallSpec(
            tool: "gem",
            arguments: ["install", "solargraph"]
        )
    )
}
