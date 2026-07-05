import SwiftTreeSitter
import TreeSitterJSON

/// The JSON `LanguageModule`: grammar and chunk rules for `.json`/`.jsonc` files.
///
/// - The Rust `swissarmyhammer-treesitter/src/chunk.rs` `EMBEDDABLE_NODE_KINDS`
///   constant has no JSON section — JSON has no function/type-like construct
///   worth chunking as a definition. `chunkKinds` instead maps `pair` (a
///   `"key": value` entry) to `.other`, so a document's top-level keys are
///   still indexable as chunks; there is no closer analogue to `.function`,
///   `.method`, or `.type` for a data format with no callable or type
///   declarations.
/// - `containerNodeKinds` is `object`: a nested `pair`'s symbol_path is
///   qualified by the enclosing object, the same role `class_definition`
///   plays for a nested method in `PythonLanguage`.
/// - `projectMarkers` is empty: `swissarmyhammer-project-detection`'s
///   `ProjectType` enum has no JSON variant — a `.json` file doesn't identify
///   a whole project the way `Cargo.toml` or `pyproject.toml` does (even
///   though `package.json` does, that's `SharedProjectMarkers.nodeJs`'s
///   concern, not this format module's).
/// - `languageServer` is `nil`: this is a tree-sitter-only module (no JSON
///   entry in `builtin/lsp/*.yaml`).
public enum JSONLanguage: LanguageModule {
    /// The language identifier (`"json"`).
    public static let name = "json"

    /// File extensions this module handles, without a leading dot: `["json", "jsonc"]`.
    public static let fileExtensions = ["json", "jsonc"]

    /// The tree-sitter-json grammar entry point used to parse `.json` source.
    public static let treeSitterLanguage: Language? = Language(tree_sitter_json())

    /// Definition node kind → meta-type mapping.
    ///
    /// `pair` (a `"key": value` entry) maps to `.other`: JSON has no
    /// function, method, or type declaration to chunk, but a document's
    /// top-level keys are still meaningful units worth indexing.
    public static let chunkKinds: [String: SymbolMetaType] = [
        "pair": .other
    ]

    /// Node kinds that provide naming context for nested symbols' symbol_path.
    ///
    /// `object` provides this naming context without being chunked itself,
    /// so a nested pair is qualified by its enclosing object.
    public static let containerNodeKinds: Set<String> = [
        "object"
    ]

    /// Marker files that identify a JSON project.
    ///
    /// Empty: `swissarmyhammer-project-detection`'s `ProjectType` enum has no
    /// JSON variant.
    public static let projectMarkers: [ProjectMarker] = []

    /// Always `nil`: this is a tree-sitter-only module with no LSP server.
    public static let languageServer: ServerSpec? = nil
}
