import SwiftTreeSitter
import TreeSitterYAML

/// The YAML `LanguageModule`: grammar and chunk rules for `.yaml`/`.yml` files.
///
/// - The Rust `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant has no YAML section — like JSON, YAML has no function/type-like
///   construct worth chunking as a definition. `chunkKinds` instead maps
///   `block_mapping_pair` and `flow_pair` (a `key: value` entry in
///   block-style and flow-style mappings, respectively) to `.other`, so a
///   document's top-level keys are still indexable as chunks.
/// - `containerNodeKinds` is `block_mapping` and `flow_mapping`: a nested
///   mapping pair's symbol_path is qualified by its enclosing mapping, the
///   same role `class_definition` plays for a nested method in
///   `PythonLanguage`.
/// - `projectMarkers` is empty: `swissarmyhammer-project-detection`'s
///   `ProjectType` enum has no YAML variant — a `.yaml` file doesn't identify
///   a whole project the way `Cargo.toml` or `pyproject.toml` does.
/// - `languageServer` is `nil`: this is a tree-sitter-only module (no YAML
///   entry in `builtin/lsp/*.yaml`).
public enum YAMLLanguage: LanguageModule {
    /// The language identifier (`"yaml"`).
    public static let name = "yaml"

    /// File extensions this module handles, without a leading dot: `["yaml", "yml"]`.
    public static let fileExtensions = ["yaml", "yml"]

    /// The tree-sitter-yaml grammar entry point used to parse `.yaml` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_yaml())

    /// Definition node kind → meta-type mapping.
    ///
    /// `block_mapping_pair` and `flow_pair` (a `key: value` entry in
    /// block-style and flow-style mappings) map to `.other`: YAML has no
    /// function, method, or type declaration to chunk, but a document's
    /// top-level keys are still meaningful units worth indexing.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "block_mapping_pair": .other,
        "flow_pair": .other,
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// `block_mapping` and `flow_mapping` provide this naming context without
    /// being chunked themselves, so a nested mapping pair is qualified by its
    /// enclosing mapping.
    public static let containerNodeKinds: Set<String> = [
        "block_mapping",
        "flow_mapping",
    ]

    /// Marker files that identify a YAML project.
    ///
    /// Empty: `swissarmyhammer-project-detection`'s `ProjectType` enum has no
    /// YAML variant.
    public static let projectMarkers: [ProjectMarker] = []

    /// Always `nil`: this is a tree-sitter-only module with no LSP server.
    public static let languageServer: ServerSpec? = nil
}
